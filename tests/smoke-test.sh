#!/usr/bin/env bash
# Offline smoke test for a built image: needs only Docker, no IDrive account.
# Usage: ./tests/smoke-test.sh <image>
set -euo pipefail

IMAGE="${1:?usage: $0 <image>}"
RUN_ID="idrive-smoke-$$"
CONTAINERS=()
VOLUMES=()

cleanup() {
    set +e
    for c in "${CONTAINERS[@]}"; do docker rm -f "$c" >/dev/null 2>&1; done
    for v in "${VOLUMES[@]}"; do docker volume rm -f "$v" >/dev/null 2>&1; done
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Wait until a file exists inside a running container.
wait_file() {
    local c="$1" path="$2"
    for _ in $(seq 1 30); do
        docker exec "$c" test -f "$path" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

logs_contain() { local logs; logs=$(docker logs "$1" 2>&1); grep -q -- "$2" <<<"$logs"; }

echo "=== Smoke testing $IMAGE ==="

# 1. The IDrive client runs and reports a version.
ver=$(docker run --rm --entrypoint /opt/IDriveForLinux/bin/idrive "$IMAGE" --version | tr -d '\r\n')
[ -n "$ver" ] || fail "idrive --version printed nothing"
echo "[1] idrive --version = $ver"

# 2. The image is the lean build: UTF-8 locale without the locales package, no system
#    cron/systemd, and IDrive's Cloud Drive left out (unless EXPECT_CLOUD_DRIVE=true).
docker run --rm -e EXPECT_CLOUD_DRIVE="${EXPECT_CLOUD_DRIVE:-false}" --entrypoint bash "$IMAGE" -c '
set -euo pipefail
[ "$LANG" = C.UTF-8 ] && [ "$LC_ALL" = C.UTF-8 ]
for pkg in cron systemd locales unzip; do ! dpkg -s "$pkg" >/dev/null 2>&1; done
command -v curl >/dev/null && command -v tar >/dev/null && command -v ifconfig >/dev/null
cd=/opt/IDriveForLinux/bin/Idrivelib/dependencies/cloud-drive
if [ "$EXPECT_CLOUD_DRIVE" = true ]; then [ -d "$cd" ]; else [ ! -e "$cd" ]; fi
[ -z "$(ls -A /opt/IDriveForLinux/idriveIt)" ]
' || fail "lean image checks"
echo "[2] Lean image: C.UTF-8, no cron/systemd/locales, Cloud Drive as expected"

# 3. A fresh, empty volume starts: IDrive's service runs, the volume is populated,
#    the time zone applies and the image's health check passes.
vol="${RUN_ID}-fresh"
c="${RUN_ID}-fresh"
docker volume create "$vol" >/dev/null
VOLUMES+=("$vol")
CONTAINERS+=("$c")
docker run -d --name "$c" -e TZ=America/New_York -v "$vol:/opt/IDriveForLinux/idriveIt" "$IMAGE" >/dev/null
wait_file "$c" /opt/IDriveForLinux/idriveIt/cache/version || fail "cache/version was not created"
sleep 3
docker exec -e EXPECT_VER="$ver" "$c" bash -c '
set -euo pipefail
pgrep -f /etc/idrivecron >/dev/null
[ -x /opt/IDriveForLinux/idriveIt/idevsutil ]
[ "$(cat /opt/IDriveForLinux/idriveIt/cache/version)" = "$EXPECT_VER" ]
[ "$(date +%Z)" = EST ] || [ "$(date +%Z)" = EDT ]
tz=$(env -u TZ date +%Z); [ "$tz" = EST ] || [ "$tz" = EDT ]   # processes started without TZ
[ ! -e /opt/IDriveForLinux/idriveIt/cache/.updateVersionInfo ]
idrive-init.py healthcheck
' || fail "fresh start checks"
echo "[3] Fresh volume: service running, volume populated, TZ applied (also without TZ), healthy while waiting for setup"
if logs_contain "$c" "anonymous Docker volume"; then fail "anonymous-volume warning on a named volume"; fi
c="${RUN_ID}-anon"
CONTAINERS+=("$c")
docker run -d --name "$c" "$IMAGE" >/dev/null   # nothing mounted: Docker uses an anonymous volume
sleep 4
logs_contain "$c" "anonymous Docker volume" || fail "no warning when the config is on an anonymous volume"
docker rm -fv "$c" >/dev/null
echo "[3b] Warning when the config folder is an anonymous volume, none on a named one"
c="${RUN_ID}-fresh"

# 4. docker stop is a clean stop.
docker stop -t 10 "$c" >/dev/null
rc=$(docker inspect --format '{{.State.ExitCode}}' "$c")
[ "$rc" = 0 ] || fail "expected exit code 0 after docker stop, got $rc"
echo "[4] docker stop exits 0"

# Seed a volume with a set-up account, written with IDrive's own ENCRYPT, as an older image
# would leave it: seed_account <volume> <isLoggedin> <schedule status> <extra CONFIGURATION_FILE JSON>
seed_account() {
    docker run --rm -i -v "$1:/opt/IDriveForLinux/idriveIt" --entrypoint bash "$IMAGE" -s "$2" "$3" "$4" <<'SEED'
set -euo pipefail
tar --skip-old-files -xzf /opt/IDriveForLinux/idriveIt.orig.tar.gz -C /opt/IDriveForLinux
v=/opt/IDriveForLinux/idriveIt
p="$v/user_profile/root/smokeuser"
mkdir -p "$p/.userInfo" "$p/.trace"
for f in IDPWD IDENPWD IDPWD_SCH; do printf dummy > "$p/.userInfo/$f"; done
enc() { printf '%s' "$1" > /tmp/plain.json; /opt/IDriveForLinux/bin/idrive --utilities ENCRYPT /tmp/plain.json "$2" >/dev/null; }
enc "{\"root\":{\"isLoggedin\":$1,\"userid\":\"smokeuser\"}}" "$v/cache/idriveuser.txt"
enc "{\"USERNAME\":{\"VALUE\":\"smokeuser\"},\"ENCRYPTIONTYPE\":{\"VALUE\":\"DEFAULT\"},\"RMSH\":{\"VALUE\":\"x\"}$3}" "$p/CONFIGURATION_FILE"
enc "{\"root\":{\"smokeuser\":{\"autoinstall\":{\"cmd\":\"idrive --launch-update silent\",\"settings\":{\"status\":\"enabled\"}},\"otherInfo\":{\"settings\":{\"status\":\"$2\"}}}}}" "$v/idrivecrontab.json"
rm -f /tmp/plain.json
SEED
}

# Decrypt one of IDrive's state files inside a container and print a Python expression of it.
read_state() {
    docker exec "$1" python3 -c '
import json, subprocess, sys
subprocess.run(["/opt/IDriveForLinux/bin/idrive", "--utilities", "DECRYPT", sys.argv[1], "/dev/shm/s.json"], check=True, capture_output=True)
d = json.load(open("/dev/shm/s.json"))
print(eval(sys.argv[2], {"d": d}))' "$2" "$3"
}

# 5. Upgrade: a volume as an older image leaves it (stale boot time, self-update on, IDrive's
#    install and update markers, a lock from an unclean stop, an old version) comes out fixed.
vol="${RUN_ID}-upg"
c="${RUN_ID}-upg"
docker volume create "$vol" >/dev/null
VOLUMES+=("$vol")
CONTAINERS+=("$c")
seed_account "$vol" 1 ACTIVE ',"UPTIME":{"VALUE":"1999-01-01 00:00"},"AUTOSOFTWAREUPDATE":{"VALUE":1}'
docker run --rm -v "$vol:/opt/IDriveForLinux/idriveIt" --entrypoint bash "$IMAGE" -c '
v=/opt/IDriveForLinux/idriveIt; printf 1 > $v/inst.track; printf 3.16.0 > $v/cache/version
printf 3.16.0 > $v/cache/.updateVersionInfo; printf 99999 > $v/user_profile/root/idrivecron.lock'
docker run -d --name "$c" -e TZ=America/New_York -v "$vol:/opt/IDriveForLinux/idriveIt" "$IMAGE" >/dev/null
sleep 8
docker exec -e EXPECT_VER="$ver" "$c" bash -c '
set -euo pipefail
v=/opt/IDriveForLinux/idriveIt
[ ! -e $v/inst.track ] && [ ! -e $v/cache/.updateVersionInfo ]
[ "$(cat $v/cache/version)" = "$EXPECT_VER" ]
[ "$(cat $v/user_profile/root/idrivecron.lock 2>/dev/null)" != 99999 ]
idrive-init.py healthcheck
' || fail "upgrade: markers, version, lock or health"
cfg=/opt/IDriveForLinux/idriveIt/user_profile/root/smokeuser/CONFIGURATION_FILE
boot=$(docker exec "$c" bash -c 'who -b | awk "{\$1=\"\"; \$2=\"\"; print \$0}" | date "+%Y-%m-%d %H:%M" -f -')
[ "$(read_state "$c" "$cfg" 'd["UPTIME"]["VALUE"]')" = "$boot" ] || fail "upgrade: UPTIME not synced to the boot time ($boot)"
[ "$(read_state "$c" "$cfg" 'd["AUTOSOFTWAREUPDATE"]["VALUE"]')" = 0 ] || fail "upgrade: self-update still on"
[ "$(read_state "$c" /opt/IDriveForLinux/idriveIt/idrivecrontab.json 'd["root"]["smokeuser"]["autoinstall"]["settings"]["status"]')" = disabled ] \
    || fail "upgrade: scheduled self-update still enabled"
echo "[5] Upgrade: boot time synced, self-update off, markers and stale lock cleared, healthy"

# 6. The health check catches a logout, a missing password file and an INACTIVE schedule.
unhealthy_after() {  # unhealthy_after <description> <command run in the container first>
    docker exec "$c" bash -c "$2"
    if docker exec "$c" idrive-init.py healthcheck 2>/dev/null; then fail "health check passed despite: $1"; fi
}
# shellcheck disable=SC2016  # expanded inside the container, not here
enc='enc() { printf "%s" "$1" > /tmp/p; /opt/IDriveForLinux/bin/idrive --utilities ENCRYPT /tmp/p "$2" >/dev/null; }'
unhealthy_after "logout" "$enc; enc '{\"root\":{\"isLoggedin\":0,\"userid\":\"smokeuser\"}}' /opt/IDriveForLinux/idriveIt/cache/idriveuser.txt"
# A logout makes idrivecron replace itself with a new process; the container must survive that.
sleep 15
[ "$(docker inspect --format '{{.State.Running}}' "$c")" = true ] || fail "container stopped when idrivecron restarted itself"
docker exec "$c" bash -c "$enc; enc '{\"root\":{\"isLoggedin\":1,\"userid\":\"smokeuser\"}}' /opt/IDriveForLinux/idriveIt/cache/idriveuser.txt"
docker exec "$c" idrive-init.py healthcheck || fail "health check failed after logging back in"
unhealthy_after "missing IDPWD" "mv /opt/IDriveForLinux/idriveIt/user_profile/root/smokeuser/.userInfo/IDPWD /tmp/"
docker exec "$c" mv /tmp/IDPWD /opt/IDriveForLinux/idriveIt/user_profile/root/smokeuser/.userInfo/
# A private-key account has two more saved files; losing one of them is unhealthy. (IDrive logged
# out by itself while IDPWD was missing, so log back in first.)
docker exec "$c" bash -c "$enc; enc '{\"root\":{\"isLoggedin\":1,\"userid\":\"smokeuser\"}}' /opt/IDriveForLinux/idriveIt/cache/idriveuser.txt"
docker exec "$c" bash -c 'u=/opt/IDriveForLinux/idriveIt/user_profile/root/smokeuser/.userInfo
for f in IDPVT IDPVT_SCH; do printf dummy > "$u/$f"; done; idrive-init.py healthcheck' ||
    fail "health check failed with private key files present"
unhealthy_after "a missing private key file" "rm /opt/IDriveForLinux/idriveIt/user_profile/root/smokeuser/.userInfo/IDPVT_SCH"
docker exec "$c" rm /opt/IDriveForLinux/idriveIt/user_profile/root/smokeuser/.userInfo/IDPVT
docker exec "$c" idrive-init.py healthcheck || fail "health check failed without private key files"
unhealthy_after "INACTIVE schedule" "$enc; enc '{\"root\":{\"smokeuser\":{\"otherInfo\":{\"settings\":{\"status\":\"INACTIVE\"}}}}}' /opt/IDriveForLinux/idriveIt/idrivecrontab.json"
echo "[6] Health check catches a logout, missing password/private keys and an INACTIVE schedule"

# 7. When IDrive hangs, the health check still ends within its budget, inside Docker's
#    timeout, and leaves no decrypt behind (a slow check must never orphan an idrive process).
docker exec "$c" sh -c 'cd /opt/IDriveForLinux/bin && mv idrive idrive.real &&
    printf "#!/bin/sh\ncase \"\$*\" in *DECRYPT*) exec sleep 600;; esac\nexec /opt/IDriveForLinux/bin/idrive.real \"\$@\"\n" > idrive && chmod +x idrive'
start=$SECONDS
out=$(docker exec "$c" idrive-init.py healthcheck 2>&1) && fail "health check passed while IDrive hung"
took=$((SECONDS - start))
grep -q "IDrive busy" <<<"$out" || fail "unexpected health check output: $out"
[ "$took" -lt 55 ] || fail "health check took ${took}s"
if docker exec "$c" pgrep -f "sleep 600" >/dev/null; then fail "health check left a hung decrypt behind"; fi
docker exec "$c" sh -c 'cd /opt/IDriveForLinux/bin && mv idrive.real idrive'
docker run --rm --entrypoint python3 "$IMAGE" -c '
import importlib.util, os, subprocess, sys, tempfile, time
spec = importlib.util.spec_from_file_location("m", "/usr/local/bin/idrive-init.py")
m = importlib.util.module_from_spec(spec); sys.modules["m"] = m; spec.loader.exec_module(m)
calls = 0
def fake_run(args, timeout=30, input_text=None):
    global calls
    calls += 1
    if calls == 1:
        raise subprocess.TimeoutExpired(args, timeout)
    with open(args[-1], "w") as fh:
        fh.write("{\"ok\":1}")
    return subprocess.CompletedProcess(args, 0, "", "")
m.run_cmd = fake_run
m._deadline = time.monotonic() + 40
m._timed_out = False
with tempfile.NamedTemporaryFile(delete=False) as tf:
    tf.write(b"cipher")
    p = tf.name
try:
    data, _ = m.decrypt_json_file(p)
    assert data == {"ok": 1} and m._timed_out is False
finally:
    os.unlink(p)
' || fail "_timed_out remained sticky after successful retry"
echo "[7] A hung IDrive makes the health check fail after ${took}s with nothing left behind"

docker stop -t 10 "$c" >/dev/null

# 8. Automated-login building blocks, without contacting IDrive: 2FA codes match RFC 6238's
#    test vector, log scrubbing redacts whole words only, and bad settings fail fast.
docker run --rm --entrypoint python3 "$IMAGE" -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m", "/usr/local/bin/idrive-init.py")
m = importlib.util.module_from_spec(spec); sys.modules["m"] = m; spec.loader.exec_module(m)
key = m.parse_totp_secret("GEZD GN BVGY 3TQO JQGE ZDGN BVGY 3TQO JQ")   # RFC 6238 SHA-1 seed
assert m.generate_totp(key, now=59) == ("287082", 1)
uri = m.parse_totp_secret("otpauth://totp/IDrive:u@example.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&digits=6&period=30")
assert m.generate_totp(uri, now=59) == ("287082", 1)
for bad in ("not!valid!base32", "otpauth://hotp/x?secret=GEZDGNBV"):
    try:
        m.parse_totp_secret(bad); raise AssertionError(bad)
    except ValueError:
        pass
assert m.scrub("user bob@example.com bobcat bob", ["bob@example.com"]) == "user <REDACTED> bobcat <REDACTED>"
s = m.LoginSettings("u", "p", "DEFAULT", "", None, "", "", ["p", "u", "", "", ""])
st = {"salt": "not-hex"}
fp = m.settings_fingerprint(st, s)
assert len(fp) == 64 and len(bytes.fromhex(st["salt"])) == 16
' || fail "TOTP / scrub / settings unit checks"
for args in "IDRIVE_ACCOUNT=u IDRIVE_PASSWORD=p IDRIVE_BACKUP_LOCATION=bad#name" \
            "IDRIVE_ACCOUNT=u IDRIVE_PASSWORD=p IDRIVE_TOTP_SECRET=not!valid" \
            "IDRIVE_ACCOUNT=u" \
            "IDRIVE_ACCOUNT=u IDRIVE_PASSWORD=p IDRIVE_ENCRYPTION_TYPE=PRIVATE" \
            "IDRIVE_ACCOUNT_FILE=/missing IDRIVE_PASSWORD=p"; do
    # shellcheck disable=SC2086  # $args is a list of VAR=value words
    if docker run --rm --entrypoint env "$IMAGE" $args timeout 20 idrive-init.py autologin >/dev/null 2>&1; then
        fail "autologin accepted invalid settings: $args"
    fi
done
echo "[8] 2FA codes, log scrubbing and settings validation"

# 9. Credentials never reach IDrive's processes, and with credentials (even partial) configured,
#    an account that is not set up counts as unhealthy.
vol="${RUN_ID}-env"
c="${RUN_ID}-env"
docker volume create "$vol" >/dev/null
VOLUMES+=("$vol")
CONTAINERS+=("$c")
docker run -d --name "$c" -e IDRIVE_PASSWORD=secret-pw -e IDRIVE_ENCRYPTION_KEY=secret-key \
    -e IDRIVE_TOTP_SECRET=JBSWY3DPEHPK3PXP -v "$vol:/opt/IDriveForLinux/idriveIt" "$IMAGE" >/dev/null
wait_file "$c" /opt/IDriveForLinux/idriveIt/cache/version || fail "cache/version missing"
sleep 3
docker exec "$c" bash -c '
set -euo pipefail
pid=$(pgrep -f /etc/idrivecron | head -n 1)
! tr "\0" "\n" < "/proc/$pid/environ" | grep -qE "^IDRIVE_(PASSWORD|ENCRYPTION_KEY|TOTP_SECRET)="
! idrive-init.py healthcheck 2>/dev/null
! IDRIVE_ACCOUNT_FILE=/run/secrets/x idrive-init.py healthcheck 2>/dev/null
env -u IDRIVE_PASSWORD idrive-init.py healthcheck
' || fail "credential scrubbing or credentials-configured health rule"
docker stop -t 10 "$c" >/dev/null
echo "[9] Credentials kept out of IDrive's processes; unconfigured + credentials = unhealthy"

# 10. Login backoff and pause rules (state file in /tmp, no network).
docker run --rm --entrypoint python3 "$IMAGE" -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m", "/usr/local/bin/idrive-init.py")
m = importlib.util.module_from_spec(spec); sys.modules["m"] = m; spec.loader.exec_module(m)
m.CACHE_DIR = "/tmp"; m.LOGIN_STATE_FILE = "/tmp/autologin-state.json"
assert [m.backoff_seconds(n) for n in range(9)] == [0, 300, 600, 1200, 2400, 4800, 9600, 19200, 21600]
assert m.classify_failure("Error: Invalid username or Password") == "credentials"
assert m.classify_failure("RATE_LIMITER_BLOCKED") == "rate-limited"
assert m.classify_failure("Connection timed out") == "error"
st = {}
m.record_login_result(st, m.LoginResult(False, "error", "network")); st["last_attempt"] = 1000
assert st["failures"] == 1 and not st.get("blocked")
assert m.login_gate(st, 1299) is not None and m.login_gate(st, 1300) is None
m.record_login_result(st, m.LoginResult(False, "credentials", "bad password"))
assert st["blocked"] and "paused" in m.login_gate(st, 10**10)
st["problem_since"] = 1000; st["last_notice"] = 1000
m.record_login_result(st, m.LoginResult(True, totp_counter=42))
assert st["failures"] == 0 and not st["blocked"] and st["last_totp_counter"] == 42
assert "problem_since" not in st and "last_notice" not in st
m.record_login_result(st, m.LoginResult(False, "rate-limited", "locked"))
assert m.backoff_seconds(st["failures"]) == 21600 and m.load_login_state() == st
' || fail "backoff unit checks"
# An unreadable CONFIGURATION_FILE (logged out) must not log in, and must back off like a failed
# login so the watchdog does not restart the container every few minutes.
docker run --rm -e IDRIVE_ACCOUNT=smokeuser -e IDRIVE_PASSWORD=unused --entrypoint bash "$IMAGE" -c '
set -uo pipefail
v=/opt/IDriveForLinux/idriveIt; tar -xzf /opt/IDriveForLinux/idriveIt.orig.tar.gz -C /opt/IDriveForLinux
p=$v/user_profile/root/smokeuser; mkdir -p "$p/.userInfo"; printf garbage > "$p/CONFIGURATION_FILE"
printf "%s" "{\"root\":{\"isLoggedin\":0,\"userid\":\"smokeuser\"}}" > /tmp/p
/opt/IDriveForLinux/bin/idrive --utilities ENCRYPT /tmp/p "$v/cache/idriveuser.txt" >/dev/null
out=$(idrive-init.py autologin 2>&1) && exit 1
grep -q "will retry in 5 min" <<<"$out" || { echo "$out" >&2; exit 1; }
out=$(idrive-init.py autologin 2>&1) && exit 1
grep -q "backing off after 1 failed" <<<"$out" || { echo "$out" >&2; exit 1; }
' || fail "unreadable CONFIGURATION_FILE backs off"
echo "[10] Login backoff: 5 min doubling to 6 h, pause on credential errors, reset on success, unreadable config"

# 11. Watchdog: leaves a healthy session alone, exits 3 after a logout (two checks in a row).
#     The account is logged in at start, so autologin never contacts IDrive.
vol="${RUN_ID}-wd"
c="${RUN_ID}-wd"
docker volume create "$vol" >/dev/null
VOLUMES+=("$vol")
CONTAINERS+=("$c")
seed_account "$vol" 1 ACTIVE ""
docker run -d --name "$c" -e IDRIVE_ACCOUNT=smokeuser -e IDRIVE_PASSWORD=unused -e IDRIVE_WATCHDOG_INTERVAL=3 \
    -v "$vol:/opt/IDriveForLinux/idriveIt" "$IMAGE" >/dev/null
sleep 10
logs_contain "$c" "Account already logged in" || fail "autologin did not skip a logged-in account"
[ "$(docker inspect --format '{{.State.Running}}' "$c")" = true ] || fail "watchdog restarted a healthy session"
docker exec "$c" bash -c "$enc; enc '{\"root\":{\"isLoggedin\":0,\"userid\":\"smokeuser\"}}' /opt/IDriveForLinux/idriveIt/cache/idriveuser.txt"
for _ in $(seq 1 30); do
    [ "$(docker inspect --format '{{.State.Running}}' "$c")" = false ] && break
    sleep 1
done
rc=$(docker inspect --format '{{.State.ExitCode}}' "$c")
[ "$rc" = 3 ] || fail "expected watchdog exit code 3 after a logout, got $rc"
logs_contain "$c" "restarting the container to log in again" || fail "missing watchdog restart message"
echo "[11] Watchdog leaves a healthy session alone and exits 3 after a logout"

# 12. A configuration error (here: credentials for another account) pauses automated login,
#     so the watchdog must not restart; reset-login clears the pause.
c="${RUN_ID}-wd2"
CONTAINERS+=("$c")
docker run -d --name "$c" -e IDRIVE_ACCOUNT=someone-else -e IDRIVE_PASSWORD=unused -e IDRIVE_WATCHDOG_INTERVAL=3 \
    -v "$vol:/opt/IDriveForLinux/idriveIt" "$IMAGE" >/dev/null
sleep 20
[ "$(docker inspect --format '{{.State.Running}}' "$c")" = true ] || fail "watchdog restarted despite a paused login"
logs_contain "$c" "automated login paused after" || fail "missing paused-login notice"
docker exec "$c" bash -c '
set -euo pipefail
f=/opt/IDriveForLinux/idriveIt/cache/autologin-state.json
python3 -c "import json,sys; assert json.load(open(sys.argv[1]))[\"blocked\"] is True" "$f"
idrive-init.py reset-login >/dev/null
python3 -c "import json,sys; assert not json.load(open(sys.argv[1])).get(\"blocked\")" "$f"
' || fail "pause state or reset-login"
docker stop -t 10 "$c" >/dev/null
echo "[12] A paused login blocks watchdog restarts; reset-login clears it"

# 13. Job summaries: a real IDrive job log (tests/fixtures) gives one [job] line, each job is
#     reported once, and running jobs are skipped.
FIXTURES="$(cd "$(dirname "$0")" && pwd)/fixtures"
docker run --rm -v "$FIXTURES:/fixtures:ro" --entrypoint bash "$IMAGE" -c '
set -euo pipefail
logs=/opt/IDriveForLinux/idriveIt/user_profile/root/user/Backup/DefaultBackupSet/LOGS
mkdir -p "$logs"
[ -z "$(IDRIVE_LOG_LEVEL=summary idrive-init.py job-summaries)" ]                       # first call: nothing old reported
cp /fixtures/1795729183_Success_Manual "$logs/"
cp /fixtures/1795729183_Success_Manual "$logs/1795729999_Running_Scheduled"
out=$(IDRIVE_LOG_LEVEL=summary idrive-init.py job-summaries)
expected="[job] Backup (Manual) Success: 2 considered, 2 backed up (4 bytes), 0 failed, ended 2026-11-26 14:39"
[ "$out" = "$expected" ] || { echo "got: $out" >&2; exit 1; }
[ -z "$(IDRIVE_LOG_LEVEL=summary idrive-init.py job-summaries)" ]                       # reported once
# IDrive sometimes reports a negative failed count (and then "Failure"); files that vanished
# during the job are listed separately as missing.
sed -e "s/^Files failed to backup : 0/Files failed to backup : -170416742/" \
    -e "s/^\[SUMMARY:\]/Total number of file(s) Missing : 51\n[SUMMARY:]/" \
    /fixtures/1795729183_Success_Manual > "$logs/1795739999_Failure_Manual"
out=$(IDRIVE_LOG_LEVEL=summary idrive-init.py job-summaries)
expected="[job] Backup (Manual) Failure: 2 considered, 2 backed up (4 bytes), 51 missing, invalid failed count from IDrive (-170,416,742), ended 2026-11-26 14:39"
[ "$out" = "$expected" ] || { echo "got: $out" >&2; exit 1; }

# While a job runs: a progress line for the newest _Running_ log of the job folder, while the
# job process from pid.txt is alive, from info_file and the per-engine PROGRESS_DETAILS_<n>
# (real values from a backup of 808,346 files, 777,976 of them already in the account). A
# leftover older _Running_ log is ignored; nothing after the process ended; no repeats.
set_dir=${logs%/LOGS}
rm "$logs/1795729999_Running_Scheduled"
cp /fixtures/1795729183_Success_Manual "$logs/1795761003_Running_Scheduled"
cp /fixtures/1795729183_Success_Manual "$logs/1795797335_Running_Manual"
printf "TOTALFILES 808346\nFAILEDCOUNT 0\nDENIEDCOUNT 0\nREADYSYNC 777976\n" > "$set_dir/info_file"
printf "%s\n" "Full Backup" "1 MB" 0 0 0 /x 0 0% 15528 0 0 > "$set_dir/PROGRESS_DETAILS_1"
printf "%s\n" "Full Backup" "1 MB" 0 0 0 /y 0 0% 5809 0 0 > "$set_dir/PROGRESS_DETAILS_2"
# An unrelated PID (recycled PID scenario) must not be treated as a live IDrive job.
sleep 300 & other=$!
echo "$other" > "$set_dir/pid.txt"
[ -z "$(idrive-init.py job-summaries | grep running || true)" ]
kill "$other"; wait "$other" 2>/dev/null || true

bash -c '\''exec -a /opt/IDriveForLinux/bin/idrive sleep 300'\'' & job=$!
echo "$job" > "$set_dir/pid.txt"
[ -z "$(IDRIVE_LOG_LEVEL=summary idrive-init.py job-summaries)" ]
out=$(idrive-init.py job-summaries)
expected="[job] Backup (Manual) running since $(date -d @1795797335 +%H:%M): 21,337 of 30,370 files to upload processed (70%); 777,976 of 808,346 already in the account"
[ "$out" = "$expected" ] || { echo "got: $out" >&2; exit 1; }
[ -z "$(idrive-init.py job-summaries)" ]                       # not again within 10 minutes
kill "$job"; wait "$job" 2>/dev/null || true
rm -f /tmp/idrive-job-summaries.json                            # as if 10 minutes had passed
[ -z "$(idrive-init.py job-summaries | grep running || true)" ] # job process gone: no progress line

# Multi-word job type (LocalBackup) parses considered count and End Time.
local_logs=/opt/IDriveForLinux/idriveIt/user_profile/root/user/LocalBackup/DefaultLocalSet/LOGS
mkdir -p "$local_logs"
cat > "$local_logs/1795749999_Success_Scheduled" <<'\''LOCAL'\''
[SUMMARY:]
Files considered for local backup : 10
Files backed up now : 10 [Size of backed up files: 1 MB]
Files failed to backup : 0
Local Backup End Time : Thu Nov 26 14:41:00 2026
LOCAL
out=$(IDRIVE_LOG_LEVEL=summary idrive-init.py job-summaries)
expected="[job] Local Backup (Scheduled) Success: 10 considered, 10 backed up (1 MB), 0 failed, ended 2026-11-26 14:41"
[ "$out" = "$expected" ] || { echo "got: $out" >&2; exit 1; }

# Over 500 finished jobs must never re-report older jobs on later ticks, and vanished files must not crash.
python3 - <<'\''PY'\''
import contextlib, importlib.util, io, json, os, sys
spec = importlib.util.spec_from_file_location("m", "/usr/local/bin/idrive-init.py")
m = importlib.util.module_from_spec(spec); sys.modules["m"] = m; spec.loader.exec_module(m)
logs = "/opt/IDriveForLinux/idriveIt/user_profile/root/user/Backup/DefaultBackupSet/LOGS"
fixture = open("/fixtures/1795729183_Success_Manual").read()
base = int(json.load(open("/tmp/idrive-job-summaries.json"))["since"]) + 10
for i in range(505):
    p = os.path.join(logs, f"{1795800000 + i}_Success_Scheduled")
    with open(p, "w") as fh:
        fh.write(fixture)
    os.utime(p, (base + i, base + i))
for expected_lines in (505, 0, 0):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        assert m.cmd_job_summaries() == 0
    assert len(buf.getvalue().splitlines()) == expected_lines
st = json.load(open("/tmp/idrive-job-summaries.json"))
assert len(st["reported"]) <= 500
m.glob.glob = lambda pat: ["/tmp/vanished-job_Running_Manual"]
assert m.cmd_job_summaries() == 0
PY
' || fail "job summaries"
echo "[13] Job summaries: one line per finished job from its [SUMMARY:] block, progress while one runs"

# 14. IDRIVE_LOG_LEVEL filters IDrive's trace logs (the container's own messages always pass).
trace_lines='[2026/11/26 02:10:01][root][&backup][Line: 1] Prepare file list...
[2026/11/26 02:10:01][root][&utilities][Line: 1] Starting rescan
[2026/11/26 02:10:01][root][&utilities][Line: 1] dir add event, trigger scan
[2026/11/26 02:10:01][root][&utilities][Line: 1] /source/1/photo.jpg
[2026/11/26 02:10:01][root][&utilities][Line: 1] /source/1/job/ERROR
[2026/11/26 02:10:01][root][Header.pl][Line: 1] line no 1043 backupset contents : /source/1/a.txt
/source/1/listed-file.txt
[2026/11/26 02:10:01][root][&backup][Line: 1] POSIX FORK TRACKERS: EVS Child PID: 4711
[2026/11/26 02:10:01][root][Header.pl][Line: 1] line 1072 4595
[2026/11/26 02:10:02][root][&backup][Line: 1] write backup summary failedFilescount : 0
[2026/11/26 02:10:02][root][&backup][Line: 1] /source/1/secret.db: Permission denied
[2026/11/26 02:10:02][root][&dashboard][Line: 1] password mismatch
[2026/11/26 02:10:02][root][&dashboard][Line: 1] Connection timed out
[2026/11/26 02:10:02][root][&backup][Line: 1] unable to open file : /opt/IDriveForLinux/idriveIt/user_profile/root/u/Backup/DefaultBackupSet/error.txt
[2026/11/26 02:10:03][root][&logout][Line: 1] call to normal logout'
for level in full info summary; do
    c="${RUN_ID}-log-$level"
    CONTAINERS+=("$c")
    vol="${RUN_ID}-log-$level"
    VOLUMES+=("$vol")
    # An old line already in the log: only full replays it at start.
    docker run --rm -v "$vol:/opt/IDriveForLinux/idriveIt" --entrypoint sh "$IMAGE" -c '
        mkdir -p /opt/IDriveForLinux/idriveIt/user_profile/root/.trace
        echo "[2026/04/30 09:29:04][root][Common.pm][Line: 1] CURL-ERROR: old error" > /opt/IDriveForLinux/idriveIt/user_profile/root/.trace/traceLog.txt'
    docker run -d --name "$c" -e IDRIVE_LOG_LEVEL="$level" -v "$vol:/opt/IDriveForLinux/idriveIt" "$IMAGE" >/dev/null
    sleep 4
    docker exec -i "$c" sh -c 'cat >> /opt/IDriveForLinux/idriveIt/user_profile/root/.trace/traceLog.txt' <<<"$trace_lines"
    sleep 2
    logs=$(docker logs "$c" 2>&1)
    seen=""
    for msg in "old error" "Prepare file list" "Starting rescan" "dir add event" "photo.jpg" "job/ERROR" "backupset contents" \
               "listed-file.txt" "POSIX FORK" "line 1072" "failedFilescount" "Permission denied" "password mismatch" \
               "timed out" "unable to open file" "normal logout"; do
        grep -q -- "$msg" <<<"$logs" && seen="$seen${seen:+,}$msg"
    done
    case "$level" in
        full) want="old error,Prepare file list,Starting rescan,dir add event,photo.jpg,job/ERROR,backupset contents,listed-file.txt,POSIX FORK,line 1072,failedFilescount,Permission denied,password mismatch,timed out,unable to open file,normal logout" ;;
        info) want="Prepare file list,failedFilescount,Permission denied,password mismatch,timed out,unable to open file,normal logout" ;;
        summary) want="Permission denied,password mismatch,timed out,normal logout" ;;
    esac
    [ "$seen" = "$want" ] || fail "IDRIVE_LOG_LEVEL=$level showed [$seen], expected [$want]"
    grep -q "Starting IDrive CRON service" <<<"$logs" || fail "IDRIVE_LOG_LEVEL=$level hid the container's own messages"
    docker rm -f "$c" >/dev/null
done
if docker run --rm -e IDRIVE_LOG_LEVEL=loud "$IMAGE" >/dev/null 2>&1; then fail "invalid IDRIVE_LOG_LEVEL accepted"; fi
echo "[14] IDRIVE_LOG_LEVEL: full shows all, info drops the bulk (watcher, backup set listing, debug), summary keeps new errors"

echo "PASS: smoke test for $IMAGE"
