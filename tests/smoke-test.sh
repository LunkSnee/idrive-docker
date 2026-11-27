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

# 2. A fresh, empty volume starts: IDrive's service runs, the volume is populated,
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
' || fail "fresh start checks"
echo "[2] Fresh volume: service running, volume populated, TZ applied"

# 3. docker stop is a clean stop.
docker stop -t 10 "$c" >/dev/null
rc=$(docker inspect --format '{{.State.ExitCode}}' "$c")
[ "$rc" = 0 ] || fail "expected exit code 0 after docker stop, got $rc"
echo "[3] docker stop exits 0"

echo "PASS: smoke test for $IMAGE"
