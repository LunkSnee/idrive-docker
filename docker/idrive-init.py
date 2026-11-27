#!/usr/bin/env python3
"""Container helper for idrive-docker.

IDrive for Linux was written for a normal machine. In a container, some routine events
(a host reboot, a recreated container, a new image) look to IDrive like a different or
freshly installed machine, and it logs the account out. This helper keeps the persistent
config volume (/opt/IDriveForLinux/idriveIt) in the state IDrive expects.

Commands:
  prepare      run by start.sh before IDrive starts (see cmd_prepare)
  autologin    run by start.sh after prepare: optional automated setup and re-login
               from credentials (see cmd_autologin)
  healthcheck  the Docker HEALTHCHECK (see cmd_healthcheck)
  watchdog     run by start.sh every IDRIVE_WATCHDOG_INTERVAL seconds: asks for a restart
               (exit 3) when a logout needs automated login again (see cmd_watchdog)
  reset-login  clear the automated-login backoff/pause (see cmd_reset_login)

IDrive keeps most of its state as JSON scrambled with its own encryption; the helper reads
and writes it with IDrive's own `idrive --utilities DECRYPT|ENCRYPT`, so the format stays
IDrive's business.
"""
from __future__ import annotations

import base64
import glob
import hashlib
import hmac
import json
import os
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Any
from urllib.parse import parse_qs, urlparse

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
    global _timed_out
    # idrivecron replaces itself with a new process at times, with a few seconds in between
    # where none runs; look again for up to 10 s before calling it stopped.
    for attempt in range(6):
        timeout = _cmd_timeout(5)
        if timeout < 1:
            _timed_out = True
            return False, "healthcheck budget exhausted"
        try:
            if run_cmd(["pgrep", "-f", "/etc/idrivecron"], timeout=timeout).returncode == 0:
                break
        except subprocess.TimeoutExpired:
            _timed_out = True
            return False, "pgrep timed out"
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
        # With credentials configured, setup was supposed to happen at start, so it failed.
        if credentials_configured():
            return False, "account is not configured (automated setup failed; see docker logs)"
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


# ---------------------------------------------------------------------------------------------
# autologin: optional automated setup and re-login from credentials (Docker secrets)
#
# IDrive has no non-interactive login, so the helper runs `idrive --account-setting` (first
# setup of an empty volume) or `idrive --login` (an existing account that is logged out)
# in a pseudo-terminal and answers its prompts. The prompts are matched by their text, so a
# change in IDrive's wording shows up as a failed login with the transcript in the log.
# ---------------------------------------------------------------------------------------------
BACKUP_LOCATION_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
MENU_PROMPT = r"(?:Enter your choice|Enter the\s+'?S\.No\.?'?[^\n:]*):"

# IDrive output that means the login cannot succeed; seeing one stops the interaction.
FAILURE_PATTERNS = (
    r"Invalid username or Password",
    r"Invalid encryption key",
    r"failed to authenticate user",
    r"Unable to Create Backup Location",
    r"Unable to find your backup location",
    r"Two-factor authentication has failed",
    r"exceeded the number of attempts",
    r"maximum count for receiving OTP",
    r"RATE_LIMITER_BLOCKED",
    r"failed to verify your account",
    r"encryption verification failed",
    r"failed to encode private key",
    r"account has been (?:blocked|cancell?ed|canceled|expired)",
    r"already logged in\. Logout using",
)

# Failures that retrying with the same settings cannot fix: retrying only risks a lockout.
CREDENTIAL_ERRORS = (
    r"Invalid username or Password",
    r"Invalid encryption key",
    r"failed to authenticate user",
    r"Two-factor authentication has failed",
    r"failed to verify your account",
    r"encryption verification failed",
    r"failed to encode private key",
    r"account has been (?:blocked|cancell?ed|canceled|expired)",
)
# IDrive's own lockouts: wait the maximum backoff before trying again.
RATE_LIMIT_ERRORS = (r"exceeded the number of attempts", r"maximum count for receiving OTP", r"RATE_LIMITER_BLOCKED")

# Record of automated login attempts on the config volume. Plain JSON without secrets: times,
# counts, the last error, a salted hash of the settings (to notice when they change) and the
# last 2FA time step used. It survives restarts, so restarts cannot hammer IDrive's servers.
LOGIN_STATE_FILE = os.path.join(CACHE_DIR, "autologin-state.json")
BACKOFF_BASE_S = 5 * 60
BACKOFF_MAX_S = 6 * 60 * 60
WATCHDOG_RESTART_RC = 3  # start.sh exits with this code when the watchdog asks for a restart


@dataclass
class LoginResult:
    """Outcome of one automated --login / --account-setting run."""

    ok: bool
    category: str = ""  # "credentials", "config", "rate-limited" or "error" when not ok
    message: str = ""
    totp_counter: int | None = None  # last 2FA time step used, persisted across restarts


def classify_failure(output: str) -> str:
    """'credentials', 'rate-limited' or 'error' for a failed login transcript."""
    if any(re.search(p, output, re.I) for p in CREDENTIAL_ERRORS):
        return "credentials"
    if any(re.search(p, output, re.I) for p in RATE_LIMIT_ERRORS):
        return "rate-limited"
    return "error"


