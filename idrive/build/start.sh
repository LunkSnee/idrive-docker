#!/usr/bin/env bash
set -euo pipefail

echo "Initializing IDrive container..."

# 1. Volume Initialization
ORIG_ARCHIVE=/opt/IDriveForLinux/idriveIt.orig.tar.gz
if [ -f "$ORIG_ARCHIVE" ]; then
    # Restore whatever the volume is missing (first run, or files a newer image added),
    # without disturbing existing configuration.
    if ! tar -xzf "$ORIG_ARCHIVE" -C /opt/IDriveForLinux --skip-old-files; then
        echo "WARNING: restoring missing files from $ORIG_ARCHIVE failed" >&2
    fi

    # The idevsutil helpers live inside the persisted volume, so without this they stay
    # frozen at whatever image first populated it and drift out of step with
    # /opt/IDriveForLinux/bin/idrive on every upgrade.
    #
    # Match by pattern, not by name: the install currently ships idevsutil,
    # idevsutil_dedup, idevsutil_sync and idevsutil_dedup_sync. A hardcoded list
    # silently skips any helper iDrive adds or renames later, leaving it stale forever.
    if ! tar -xzf "$ORIG_ARCHIVE" -C /opt/IDriveForLinux --overwrite --wildcards 'idriveIt/idevsutil*'; then
        echo "WARNING: could not refresh idevsutil binaries from $ORIG_ARCHIVE" >&2
    fi
else
    echo "WARNING: $ORIG_ARCHIVE is missing; cannot verify the idevsutil binaries in the" >&2
    echo "         volume match this image. They may be stale from an older version." >&2
fi

# 1b. Record IDrive client version into the idriveIt folder.
# Try to parse a semantic version like "3.12.0" from the output of the idrive binary.
ver_parsed=""
if [ -x "/opt/IDriveForLinux/bin/idrive" ]; then
    ver_raw=$(/opt/IDriveForLinux/bin/idrive --version 2>/dev/null || true)
    # Extract first occurrence of a semantic version number
    ver_parsed=$(printf "%s" "$ver_raw" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1 || true)
fi
# Ensure the idriveIt directory exists (volume may be empty) and write the version files.
mkdir -p /opt/IDriveForLinux/idriveIt/cache
if [ -n "$ver_parsed" ]; then
    echo "IDrive client version: $ver_parsed"
    printf '%s\n' "$ver_parsed" > /opt/IDriveForLinux/idriveIt/cache/.updateVersionInfo
    printf '%s' "$ver_parsed" > /opt/IDriveForLinux/idriveIt/cache/version
else
    # Previously this wrote the literal string "unknown" into both files. Recording a
    # bogus version is worse than recording none, so leave them as they are.
    echo "WARNING: could not parse 'idrive --version'; leaving cache/version as-is" >&2
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
