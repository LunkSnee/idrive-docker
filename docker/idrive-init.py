#!/usr/bin/env python3
"""Container helper for idrive-docker.

IDrive for Linux was written for a normal machine. In a container, some routine events
(a host reboot, a recreated container, a new image) look to IDrive like a different or
freshly installed machine, and it logs the account out. This helper keeps the persistent
config volume (/opt/IDriveForLinux/idriveIt) in the state IDrive expects.

Commands:
  prepare      run by start.sh before IDrive starts (see cmd_prepare)
  healthcheck  the Docker HEALTHCHECK (see cmd_healthcheck)

IDrive keeps most of its state as JSON scrambled with its own encryption; the helper reads
and writes it with IDrive's own `idrive --utilities DECRYPT|ENCRYPT`, so the format stays
IDrive's business.
"""
from __future__ import annotations

import glob
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

BIN_DIR = "/opt/IDriveForLinux/bin"
IDRIVE_BIN = os.path.join(BIN_DIR, "idrive")
BASE_DIR = "/opt/IDriveForLinux/idriveIt"  # the persistent config volume
ORIG_TAR = "/opt/IDriveForLinux/idriveIt.orig.tar.gz"  # the volume's defaults, from the image build
IMAGE_VERSION_FILE = "/opt/IDriveForLinux/.image_version"  # IDrive version, recorded at build time
CACHE_DIR = os.path.join(BASE_DIR, "cache")
VERSION_FILE = os.path.join(CACHE_DIR, "version")  # IDrive's record of the installed version
UPDATE_INFO_FILE = os.path.join(CACHE_DIR, ".updateVersionInfo")  # IDrive's "update available" marker
IDRIVEUSER_FILE = os.path.join(CACHE_DIR, "idriveuser.txt")  # which account is configured, and isLoggedin
CRONTAB_FILE = os.path.join(BASE_DIR, "idrivecrontab.json")  # IDrive's own job schedule
INST_TRACK_FILE = os.path.join(BASE_DIR, "inst.track")  # IDrive's "fresh install" marker
PROFILE_ROOT = os.path.join(BASE_DIR, "user_profile", "root")  # one folder per account
BASE_TRACE_FILE = os.path.join(PROFILE_ROOT, ".trace", "traceLog.txt")

# Lock and PID files left behind by an unclean stop; IDrive refuses to start its services
# while they exist.
STALE_RUNTIME_FILES = (
    "/var/run/idrivecron.lock",
    os.path.join(PROFILE_ROOT, "idrivecron.lock"),
    os.path.join(PROFILE_ROOT, "idrivecron.pid"),
    os.path.join(PROFILE_ROOT, "dashboard.pid"),
    os.path.join(CACHE_DIR, "update.pid"),
    os.path.join(CACHE_DIR, "preupdate.pid"),
)

# Saved-password files IDrive itself requires; without them it logs out ("no_pwd_files").
# Accounts with a private encryption key also need PRIVATE_KEY_FILES.
PASSWORD_FILES = ("IDPWD", "IDENPWD", "IDPWD_SCH")
PRIVATE_KEY_FILES = ("IDPVT", "IDPVT_SCH")

# Docker kills a health check that overruns its --timeout (60 s in the Dockerfile), which
# would orphan a running `idrive --utilities DECRYPT`. The check works to this budget
# instead, so its own subprocess timeouts end any slow command first.
HEALTHCHECK_BUDGET_S = 40
_deadline: float | None = None  # monotonic time by which the current health check must end
_timed_out = False  # a decrypt was cut short to stay within the deadline