def load_login_state() -> dict[str, Any]:
    try:
        with open(LOGIN_STATE_FILE, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_login_state(state: dict[str, Any]) -> None:
    """Write the record atomically (mode 0600, from mkstemp)."""
    os.makedirs(CACHE_DIR, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(prefix=".autologin-state.", dir=CACHE_DIR)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2, sort_keys=True)
    os.replace(tmp_path, LOGIN_STATE_FILE)


def settings_fingerprint(state: dict[str, Any], s: LoginSettings) -> str:
    """Salted, slow hash of the login settings; only used to notice that they changed."""
    salt_bytes = b""
    if isinstance(state.get("salt"), str) and state["salt"]:
        try:
            salt_bytes = bytes.fromhex(state["salt"])
        except ValueError:
            salt_bytes = b""
    if not salt_bytes:
        salt_bytes = os.urandom(16)
        state["salt"] = salt_bytes.hex()
    material = "\0".join([s.account, s.password, s.enc_key, s.totp_raw, s.enc_type, s.backup_loc]).encode("utf-8")
    return hashlib.pbkdf2_hmac("sha256", material, salt_bytes, 200_000).hex()


def backoff_seconds(failures: int) -> int:
    """5 min, 10 min, 20 min, ... capped at 6 h."""
    return 0 if failures <= 0 else min(BACKOFF_BASE_S * 2 ** (failures - 1), BACKOFF_MAX_S)


def login_gate(state: dict[str, Any], now: float) -> str | None:
    """Why an automated login must not be attempted now, or None when it may go ahead."""
    if state.get("blocked"):
        return (
            f"paused after: {str(state.get('last_error') or 'a credential error').rstrip('.')}. "
            "Fix the credentials/settings and restart the container, or run 'idrive-init.py reset-login' to retry the same ones"
        )
    wait_s = int(state.get("last_attempt", 0)) + backoff_seconds(int(state.get("failures", 0))) - now
    if wait_s > 0:
        return f"backing off after {state.get('failures')} failed attempt(s); next attempt in {int(wait_s // 60) + 1} min"
    return None


def record_login_result(state: dict[str, Any], result: LoginResult) -> None:
    """Persist an attempt's outcome: success clears the record; credential and configuration
    errors pause automated login; IDrive's rate limits wait the maximum backoff."""
    if result.totp_counter is not None:
        state["last_totp_counter"] = result.totp_counter
    if result.ok:
        state.update({"failures": 0, "blocked": False, "last_error": "", "last_success": int(time.time())})
        state.pop("problem_since", None)
        state.pop("last_notice", None)
    else:
        state["failures"] = int(state.get("failures", 0)) + 1
        state["last_error"] = result.message
        if result.category in ("credentials", "config"):
            state["blocked"] = True
        elif result.category == "rate-limited":
            state["failures"] = max(state["failures"], 8)
    save_login_state(state)


def autologin_config_error(message: str) -> int:
    """Report a configuration problem and pause automated login until the settings change.
    (Otherwise the watchdog would restart the container over and over for nothing.)"""
    print(f"[autologin] ERROR: {message}", file=sys.stderr)
    state = load_login_state()
    state.update({"blocked": True, "last_error": message})
    state.pop("fingerprint", None)  # any corrected configuration then counts as changed
    save_login_state(state)
    return 1


@dataclass
class LoginSettings:
    """Credentials and first-setup choices, read from the environment or secret files."""

    account: str
    password: str
    enc_type: str  # DEFAULT or PRIVATE (first setup only)
    enc_key: str
    totp_spec: tuple[bytes, int, int, str] | None  # parsed authenticator setup key
    backup_loc: str  # backup location name for first setup ("" = IDrive's default)
    totp_raw: str  # raw TOTP secret/URI for settings fingerprinting
    secrets: list[str]  # values to redact from any transcript that is printed


def read_env_or_file(var_name: str) -> str:
    """VAR_FILE (a Docker secret file) if set, else VAR. Trailing newlines are dropped."""
    file_var = f"{var_name}_FILE"
    secret_path = os.environ.get(file_var, "").strip()
    if secret_path:
        if not os.path.isfile(secret_path):
            raise FileNotFoundError(f"{file_var} points to missing file: {secret_path}")
        with open(secret_path, encoding="utf-8") as fh:
            return fh.read().rstrip("\r\n")
    return os.environ.get(var_name, "")


def credentials_configured() -> bool:
    """True when automated login is configured (used by the health check)."""
    return any(
        os.environ.get(v, "").strip()
        for v in ("IDRIVE_ACCOUNT", "IDRIVE_ACCOUNT_FILE", "IDRIVE_PASSWORD", "IDRIVE_PASSWORD_FILE")
    )


def scrub(text: str, secrets: list[str]) -> str:
    """Redact secrets and the account name (and its email parts) from text that gets printed."""
    out = text
    for secret in secrets:
        if not secret:
            continue
        out = out.replace(secret, "<REDACTED>")
        if "@" in secret:
            local, domain = secret.split("@", 1)
            out = re.sub(re.escape(secret), "<REDACTED>", out, flags=re.I)
            if local:
                # Whole words only, so a short local part ("bob") does not mangle unrelated text.
                out = re.sub(rf"(?<![\w.+-]){re.escape(local)}(?![\w.+-])", "<REDACTED>", out, flags=re.I)
            if domain:
                out = re.sub(re.escape(f"@{domain}"), "@<REDACTED>", out, flags=re.I)
    return out


def strip_ansi(text: str) -> str:
    """Remove terminal escape sequences from PTY output."""
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b\([A-Za-z0-9]|\r", "", text)


def parse_totp_secret(raw: str) -> tuple[bytes, int, int, str]:
    """Parse a raw Base32 TOTP secret or otpauth://totp URI into (key, digits, period, algorithm)."""
    text = raw.strip()
    digits = 6
    period = 30
    algorithm = "SHA1"

    if text.lower().startswith("otpauth://"):
        parsed = urlparse(text)
        if parsed.netloc.lower() != "totp":
            raise ValueError("Invalid IDRIVE_TOTP_SECRET: only otpauth://totp URIs are supported.")
        qs = parse_qs(parsed.query)
        secret_b32 = (qs.get("secret") or [""])[0].strip()
        if "digits" in qs and qs["digits"][0].strip():
            try:
                digits = int(qs["digits"][0].strip())
            except ValueError:
                raise ValueError("Invalid IDRIVE_TOTP_SECRET URI: invalid digits parameter.") from None
        if "period" in qs and qs["period"][0].strip():
            try:
                period = int(qs["period"][0].strip())
            except ValueError:
                raise ValueError("Invalid IDRIVE_TOTP_SECRET URI: invalid period parameter.") from None
        if "algorithm" in qs and qs["algorithm"][0].strip():
            algorithm = qs["algorithm"][0].strip().upper()
    else:
        secret_b32 = text

    if digits not in (6, 7, 8):
        raise ValueError("Invalid IDRIVE_TOTP_SECRET: digits must be 6, 7, or 8.")
    if period <= 0:
        raise ValueError("Invalid IDRIVE_TOTP_SECRET: period must be positive.")
    hash_algos = {"SHA1": hashlib.sha1, "SHA256": hashlib.sha256, "SHA512": hashlib.sha512}
    if algorithm not in hash_algos:
        raise ValueError("Invalid IDRIVE_TOTP_SECRET: unsupported TOTP algorithm.")

    compact = re.sub(r"[\s-]+", "", secret_b32).upper()
    if not compact:
        raise ValueError("Invalid IDRIVE_TOTP_SECRET: secret is empty.")
    padded = compact + ("=" * ((-len(compact)) % 8))
    try:
        key = base64.b32decode(padded, casefold=True)
    except Exception:
        raise ValueError(
            "Invalid IDRIVE_TOTP_SECRET: expected a valid Base32 secret or otpauth://totp URI."
        ) from None
    if not key:
        raise ValueError("Invalid IDRIVE_TOTP_SECRET: decoded secret key is empty.")
    return key, digits, period, algorithm


def generate_totp(
    spec: tuple[bytes, int, int, str],
    now: float | None = None,
    min_remaining_s: float = 5.0,
    min_counter: int | None = None,
) -> tuple[str, int]:
    """Generate an RFC 6238 TOTP code, avoiding expiring boundaries when reading live wall time."""
    key, digits, period, algorithm = spec
    hash_fn = {"SHA1": hashlib.sha1, "SHA256": hashlib.sha256, "SHA512": hashlib.sha512}[algorithm]

    if now is None:
        cur = time.time()
        if min_counter is not None:
            cur_counter = int(cur // period)
            if cur_counter < min_counter:
                wait_s = (min_counter * period) - cur + 0.5
                if wait_s > 0:
                    time.sleep(wait_s)
                cur = time.time()
        remaining = period - (cur % period)
        if remaining < min_remaining_s:
            time.sleep(remaining + 0.5)
            cur = time.time()
    else:
        cur = now

    counter = int(cur // period)
    msg = struct.pack(">Q", counter)
    digest = hmac.new(key, msg, hash_fn).digest()
    offset = digest[-1] & 0x0F
    code_int = (struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF) % (10**digits)
    return f"{code_int:0{digits}d}", counter


def _terminate_child(pid: int) -> int:
    """Terminate and reap a spawned child PID cleanly."""
    for sig in (15, 9):
        try:
            os.kill(pid, sig)
        except OSError:
            break
        if sig == 15:
            for _ in range(4):
                try:
                    wpid, status = os.waitpid(pid, os.WNOHANG)
                    if wpid == pid:
                        return os.waitstatus_to_exitcode(status)
                except ChildProcessError:
                    return 0
                time.sleep(0.1)
    try:
        _, status = os.waitpid(pid, 0)
        return os.waitstatus_to_exitcode(status)
    except OSError:
        return 1


def pty_interact(args: list[str], handler, secrets: list[str], timeout_s: int = 180) -> tuple[int, str]:
    """Execute `idrive <args>` under a PTY, dispatching output chunks to handler(unseen, write_fn)."""
    cmd = [IDRIVE_BIN] + args
    pid, master_fd = pty.fork()
    if pid == 0:
        try:
            os.execv(cmd[0], cmd)
        except OSError:
            os._exit(127)

    unseen = ""
    full_log: list[str] = []
    start = time.monotonic()
    detected_error: str | None = None
    aborted = False
    rc: int | None = None

    def write_line(text: str) -> None:
        time.sleep(0.2)
        os.write(master_fd, (text + "\n").encode("utf-8"))

    try:
        while True:
            if time.monotonic() - start > timeout_s:
                full_log.append(f"\n[PTY TIMEOUT after {timeout_s}s]")
                rc = 124
                break

            rlist, _, _ = select.select([master_fd], [], [], 0.5)
            if master_fd in rlist:
                try:
                    chunk = os.read(master_fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break

                txt = strip_ansi(chunk.decode("utf-8", errors="replace"))
                unseen += txt
                full_log.append(txt)

                for err_pat in FAILURE_PATTERNS:
                    if re.search(err_pat, unseen, re.I):
                        detected_error = err_pat
                        break
                if detected_error:
                    # Brief drain so the full error line is captured before terminating child.
                    drain_r, _, _ = select.select([master_fd], [], [], 0.5)
                    if master_fd in drain_r:
                        try:
                            extra = os.read(master_fd, 4096)
                            if extra:
                                full_log.append(strip_ansi(extra.decode("utf-8", errors="replace")))
                        except OSError:
                            pass
                    break

                result = handler(unseen, write_line)
                if result == "ABORT":
                    aborted = True
                    break
                if isinstance(result, int):
                    unseen = unseen[result:]
            else:
                wpid, status = os.waitpid(pid, os.WNOHANG)
                if wpid == pid:
                    rc = os.waitstatus_to_exitcode(status)
                    break
    finally:
        try:
            os.close(master_fd)
        except OSError:
            pass
        if rc is None and not detected_error and not aborted:
            # Give a child that just closed its PTY a brief moment to exit cleanly.
            for _ in range(30):
                try:
                    wpid, status = os.waitpid(pid, os.WNOHANG)
                    if wpid == pid:
                        rc = os.waitstatus_to_exitcode(status)
                        break
                except ChildProcessError:
                    rc = 0
                    break
                time.sleep(0.1)
        if rc is None:
            rc = _terminate_child(pid)

    if (detected_error or aborted) and rc == 0:
        rc = 1
    return rc, scrub("".join(full_log), secrets)


def parse_device_table(text: str) -> list[tuple[str, str]]:
    """Parse `(S.No., Device name)` rows from IDrive's existing-devices table."""
    rows: list[tuple[str, str]] = []
    for line in text.splitlines():
        m = re.match(r"^\s*(\d+)\s+(.+?)\s*$", line)
        if not m:
            continue
        sno = m.group(1)
        rest = m.group(2)
        rest_no_os = re.sub(r"\s+(?:Linux|Windows|Mac|macOS|FreeBSD|Unix)\b.*$", "", rest, flags=re.I).strip()
        dev_name = (rest_no_os or re.split(r"\s+", rest)[0]).strip()
        if dev_name and dev_name.lower() != "device":
            rows.append((sno, dev_name))
    return rows


def stop_idrive_daemons() -> None:
    """Stop any stray IDrive background services spawned by interactive commands."""
    for pat in ("/etc/idrivecron", "/opt/IDriveForLinux/"):
        run_cmd(["pkill", "-TERM", "-f", pat], timeout=5)
    time.sleep(1.0)
    for pat in ("/etc/idrivecron", "/opt/IDriveForLinux/"):
        run_cmd(["pkill", "-KILL", "-f", pat], timeout=5)


def match_device_sno(rows: list[tuple[str, str]], target: str) -> str | None:
    """Match target device name against parsed table rows, handling IDrive 24-char trimming."""
    for sno, dev in rows:
        if dev == target:
            return sno
    for sno, dev in rows:
        if dev.lower() == target.lower():
            return sno
    if len(target) > 21:
        for sno, dev in rows:
            if dev.endswith("...") and target.startswith(dev[:-3]):
                return sno
    return None


def rename_backup_location_if_needed(profile_dir: str, desired_name: str, secrets: list[str]) -> bool:
    """Rename server backup location via DASHBOARD7 and sync CONFIGURATION_FILE."""
    cfg_path = os.path.join(profile_dir, "CONFIGURATION_FILE")
    cfg, was_plain = decrypt_json_file(cfg_path)
    if not isinstance(cfg, dict):
        print("[autologin] WARNING: Could not read CONFIGURATION_FILE to check backup location.", file=sys.stderr)
        return False

    cur_bl = str(cfg_get(cfg, "BACKUPLOCATION", "") or "")
    if "#" not in cur_bl:
        return True
    prefix, current_nick = cur_bl.split("#", 1)
    if current_nick == desired_name:
        return True

    res = run_cmd([IDRIVE_BIN, "--utilities", "DASHBOARD7", desired_name], timeout=60)
    if res.returncode != 0 or "SUCCESS" not in (res.stdout + res.stderr):
        err_detail = scrub((res.stdout + res.stderr).strip(), secrets)
        print(f"[autologin] ERROR: DASHBOARD7 rename failed (rc={res.returncode}): {err_detail}", file=sys.stderr)
        return False

    new_bl = f"{prefix}#{desired_name}"
    cfg_set(cfg, "BACKUPLOCATION", new_bl)
    cur_rf = str(cfg_get(cfg, "RESTOREFROM", "") or "")
    if cur_rf == cur_bl or not cur_rf:
        cfg_set(cfg, "RESTOREFROM", new_bl)
    encrypt_json_file_atomic(cfg_path, cfg, force_plaintext=was_plain)
    print(f"[autologin] Renamed backup location to {desired_name!r}.")
    return True




def _base_auth_state(last_totp_counter: int | None = None) -> dict[str, Any]:
    """Which shared prompts have been answered (each is answered once)."""
    return {
        "method": False,
        "user": False,
        "pwd": False,
        "enter_key": False,
        "confirm": 0,
        "missing_key": False,
        "totp_menu_count": 0,
        "otp_attempts": 0,
        # Persisted across restarts, so a quick restart never re-sends a code IDrive already used.
        "last_totp_counter": last_totp_counter,
        "missing_totp": False,
        "totp_failed": False,
        "trust_answered": False,
    }


def handle_auth_prompts(tail: str, buf_len: int, state: dict[str, Any], write_fn, s: LoginSettings) -> int | str | None:
    """Answer the prompts --login and --account-setting share: login method, username,
    password, 2FA (authenticator code), "trust this device" (always yes), and the encryption
    key. Returns how much output was consumed, "ABORT", or None if nothing matched."""
    if re.search(rf"1\)\s*Login using IDrive credentials[\s\S]*?{MENU_PROMPT}", tail, re.I) and not state["method"]:
        state["method"] = True
        write_fn("1")
        return buf_len
    if re.search(r"Enter your IDrive username\s*:", tail, re.I) and not state["user"]:
        state["user"] = True
        write_fn(s.account)
        return buf_len
    if re.search(r"Enter your IDrive password\s*:", tail, re.I) and not state["pwd"]:
        state["pwd"] = True
        write_fn(s.password)
        return buf_len
    is_2fa_menu = bool(
        re.search(rf"(?:Two-factor Authentication|Building menu for verification)[\s\S]*?{MENU_PROMPT}", tail, re.I)
        or (re.search(r"^\s*1\)\s*Enter one-time code\b", tail, re.M | re.I) and re.search(MENU_PROMPT, tail, re.I))
    )
    if is_2fa_menu:
        if s.totp_spec is None:
            state["missing_totp"] = True
            return "ABORT"
        choice = None
        for m in re.finditer(r"^\s*(\d+)\)\s*(.+)$", tail, re.M):
            if re.search(r"one.?time\s*code|authenticator|totp|time.?based|\botp\b", m.group(2), re.I):
                choice = m.group(1)
                break
        if choice is None or state["totp_menu_count"] >= 2:
            state["totp_failed"] = True
            return "ABORT"
        state["totp_menu_count"] += 1
        write_fn(choice)
        return buf_len
    if re.search(r"\bEnter\s+(?:the\s+)?(?:(?:one.?time|verification|security|OTP)\s+)?code\s*:", tail, re.I):
        if s.totp_spec is None:
            state["missing_totp"] = True
            return "ABORT"
        if state["otp_attempts"] >= 2:  # a second rejected code means the key or the clock is wrong
            state["totp_failed"] = True
            return "ABORT"
        min_counter = (state["last_totp_counter"] + 1) if state["last_totp_counter"] is not None else None
        code, counter = generate_totp(s.totp_spec, min_counter=min_counter)
        s.secrets.append(code)
        state["last_totp_counter"] = counter
        state["otp_attempts"] += 1
        write_fn(code)
        return buf_len
    if re.search(r"(?:do you want to trust|trust this (?:device|computer|machine))[\s\S]*?(?:Enter your choice|\(y/n\))", tail, re.I) and not state["trust_answered"]:
        state["trust_answered"] = True
        write_fn("y")
        return buf_len
    if re.search(r"Enter your encryption key\s*:", tail, re.I) and not state["enter_key"]:
        if not s.enc_key:
            state["missing_key"] = True
            return "ABORT"
        state["enter_key"] = True
        write_fn(s.enc_key)
        return buf_len
    if re.search(r"do you want to login as.*\(y/n\)[\s\S]*?Enter your choice\s*:", tail, re.I) and state["confirm"] < 2:
        state["confirm"] += 1
        write_fn("y")
        return buf_len
    return None


def _report_failure(state: dict[str, Any], rc: int, out: str, logged_in: int, cmd: str) -> LoginResult:
    """Print why an automated login failed (the transcript is already scrubbed) and classify it."""
    if state["missing_key"]:
        msg, category = "IDRIVE_ENCRYPTION_KEY is required for this account's private encryption key", "config"
    elif state["missing_totp"]:
        msg = f"two-factor authentication requested; set IDRIVE_TOTP_SECRET_FILE or run 'idrive {cmd}' interactively"
        category = "config"
    elif state["totp_failed"]:
        msg, category = "two-factor code was rejected after retry; verify IDRIVE_TOTP_SECRET and the host clock", "credentials"
    else:
        category = classify_failure(out)
        msg = f"idrive {cmd} failed (rc={rc}, logged_in={logged_in}, cause={category})"
        print(out[-2500:], file=sys.stderr)
    print(f"[autologin] ERROR: {msg}.", file=sys.stderr)
    return LoginResult(False, category, msg, state["last_totp_counter"])


def run_login_flow(s: LoginSettings, last_totp_counter: int | None = None) -> LoginResult:
    """Log an existing account back in with `idrive --login`."""
    state = _base_auth_state(last_totp_counter)

    def handle(buf: str, write_fn) -> int | str | None:
        tail = buf[-1500:]
        shared = handle_auth_prompts(tail, len(buf), state, write_fn, s)
        if shared is not None:
            return shared
        if re.search(r"Do you really want to continue\s*\(y/n\)\?", tail, re.I):
            write_fn("y")
            return len(buf)
        return None

    rc, out = pty_interact(["--login"], handle, s.secrets, timeout_s=150)
    _, logged_in = get_idriveuser_state()
    if state["missing_key"] or state["missing_totp"] or state["totp_failed"] or rc != 0 or logged_in != 1:
        return _report_failure(state, rc, out, logged_in, "--login")
    return LoginResult(True, totp_counter=state["last_totp_counter"])


def run_account_setting_flow(s: LoginSettings, last_totp_counter: int | None = None) -> LoginResult:
    """Set up an empty volume with `idrive --account-setting`.

    Backup location: with IDRIVE_BACKUP_LOCATION set, an existing location of that name is
    reused, otherwise a new one is created (and renamed to it afterwards, see
    rename_backup_location_if_needed). Saved settings of a reused location are not copied.
    """
    state = _base_auth_state(last_totp_counter)
    state.update({"enc_choice": False, "set_key": False, "conf_key": False, "checked_existing": False, "enter_loc": False, "proxy_seen": 0})

    def handle(buf: str, write_fn) -> int | str | None:
        tail = buf[-2500:]

        if re.search(r"want to reconfigure.*\(y/n\)", tail, re.I):
            write_fn("y")
            return len(buf)
        if re.search(r"Do you wish to use proxy\?", tail, re.I) and state["proxy_seen"] < 2:
            state["proxy_seen"] += 1
            write_fn("n")
            return len(buf)

        shared = handle_auth_prompts(tail, len(buf), state, write_fn, s)
        if shared is not None:
            return shared

        if re.search(rf"1\)\s*Default encryption key[\s\S]*?{MENU_PROMPT}", tail, re.I) and not state["enc_choice"]:
            state["enc_choice"] = True
            write_fn("2" if s.enc_type == "PRIVATE" else "1")
            return len(buf)
        if re.search(r"Set your encryption key\s*:", tail, re.I) and not state["set_key"]:
            state["set_key"] = True
            write_fn(s.enc_key)
            return len(buf)
        if re.search(r"Confirm your encryption key\s*:", tail, re.I) and not state["conf_key"]:
            state["conf_key"] = True
            write_fn(s.enc_key)
            return len(buf)

        # IDrive found one location for this machine and asks whether to use another one.
        m_single = re.search(rf"backup to device name is\s+(\S+)\..*Do you want to change[\s\S]*?{MENU_PROMPT}", tail, re.I)
        if m_single:
            write_fn("y" if s.backup_loc and m_single.group(1).strip('".') != s.backup_loc else "n")
            return len(buf)
        # Create a new location, or first look through the existing ones for the requested name.
        if re.search(rf"1\)\s*Create new Backup Location[\s\S]*?{MENU_PROMPT}", tail, re.I):
            if s.backup_loc and not state["checked_existing"]:
                state["checked_existing"] = True
                write_fn("2")
            else:
                write_fn("1")
            return len(buf)
        # The list of existing locations: pick the requested one, or go back and create it.
        if re.search(r"Enter the\s+['\"]?S\.No\.?['\"]?\s+to select (?:the|your)\s+Backup\s+location[\s\S]*?Enter your choice\s*:", tail, re.I):
            sno = match_device_sno(parse_device_table(buf[-3500:]), s.backup_loc) if s.backup_loc else None
            write_fn(sno or "")
            return len(buf)
        if re.search(r"Enter your Backup Location", tail, re.I) and not state["enter_loc"]:
            state["enter_loc"] = True
            write_fn(s.backup_loc)
            return len(buf)
        # "Copy the saved settings of the selected location?" No.
        if re.search(r"(?:Enter\s+'y'\s+to continue or\s+'n'\s+to skip|do you want to continue or skip)[\s\S]*?Enter your choice\s*:", tail, re.I):
            write_fn("n")
            return len(buf)
        if re.search(rf"1\)\s*Mirror[\s\S]*?2\)\s*Relative[\s\S]*?{MENU_PROMPT}", tail, re.I):
            write_fn("1")
            return len(buf)
        return None

    rc, out = pty_interact(["--account-setting"], handle, s.secrets, timeout_s=180)
    _, logged_in = get_idriveuser_state()
    if state["missing_key"] or state["missing_totp"] or state["totp_failed"] or rc != 0 or logged_in != 1:
        return _report_failure(state, rc, out, logged_in, "--account-setting")
    return LoginResult(True, totp_counter=state["last_totp_counter"])


def read_login_settings() -> LoginSettings | None:
    """Read and check the login settings. None when no credentials are configured.
    Raises ValueError for an invalid configuration."""
    try:
        account = read_env_or_file("IDRIVE_ACCOUNT").strip()
        password = read_env_or_file("IDRIVE_PASSWORD")
        enc_key = read_env_or_file("IDRIVE_ENCRYPTION_KEY")
        totp_raw = read_env_or_file("IDRIVE_TOTP_SECRET").strip()
    except FileNotFoundError as exc:
        raise ValueError(str(exc)) from None
    if not account and not password:
        return None
    if not account or not password:
        raise ValueError("Both IDRIVE_ACCOUNT and IDRIVE_PASSWORD must be provided.")
    enc_type = os.environ.get("IDRIVE_ENCRYPTION_TYPE", "DEFAULT").strip().upper() or "DEFAULT"
    if enc_type not in ("DEFAULT", "PRIVATE"):
        raise ValueError(f"Invalid IDRIVE_ENCRYPTION_TYPE={enc_type!r} (expected DEFAULT or PRIVATE).")
    if enc_type == "PRIVATE" and not enc_key:
        raise ValueError("IDRIVE_ENCRYPTION_KEY is required when IDRIVE_ENCRYPTION_TYPE=PRIVATE.")
    backup_loc = os.environ.get("IDRIVE_BACKUP_LOCATION", "").strip()
    if backup_loc and not BACKUP_LOCATION_RE.match(backup_loc):
        raise ValueError("Invalid IDRIVE_BACKUP_LOCATION (must be 1-64 characters matching [A-Za-z0-9_-]).")
    totp_spec = parse_totp_secret(totp_raw) if totp_raw else None
    secrets = [password, account, enc_key, totp_raw, re.sub(r"[\s-]+", "", totp_raw)]
    return LoginSettings(account, password, enc_type, enc_key, totp_spec, backup_loc, totp_raw, secrets)


def cmd_autologin() -> int:
    """Run by start.sh after prepare. Does nothing without credentials or when already logged in;
    logs a logged-out account back in; sets up an empty volume. Exit 1 on failure (start.sh
    still starts IDrive, and the health check reports the problem).

    Every attempt goes through the attempt record: failures back off, and credential or
    configuration errors pause automated login until the settings change."""
    try:
        s = read_login_settings()
    except ValueError as exc:
        return autologin_config_error(str(exc))
    if s is None:
        print("[autologin] Credentials not provided; skipping automated login.")
        return 0

    # Changed credentials or settings clear any earlier backoff or pause.
    login_state = load_login_state()
    fingerprint = settings_fingerprint(login_state, s)
    if login_state.get("fingerprint") != fingerprint:
        if login_state.get("failures") or login_state.get("blocked"):
            print("[autologin] Credentials or settings changed; clearing earlier login failures.")
        login_state = {"salt": login_state["salt"], "fingerprint": fingerprint, "last_totp_counter": login_state.get("last_totp_counter")}
        save_login_state(login_state)

    def attempt(flow, banner: str = "") -> LoginResult | None:
        """Run a login flow unless backoff or a pause forbids it (None then)."""
        reason = login_gate(login_state, time.time())
        if reason:
            print(f"[autologin] Skipping automated login: {reason}.", file=sys.stderr)
            return None
        if banner:
            print(banner)
        login_state["last_attempt"] = int(time.time())
        save_login_state(login_state)
        result = flow(s, login_state.get("last_totp_counter"))
        stop_idrive_daemons()  # the login may start IDrive services; start.sh starts them itself
        record_login_result(login_state, result)
        if not result.ok and login_state.get("blocked"):
            print("[autologin] Automated login is paused until the credentials/settings change "
                  "(or 'idrive-init.py reset-login' is run), so the IDrive account cannot be locked.", file=sys.stderr)
        elif not result.ok:
            print(f"[autologin] Will retry in {backoff_seconds(login_state['failures']) // 60} min "
                  "(the watchdog restarts the container when it is due).", file=sys.stderr)
        return result

    user_id, logged_in = get_idriveuser_state()
    pdir = resolve_profile_dir(user_id)
    cfg_path = os.path.join(pdir, "CONFIGURATION_FILE") if pdir else ""

    if pdir and os.path.isfile(cfg_path):
        cfg, _ = decrypt_json_file(cfg_path)
        if not isinstance(cfg, dict):
            # Without it the account cannot be checked, so do not log in. Count it as a failed
            # attempt, so the watchdog's restarts back off instead of repeating every few minutes.
            reason = login_gate(login_state, time.time())
            if reason:
                print(f"[autologin] Skipping automated login: {reason}.", file=sys.stderr)
                return 1
            login_state["last_attempt"] = int(time.time())
            record_login_result(login_state, LoginResult(False, "error", "could not read CONFIGURATION_FILE"))
            print("[autologin] ERROR: Could not read CONFIGURATION_FILE; will retry in "
                  f"{backoff_seconds(login_state['failures']) // 60} min.", file=sys.stderr)
            return 1
        # Never log a volume set up for one account into another.
        existing_ids = {
            val.lower()
            for raw in (user_id, os.path.basename(pdir), cfg_get(cfg, "USERNAME", ""), cfg_get(cfg, "EMAILADDRESS", ""))
            if (val := str(raw or "").strip())
        }
        if s.account.lower() not in existing_ids:
            return autologin_config_error(
                "Volume already contains a configured profile for another account; refusing to overwrite existing backup metadata."
            )
        if str(cfg_get(cfg, "ENCRYPTIONTYPE", "DEFAULT")).upper() == "PRIVATE" and not s.enc_key:
            return autologin_config_error("Existing profile uses PRIVATE encryption; IDRIVE_ENCRYPTION_KEY is required.")
        cron_data, _ = decrypt_json_file(CRONTAB_FILE)
        inactive = (get_cron_status(cron_data, user_id) or "").upper() == "INACTIVE"
        if logged_in == 1 and not inactive:
            print("[autologin] Account already logged in and active; skipping automated login.")
            return 0
        if login_gate(login_state, time.time()) is None and logged_in == 1:
            # Logged in, but IDrive switched the schedule off: log out, then in again.
            run_cmd([IDRIVE_BIN, "--logout", "1", "0"], timeout=30)
        result = attempt(run_login_flow, "[autologin] Restoring session via idrive --login...")
        if not (result and result.ok):
            return 1
        print("[autologin] Session restored successfully.")
        return cmd_prepare(quiet=True)

    result = attempt(run_account_setting_flow, "[autologin] Configuring unconfigured volume via idrive --account-setting...")
    if not (result and result.ok):
        return 1
    new_user_id, _ = get_idriveuser_state()
    new_pdir = resolve_profile_dir(new_user_id)
    rename_ok = True
    if new_pdir and s.backup_loc:
        rename_ok = rename_backup_location_if_needed(new_pdir, s.backup_loc, s.secrets)
    prep_rc = cmd_prepare(quiet=True)
    if not rename_ok:
        return 1
    print("[autologin] Account setup completed successfully.")
    return prep_rc


# ---------------------------------------------------------------------------------------------
# watchdog: recover from logouts that happen while the container runs
# ---------------------------------------------------------------------------------------------
def watchdog_check() -> tuple[bool, str]:
    """(session_ok, problem)."""
    if not is_already_initialized():
        return False, "account is not configured"
    user_id, logged_in = get_idriveuser_state()
    if logged_in != 1:
        return False, "account is logged out"
    cron_data, _ = decrypt_json_file(CRONTAB_FILE)
    if (get_cron_status(cron_data, user_id) or "").upper() == "INACTIVE":
        return False, "backup schedule is INACTIVE"
    return True, "ok"


def cmd_watchdog() -> int:
    """Run by start.sh every IDRIVE_WATCHDOG_INTERVAL seconds.

    IDrive also logs out while running (for example on server errors such as "password
    mismatch" or "invalid device id"). When credentials are configured and the problem is seen
    on two checks in a row (the first may be a login in progress), exit WATCHDOG_RESTART_RC:
    start.sh then exits, Docker's restart policy starts a fresh container, and its startup
    login runs. Backoff and pauses from the attempt record are honoured, so this cannot loop.
    Without credentials it only logs a reminder."""
    can_login = os.environ.get("IDRIVE_AUTOLOGIN_AVAILABLE") == "1"  # set by start.sh
    session_ok, problem = watchdog_check()
    state = load_login_state()
    if session_ok or (problem == "account is not configured" and not can_login):
        if state.pop("problem_since", None) is not None:
            save_login_state(state)
        return 0

    now = int(time.time())
    gate = login_gate(state, now) if can_login else None
    if "problem_since" not in state:
        state["problem_since"] = now
        save_login_state(state)
        if not can_login:
            hint = "log in with: docker exec -it <container> idrive --login"
        else:
            hint = f"automated login {gate}" if gate else "will re-login automatically"
        print(f"[watchdog] IDrive {problem}; {hint}.", file=sys.stderr)
        return 0
    if not can_login:
        return 0
    if gate:
        if now - int(state.get("last_notice", 0)) >= 3600:  # remind at most hourly
            state["last_notice"] = now
            save_login_state(state)
            print(f"[watchdog] IDrive {problem}; automated login {gate}.", file=sys.stderr)
        return 0
    print(f"[watchdog] IDrive {problem}; restarting the container to log in again.", file=sys.stderr)
    return WATCHDOG_RESTART_RC


def cmd_reset_login() -> int:
    """Clear backoff and pause, so the next start retries automated login immediately."""
    state = load_login_state()
    for key in ("failures", "blocked", "last_error", "last_attempt", "problem_since", "last_notice"):
        state.pop(key, None)
    save_login_state(state)
    print("[autologin] Login backoff cleared; restart the container to retry automated login now.")
    return 0


def main() -> int:
    # Keep stdout and stderr lines in order in `docker logs` (stdout is block-buffered when piped).
    sys.stdout.reconfigure(line_buffering=True)
    commands = {
        "prepare": cmd_prepare,
        "autologin": cmd_autologin,
        "healthcheck": cmd_healthcheck,
        "watchdog": cmd_watchdog,
        "reset-login": cmd_reset_login,
    }
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        print(f"Usage: idrive-init.py {{{'|'.join(commands)}}}", file=sys.stderr)
        return 2
    return commands[sys.argv[1]]()


if __name__ == "__main__":
    sys.exit(main())
