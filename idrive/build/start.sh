#!/usr/bin/env bash
set -euo pipefail

echo "Initializing IDrive container..."

# 1. Volume Initialization
# Extract missing files from the backup archive; bypass existing configuration files.
tar -xzf /tmp/idriveIt.orig.tar.gz -C /opt/IDriveForLinux --skip-old-files

# 2. Process Management & Signal Trapping
exit_handler() {
    echo "Termination signal received. Shutting down IDrive services..."
    if [ -n "${cron_pid:-}" ] && kill -0 "$cron_pid" 2>/dev/null; then
        kill -TERM "$cron_pid"
        echo "IDrive CRON service stopped."
    fi
    exit 0
}

trap 'exit_handler' SIGTERM SIGINT EXIT

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