# ---------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------
def run_cmd(args: list[str], timeout: int = 30, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    """Run a command and capture its output as text. On timeout the command is killed."""
    return subprocess.run(args, input=input_text, capture_output=True, text=True, errors="replace", timeout=timeout)


def _cmd_timeout(default: int) -> int:
    """Per-command timeout, shortened to fit the health-check deadline when one is set."""
    if _deadline is None:
        return default
    return max(0, min(default, int(_deadline - time.monotonic())))


@contextmanager
def secure_temp_dir() -> Iterator[str]:
    """A private (0700) temporary folder, in RAM (/dev/shm) when possible, for decrypted files."""
    base = "/dev/shm" if os.path.isdir("/dev/shm") and os.access("/dev/shm", os.W_OK) else "/tmp"
    with tempfile.TemporaryDirectory(prefix="idrive_", dir=base) as tdir:
        os.chmod(tdir, 0o700)
        yield tdir


def get_idrive_version() -> str:
    """The image's IDrive version (recorded at build time; falls back to asking the binary)."""
    if os.path.isfile(IMAGE_VERSION_FILE):
        with open(IMAGE_VERSION_FILE, encoding="utf-8", errors="replace") as fh:
            cached = fh.read().strip()
        if cached:
            return cached
    res = run_cmd([IDRIVE_BIN, "--version"], timeout=15)
    if res.returncode != 0 or not res.stdout.strip():
        raise RuntimeError(f"Failed to query idrive --version (rc={res.returncode})")
    return res.stdout.strip()


def get_live_uptime() -> str | None:
    """The host's boot time, computed exactly the way IDrive does (`who -b | ... | date`)."""
    wb = run_cmd(["who", "-b"], timeout=10)
    parts = wb.stdout.split()
    if wb.returncode != 0 or len(parts) < 3:
        return None
    dp = run_cmd(["date", "+%Y-%m-%d %H:%M", "-f", "-"], timeout=10, input_text=" ".join(parts[2:]) + "\n")
    return (dp.stdout.strip() or None) if dp.returncode == 0 else None


# ---------------------------------------------------------------------------------------------
# Reading and writing IDrive's state files
# ---------------------------------------------------------------------------------------------
def decrypt_json_file(path: str) -> tuple[Any | None, bool]:
    """Read one of IDrive's JSON state files. Returns (data, was_plaintext).

    Most are encrypted; a few are plain JSON. A failed read is retried once, because IDrive
    may be rewriting the file at that moment.
    """
    global _timed_out
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        return None, False

    saw_timeout = False
    for attempt in range(2):
        if attempt > 0:
            time.sleep(0.5)
            if not os.path.isfile(path) or os.path.getsize(path) == 0:
                break

        with open(path, "rb") as fh:
            first = fh.read(1)
        if first in (b"{", b"["):
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    return json.load(fh), True
            except json.JSONDecodeError:
                continue

        with secure_temp_dir() as tdir:
            tmp_path = os.path.join(tdir, "dec.json")
            timeout = _cmd_timeout(30)
            if timeout < 1:
                saw_timeout = True
                break
            try:
                res = run_cmd([IDRIVE_BIN, "--utilities", "DECRYPT", path, tmp_path], timeout=timeout)
            except subprocess.TimeoutExpired:  # subprocess.run already killed the child
                saw_timeout = True
                continue
            if res.returncode != 0 or not os.path.isfile(tmp_path) or os.path.getsize(tmp_path) == 0:
                continue
            try:
                with open(tmp_path, encoding="utf-8", errors="replace") as fh:
                    return json.load(fh), False
            except json.JSONDecodeError:
                continue
    if saw_timeout:
        _timed_out = True
    return None, False


def encrypt_json_file_atomic(path: str, data: Any, force_plaintext: bool = False) -> None:
    """Write one of IDrive's state files (encrypted unless it was plain) without a partial file."""
    parent = os.path.dirname(path)
    orig_mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o660
    stage_fd, stage_path = tempfile.mkstemp(prefix=".idrive_stage_", dir=parent)
    os.close(stage_fd)
    try:
        with secure_temp_dir() as tdir:
            plain_path = os.path.join(tdir, "plain.json")
            fd = os.open(plain_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(data, fh, separators=(",", ":"))
            if force_plaintext:
                with open(plain_path, "rb") as src, open(stage_path, "wb") as dst:
                    dst.write(src.read())
            else:
                res = run_cmd([IDRIVE_BIN, "--utilities", "ENCRYPT", plain_path, stage_path], timeout=30)
                if res.returncode != 0 or not os.path.isfile(stage_path) or os.path.getsize(stage_path) == 0:
                    raise RuntimeError(f"Failed to encrypt {path}")
        os.chmod(stage_path, orig_mode)
        os.replace(stage_path, path)
    finally:
        if os.path.exists(stage_path):
            os.unlink(stage_path)


def cfg_get(cfg: dict[str, Any], key: str, default: Any = "") -> Any:
    """Read a CONFIGURATION_FILE field (stored as {"KEY": {"VALUE": ...}})."""
    val = cfg.get(key, default)
    if isinstance(val, dict) and "VALUE" in val:
        return val["VALUE"]
    return val


def cfg_set(cfg: dict[str, Any], key: str, value: Any) -> bool:
    """Set a CONFIGURATION_FILE field, keeping IDrive's VALUE wrapper. Returns True if it changed."""
    uses_wrapper = any(isinstance(v, dict) and "VALUE" in v for v in cfg.values())
    if key in cfg and isinstance(cfg[key], dict) and "VALUE" in cfg[key]:
        if cfg[key]["VALUE"] == value:
            return False
        cfg[key]["VALUE"] = value
        return True
    if cfg.get(key) == value:
        return False
    cfg[key] = {"VALUE": value} if uses_wrapper else value
    return True


def list_profile_dirs() -> list[str]:
    """Account folders under user_profile/root (hidden folders are IDrive's own)."""
    if not os.path.isdir(PROFILE_ROOT):
        return []
    return [
        os.path.join(PROFILE_ROOT, e)
        for e in sorted(os.listdir(PROFILE_ROOT))
        if not e.startswith(".") and os.path.isdir(os.path.join(PROFILE_ROOT, e))
    ]


def is_already_initialized() -> bool:
    """True once an account has been set up on this volume."""
    if os.path.isfile(IDRIVEUSER_FILE) and os.path.getsize(IDRIVEUSER_FILE) > 0:
        return True
    return any(os.path.isfile(os.path.join(p, "CONFIGURATION_FILE")) for p in list_profile_dirs())


def get_idriveuser_state() -> tuple[str, int]:
    """(account id, isLoggedin) from cache/idriveuser.txt."""
    data, _ = decrypt_json_file(IDRIVEUSER_FILE)
    if not isinstance(data, dict):
        return "", 0
    entry = data.get("root")
    if not isinstance(entry, dict):
        entry = next((v for v in data.values() if isinstance(v, dict)), None)
    if not isinstance(entry, dict):
        return "", 0
    user_id = str(entry.get("userid") or entry.get("username") or "").strip()
    try:
        logged_in = int(entry.get("isLoggedin", 0) or 0)
    except (TypeError, ValueError):
        logged_in = 0
    return user_id, logged_in


def resolve_profile_dir(user_id: str) -> str | None:
    """The account's folder: the one named after user_id, else the only configured one."""
    if user_id:
        for pdir in list_profile_dirs():
            if os.path.basename(pdir).lower() == user_id.lower():
                return pdir
    pdirs = [p for p in list_profile_dirs() if os.path.isfile(os.path.join(p, "CONFIGURATION_FILE"))]
    return pdirs[0] if len(pdirs) == 1 else None


def get_cron_status(cron_data: Any, user_id: str) -> str | None:
    """The account's schedule status in idrivecrontab.json (IDrive sets INACTIVE to stop all jobs)."""
    if not isinstance(cron_data, dict) or not isinstance(cron_data.get("root"), dict):
        return None
    acct = next((v for k, v in cron_data["root"].items() if k.lower() == user_id.lower()), None) if user_id else None
    try:
        return str(acct["otherInfo"]["settings"]["status"])
    except (TypeError, KeyError):
        return None


# ---------------------------------------------------------------------------------------------
# prepare: keep the volume consistent with the image before IDrive starts
# ---------------------------------------------------------------------------------------------
def cleanup_stale_pids() -> int:
    """Remove lock/PID files from an unclean stop. Returns how many were removed."""
    removed = 0
    for path in list(STALE_RUNTIME_FILES) + glob.glob(os.path.join(PROFILE_ROOT, "*", "dashboard.pid")):
        if os.path.isfile(path):
            os.unlink(path)
            removed += 1
    return removed


def normalize_configurations() -> dict[str, Any]:
    """Fix each account's CONFIGURATION_FILE:

    - UPTIME: IDrive saves the host's boot time and, for accounts not on IDrive's WebSocket
      remote management (RMWS != yes), logs out ("dashboard_uptime") when it changes. Writing
      the current boot time first means a host reboot no longer logs the account out.
    - AUTOSOFTWAREUPDATE: IDrive's self-update logs the account out afterwards ("app_update")
      and would patch the container instead of the image, so it is switched off.
    """
    live_uptime = get_live_uptime()
    stats: dict[str, Any] = {"profiles": 0, "uptime_synced": False, "rmsh_warning": False, "rmws": "unknown"}
    for pdir in list_profile_dirs():
        cfg_path = os.path.join(pdir, "CONFIGURATION_FILE")
        if not os.path.isfile(cfg_path) or os.path.getsize(cfg_path) == 0:
            continue
        cfg, was_plain = decrypt_json_file(cfg_path)
        if not isinstance(cfg, dict):
            print("[init] WARNING: Unable to read CONFIGURATION_FILE; leaving it unchanged.", file=sys.stderr)
            continue
        stats["profiles"] += 1
        modified = False
        if live_uptime is not None and cfg_set(cfg, "UPTIME", live_uptime):
            modified = stats["uptime_synced"] = True
        if str(cfg_get(cfg, "AUTOSOFTWAREUPDATE", "")) != "0" and cfg_set(cfg, "AUTOSOFTWAREUPDATE", 0):
            modified = True
        # IDrive 3.17.1+ checks TLS server names against RMSH; logins made by older versions
        # left it empty, and only a new login fills it in.
        if not str(cfg_get(cfg, "RMSH", "") or "").strip() and str(cfg_get(cfg, "RMIH", "") or "").strip():
            stats["rmsh_warning"] = True
        stats["rmws"] = str(cfg_get(cfg, "RMWS", "unknown") or "unknown")
        if modified:
            encrypt_json_file_atomic(cfg_path, cfg, force_plaintext=was_plain)
    return stats


def _disable_launch_update_jobs(node: Any) -> bool:
    """Disable every scheduled `--launch-update` job (IDrive's automatic self-update)."""
    changed = False
    if isinstance(node, dict):
        settings = node.get("settings")
        if "--launch-update" in str(node.get("cmd", "")) and isinstance(settings, dict):
            if settings.get("status") == "enabled":
                settings["status"] = "disabled"
                changed = True
        for val in node.values():
            if isinstance(val, dict) and _disable_launch_update_jobs(val):
                changed = True
    return changed


def config_on_anonymous_volume() -> bool:
    """True when the config folder is an anonymous Docker volume (named by a 64-character ID).

    Docker creates one for the image's VOLUME when nothing is mounted there. It survives
    restarts and image updates, but `docker compose down` + `up` or `docker rm -v` start over
    with an empty one: logged out, no schedule. A named volume or a host folder does not."""
    try:
        with open("/proc/self/mountinfo", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                fields = line.split()
                if len(fields) > 4 and fields[4] == BASE_DIR:
                    return re.search(r"/volumes/[0-9a-f]{64}/_data$", fields[3]) is not None
    except OSError:
        pass
    return False


def cmd_prepare(quiet: bool = False) -> int:
    """Bring the volume in line with the image. Safe to run on every start."""
    if not os.path.isfile(ORIG_TAR):
        print(f"[init] ERROR: Missing base archive {ORIG_TAR}", file=sys.stderr)
        return 1
    initialized = is_already_initialized()
    if not quiet and config_on_anonymous_volume():
        print(
            f"[init] WARNING: IDrive's config ({BASE_DIR}) is on an anonymous Docker volume. It is lost by "
            "`docker compose down` or `docker rm -v`, and with it the login and schedule. Mount a named volume "
            f"(-v idrive_config:{BASE_DIR}) or a host folder there.",
            file=sys.stderr,
        )

    # 1. Restore files missing from the volume (first start, or files a newer image added)
    #    without touching existing ones. inst.track is IDrive's "fresh install" marker: on a
    #    set-up volume it must not come back, or the next `--account-setting` treats the
    #    account as new and deletes its schedules.
    cmd = ["tar", "--skip-old-files"] + (["--exclude=idriveIt/inst.track"] if initialized else [])
    res = run_cmd(cmd + ["-xzf", ORIG_TAR, "-C", "/opt/IDriveForLinux"], timeout=60)
    if res.returncode != 0:
        print(f"[init] ERROR: Base archive extraction failed: {res.stderr.strip()}", file=sys.stderr)
        return 1
    if initialized and os.path.exists(INST_TRACK_FILE):
        os.unlink(INST_TRACK_FILE)
        if not quiet:
            print("[init] Removed stale inst.track from initialized volume.")

    # 2. The idevsutil transfer programs live in the volume, so they must be refreshed to
    #    match the image's IDrive version (--unlink-first replaces them even while in use).
    res = run_cmd(
        ["tar", "--unlink-first", "-xzf", ORIG_TAR, "-C", "/opt/IDriveForLinux", "--wildcards", "idriveIt/idevsutil*"],
        timeout=60,
    )
    if res.returncode != 0:
        print(f"[init] ERROR: idevsutil refresh failed: {res.stderr.strip()}", file=sys.stderr)
        return 1

    # 3. Record the image's IDrive version as installed, and clear the "update available"
    #    marker, so IDrive treats this version as current.
    os.makedirs(CACHE_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(BASE_TRACE_FILE), exist_ok=True)
    if not os.path.exists(BASE_TRACE_FILE):
        open(BASE_TRACE_FILE, "w", encoding="utf-8").close()  # start.sh tails it
    version = get_idrive_version()
    with open(VERSION_FILE, "w", encoding="utf-8") as fh:
        fh.write(version)
    if os.path.exists(UPDATE_INFO_FILE):
        os.unlink(UPDATE_INFO_FILE)

    # 4. Clear stale locks, then fix the account's config and schedule.
    stale_removed = cleanup_stale_pids()
    user_id, logged_in = get_idriveuser_state()
    cfg_stats = normalize_configurations()
    cron_data, was_plain = decrypt_json_file(CRONTAB_FILE)
    launch_update_disabled = False
    if isinstance(cron_data, dict) and _disable_launch_update_jobs(cron_data):
        encrypt_json_file_atomic(CRONTAB_FILE, cron_data, force_plaintext=was_plain)
        launch_update_disabled = True
    cron_status = get_cron_status(cron_data, user_id) or "none"

    if cfg_stats["rmsh_warning"]:
        print(
            "[init] WARNING: RMSH is empty in CONFIGURATION_FILE. IDrive 3.17.1+ needs it to verify its "
            "servers; log in again once with `idrive --login`.",
            file=sys.stderr,
        )
    if not quiet:
        print(
            "[init] Summary: "
            f"version={version} configured={bool(user_id and cfg_stats['profiles'])} "
            f"logged_in={logged_in == 1} rmws={cfg_stats['rmws']} cron_status={cron_status} "
            f"uptime_synced={cfg_stats['uptime_synced']} launch_update_disabled={launch_update_disabled} "
            f"stale_pids_cleaned={stale_removed}"
        )
    return 0


# ---------------------------------------------------------------------------------------------
# healthcheck
# ---------------------------------------------------------------------------------------------
def collect_health_state() -> tuple[bool, str]:
    """(healthy, reason).

    Always: IDrive's service (/etc/idrivecron) runs and the volume records the image's IDrive
    version. Once an account is set up, also: it is logged in (isLoggedin=1, which IDrive
    itself sets to 0 on any logout), its saved-password files exist (and both private key
    files, once either exists), and its schedule is not INACTIVE. Checking only the process
    is not enough: it keeps running after a logout.

    Costs two decrypts (cache/idriveuser.txt, idrivecrontab.json).
    """
    # idrivecron replaces itself with a new process at times, with a few seconds in between
    # where none runs; look again for up to 10 s before calling it stopped.
    for attempt in range(6):
        if run_cmd(["pgrep", "-f", "/etc/idrivecron"], timeout=5).returncode == 0:
            break
        if attempt == 5:
            return False, "idrivecron process is not running"
        time.sleep(2)
    try:
        bin_ver = get_idrive_version()
    except subprocess.TimeoutExpired:
        _timed_out = True
        return False, "idrive --version timed out"
    file_ver = ""
    if os.path.isfile(VERSION_FILE):
        with open(VERSION_FILE, encoding="utf-8", errors="replace") as fh:
            file_ver = fh.read().strip()
    if file_ver != bin_ver:
        return False, f"cache/version ({file_ver or 'missing'}) != image ({bin_ver})"
    if not is_already_initialized():
        return True, "waiting for account setup"

    user_id, logged_in = get_idriveuser_state()
    pdir = resolve_profile_dir(user_id)
    if not (user_id and pdir):
        return False, "account is not configured"
    if logged_in != 1:
        return False, "account is logged out (isLoggedin=0)"
    userinfo = os.path.join(pdir, ".userInfo")

    def present(name: str) -> bool:
        path = os.path.join(userinfo, name)
        return os.path.isfile(path) and os.path.getsize(path) > 0

    required = list(PASSWORD_FILES)
    if any(os.path.exists(os.path.join(userinfo, f)) for f in PRIVATE_KEY_FILES):
        required += PRIVATE_KEY_FILES
    if not all(present(f) for f in required):
        return False, "saved-password files in .userInfo are missing or empty"
    cron_data, _ = decrypt_json_file(CRONTAB_FILE)
    if (get_cron_status(cron_data, user_id) or "").upper() == "INACTIVE":
        return False, "backup schedule is INACTIVE"
    return True, "ok"


def cmd_healthcheck() -> int:
    """Docker HEALTHCHECK: exit 0 when healthy, else print the reason and exit 1."""
    global _deadline, _timed_out
    _timed_out = False
    _deadline = time.monotonic() + HEALTHCHECK_BUDGET_S
    healthy, reason = collect_health_state()
    if _timed_out or time.monotonic() >= _deadline:
        print(f"[healthcheck] UNHEALTHY: check took longer than {HEALTHCHECK_BUDGET_S}s (IDrive busy?)", file=sys.stderr)
        return 1
    if not healthy:
        print(f"[healthcheck] UNHEALTHY: {reason}", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    commands = {"prepare": cmd_prepare, "healthcheck": cmd_healthcheck}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        print(f"Usage: idrive-init.py {{{'|'.join(commands)}}}", file=sys.stderr)
        return 2
    return commands[sys.argv[1]]()


if __name__ == "__main__":
    sys.exit(main())
