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
[ ! -e /opt/IDriveForLinux/idriveIt/cache/.updateVersionInfo ]
idrive-init.py healthcheck
' || fail "fresh start checks"
echo "[3] Fresh volume: service running, volume populated, TZ applied, healthy while waiting for setup"
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
' || fail "TOTP / scrub unit checks"
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

echo "PASS: smoke test for $IMAGE"
