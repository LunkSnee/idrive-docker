#!/usr/bin/env bash
# Container entry point (PID 1): prepares the config volume, starts IDrive's own scheduler
# (/etc/idrivecron, which runs the backup jobs), and streams IDrive's logs to `docker logs`.
# `docker stop` stops IDrive cleanly and exits 0.
set -euo pipefail

echo "Initializing IDrive container..."

# 1. Bring the persistent volume in line with this image before IDrive starts: restore
#    missing defaults, refresh the idevsutil programs, record the IDrive version, and fix the
#    state that would otherwise make IDrive log out (see docker/idrive-init.py, cmd_prepare).
#    A failure is reported but does not stop the container, as before.
if ! /usr/local/bin/idrive-init.py prepare; then
    echo "WARNING: preparing the config volume failed; starting IDrive anyway." >&2
fi

# 2. Process Management & Signal Trapping
exit_handler() {
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "Shutting down IDrive services..."
    else
        echo "IDrive container failed (exit $rc). Shutting down..."
    fi
    if [ -n "${cron_pid:-}" ] && kill -0 "$cron_pid" 2>/dev/null; then
        kill -TERM "$cron_pid"
        echo "IDrive CRON service stopped."
    fi
    # Re-raise the real status: exiting 0 here would report a crash to Docker
    # as a clean shutdown.
    exit "$rc"
}

# A signalled stop is a clean stop; EXIT preserves whatever status actually occurred.
trap 'exit 0' SIGTERM SIGINT
trap 'exit_handler' EXIT

# 3. Start IDrive CRON Service
echo "Starting IDrive CRON service..."
/etc/idrivecron --cron >/dev/null 2>&1 &
cron_pid=$!

# 4. Base Daemon Log Discovery & Tailing
BASE_LOG_DIR="/opt/IDriveForLinux/idriveIt/user_profile/root/.trace"
BASE_LOG="${BASE_LOG_DIR}/traceLog.txt"

echo "Tailing base daemon log: $BASE_LOG"
tail -F "$BASE_LOG" &

# 5. Authenticated User Log Discovery & Tailing
echo "Polling for authenticated user log generation..."
USER_LOG=""

while true; do
    # -mindepth 3 strictly filters out the base daemon log at Depth 2.
    # It dynamically captures: root/<any_username>/.trace/traceLog.txt
    found=$(find /opt/IDriveForLinux/idriveIt/user_profile/root -mindepth 3 -type f -name "traceLog.txt" 2>/dev/null | head -n 1)
    
    if [ -n "$found" ]; then
        USER_LOG="$found"
        break
    fi
    sleep 5
done

echo "Tailing authenticated user log: $USER_LOG"
tail -F "$USER_LOG" &

# 6. Process Blocking
# The wait command without arguments blocks indefinitely, keeping PID 1 alive 
# to ensure Docker signals trigger the trap sequence.
wait
