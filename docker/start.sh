#!/usr/bin/env bash
# Container entry point (PID 1): prepares the config volume, optionally logs in, starts
# IDrive's own scheduler (/etc/idrivecron, which runs the backup jobs), and streams IDrive's
# logs to `docker logs` (filtered by IDRIVE_LOG_LEVEL, plus one [job] line per finished
# job). While running, a watchdog notices logouts (see section 5).
# Exit codes: 0 after `docker stop`, 3 when the watchdog wants a restart to log in again,
# otherwise non-zero when idrivecron stopped by itself.
set -euo pipefail

echo "Initializing IDrive container..."

# 0. Time zone for every process. IDrive starts its continuous-backup services (file watcher,
#    database writer, CDP client and server) without the container's TZ, so they fall back to
#    /etc/localtime, which is UTC in the image; point it at TZ so their log lines use local time.
if [ -n "${TZ:-}" ]; then
    if [ -f "/usr/share/zoneinfo/$TZ" ]; then
        ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
        echo "$TZ" > /etc/timezone
    else
        echo "WARNING: unknown time zone TZ=$TZ; IDrive's services use UTC." >&2
    fi
fi

# 1. Bring the persistent volume in line with this image before IDrive starts: restore
#    missing defaults, refresh the idevsutil programs, record the IDrive version, and fix the
#    state that would otherwise make IDrive log out (see docker/idrive-init.py, cmd_prepare).
#    A failure is reported but does not stop the container, as before.
if ! /usr/local/bin/idrive-init.py prepare; then
    echo "WARNING: preparing the config volume failed; starting IDrive anyway." >&2
fi

# 1b. Optional automated login: with credentials configured (IDRIVE_ACCOUNT_FILE etc.), set up
#     an empty volume or log a logged-out account back in. A failure is logged and IDrive
#     starts anyway; the health check then reports it.
if ! /usr/local/bin/idrive-init.py autologin; then
    echo "WARNING: Automated login failed; starting IDrive anyway (see the messages above)." >&2
fi
# Remember whether credentials are configured: the watchdog only restarts for a re-login then.
autologin_available=0
if [ -n "${IDRIVE_ACCOUNT:-}${IDRIVE_ACCOUNT_FILE:-}" ] && [ -n "${IDRIVE_PASSWORD:-}${IDRIVE_PASSWORD_FILE:-}" ]; then
    autologin_available=1
fi
# Keep plain-text credentials out of the environment of IDrive's processes (/proc/*/environ).
unset IDRIVE_ACCOUNT IDRIVE_PASSWORD IDRIVE_ENCRYPTION_KEY IDRIVE_TOTP_SECRET

# How much of IDrive's own trace logs reaches `docker logs` (the container's messages always do):
#   full    - everything, starting with the last 10 lines already in each log as context
#   info    - only new lines, without IDrive's bulk output: the file watcher's chatter
#             (rescans, "dir add event", bare file paths), the backup set it lists 1,000
#             files at a time during every backup, and its per-batch debug lines
#   summary - only new lines that report an error or a logout; finished jobs still get
#             their [job] line
# (The base daemon log can go unwritten for months, so replaying its last lines at start
# shows old messages as if they were new; only full does that.)
LOG_LEVEL="${IDRIVE_LOG_LEVEL:-info}"
case "$LOG_LEVEL" in
    full|info|summary) ;;
    *) echo "ERROR: IDRIVE_LOG_LEVEL must be full, info or summary" >&2; exit 1 ;;
esac

# A trace line is "[date time][user][module][Line: N] message"; a message can continue over
# further lines without that prefix (the backup set listing does, one file per line), and
# those lines follow the fate of their message. mawk (Debian's awk) because grep cannot keep that
# state; -W interactive makes it handle each line as it arrives instead of in large blocks.
# Patterns avoid backslashes, which awk -v would reinterpret.
# shellcheck disable=SC2016  # an awk program: $0 is awk's, not the shell's
LOG_FILTER='
/^[[][0-9][0-9][0-9][0-9][/][0-9][0-9][/][0-9][0-9] [0-9:]*[]][[][^]]*[]][[][^]]*[]][[]Line: [0-9]+[]]/ {
    msg = $0
    sub(/^[[][^]]*[]][[][^]]*[]][[][^]]*[]][[]Line: [0-9]+[]] ?/, "", msg)
    # A bare file path reports an error only after it ("/x/a.db: Permission denied"), so look
    # for error words there, not in the path itself (IDrive has a folder named ERROR).
    path = (msg ~ /^[/]/)
    text = msg
    if (path) text = match(msg, /: /) ? substr(msg, RSTART + 2) : ""
    if (mode == "info") keep = (msg !~ bulk && (!path || tolower(text) ~ errors))
    else keep = (tolower(text) ~ errors && msg !~ benign)
}
keep { print; fflush() }'
# info drops these messages (with their continuation lines), plus bare file paths that report no
# error after the path (IDrive's file watcher logs each changed path on its own, tagged [&utilities]):
LOG_BULK='^(Starting rescan|Ending rescan|dir add event, trigger scan|line no [0-9]+ backupset contents : .*|POSIX FORK TRACKERS: .*|line [0-9]+ [0-9]+)$'
# summary keeps messages with one of these words (whole words: not "failedFilescount")...
LOG_ERRORS='(^|[^a-z])(errors?|failed|failure|invalid|denied|logout|logged out|mismatch|blocked|expired|timed out|timeout|unable to|cannot)([^a-z]|$)'
# ...except this one, which IDrive logs after every job when there were no errors to collect.
LOG_BENIGN='unable to open file : .*/error[.]txt'

# follow_log <file>: stream one of IDrive's trace logs to docker logs at LOG_LEVEL. In info and
# summary, tail's own notices (IDrive rotates its logs often) are dropped as well.
follow_log() {
    case "$LOG_LEVEL" in
        full) tail -F "$1" ;;
        info) tail -n 0 -F "$1" 2>/dev/null | mawk -W interactive -v mode=info -v keep=1 -v bulk="$LOG_BULK" -v errors="$LOG_ERRORS" "$LOG_FILTER" ;;
        summary) tail -n 0 -F "$1" 2>/dev/null |
            mawk -W interactive -v mode=summary -v keep=0 -v errors="$LOG_ERRORS" -v benign="$LOG_BENIGN" "$LOG_FILTER" ;;
    esac
}

# Seconds between watchdog checks (docker/idrive-init.py, cmd_watchdog); 0 turns it off.
WATCHDOG_INTERVAL="${IDRIVE_WATCHDOG_INTERVAL:-300}"
case "$WATCHDOG_INTERVAL" in
    ''|*[!0-9]*) echo "ERROR: IDRIVE_WATCHDOG_INTERVAL must be a number of seconds" >&2; exit 1 ;;
esac

# 2. Process Management & Signal Trapping
tail_base_pid=""
tail_user_pid=""
sleep_pid=""

# shellcheck disable=SC2317  # runs from the EXIT trap below
exit_handler() {
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "Shutting down IDrive services..."
    elif [ "$rc" -eq 3 ]; then
        echo "Stopping so the restart policy starts a fresh container that logs in again..."
    else
        echo "IDrive container failed (exit $rc). Shutting down..."
    fi
    for tpid in "${sleep_pid:-}" "${tail_user_pid:-}" "${tail_base_pid:-}"; do
        if [ -n "$tpid" ]; then
            pkill -TERM -P "$tpid" 2>/dev/null || true
            kill -TERM "$tpid" 2>/dev/null || true
        fi
    done
    # idrivecron restarts itself at times, so stop whichever copy is running, not only $cron_pid.
    if pgrep -f /etc/idrivecron >/dev/null || pgrep -f '/opt/IDriveForLinux/' >/dev/null; then
        pkill -TERM -f /etc/idrivecron 2>/dev/null || true
        pkill -TERM -f '/opt/IDriveForLinux/' 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
            if ! pgrep -f /etc/idrivecron >/dev/null 2>&1 && ! pgrep -f '/opt/IDriveForLinux/' >/dev/null 2>&1; then
                break
            fi
            sleep 0.5
        done
        pkill -KILL -f /etc/idrivecron 2>/dev/null || true
        pkill -KILL -f '/opt/IDriveForLinux/' 2>/dev/null || true
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

echo "Tailing base daemon log: $BASE_LOG (IDRIVE_LOG_LEVEL=$LOG_LEVEL)"
follow_log "$BASE_LOG" &
tail_base_pid=$!

# 5. Supervise idrivecron until it stops: tail the account's log once it exists, and run the
#    session watchdog every WATCHDOG_INTERVAL seconds. idrivecron replaces itself with a new
#    process at times (after a login or logout; there can be several seconds with none
#    running), so supervise "an idrivecron is running", not the PID started above, and only
#    count it as stopped after 30 s without one (6 checks). The watchdog answering 3 means "logged
#    out and automated login is due": exit 3, and Docker's restart policy starts a fresh
#    container whose startup login runs (see `restart:` in compose.yaml).
echo "Polling for authenticated user log generation..."
user_log_tailed=0
next_watchdog=$((SECONDS + WATCHDOG_INTERVAL))
next_job_summary=$SECONDS
cron_missing=0

while [ "$cron_missing" -lt 6 ]; do
    if pgrep -f /etc/idrivecron >/dev/null; then cron_missing=0; else cron_missing=$((cron_missing + 1)); fi

    if [ "$user_log_tailed" -eq 0 ]; then
        # -mindepth 3 skips the base daemon log and finds the newest root/<account>/.trace/traceLog.txt
        user_log=$(find /opt/IDriveForLinux/idriveIt/user_profile/root -mindepth 3 -type f -name "traceLog.txt" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2- || true)
        if [ -n "$user_log" ]; then
            echo "Tailing authenticated user log: $user_log"
            follow_log "$user_log" &
            tail_user_pid=$!
            user_log_tailed=1
        fi
    fi

    # One [job] line per finished backup/restore (docker/idrive-init.py, cmd_job_summaries).
    if [ "$SECONDS" -ge "$next_job_summary" ]; then
        next_job_summary=$((SECONDS + 30))
        /usr/local/bin/idrive-init.py job-summaries || true
    fi

    if [ "$WATCHDOG_INTERVAL" -gt 0 ] && [ "$SECONDS" -ge "$next_watchdog" ]; then
        next_watchdog=$((SECONDS + WATCHDOG_INTERVAL))
        watchdog_rc=0
        IDRIVE_AUTOLOGIN_AVAILABLE="$autologin_available" /usr/local/bin/idrive-init.py watchdog || watchdog_rc=$?
        if [ "$watchdog_rc" -eq 3 ]; then
            exit 3
        fi
    fi

    # Sleep in the background so `docker stop` is handled at once, not after the sleep.
    sleep 5 &
    sleep_pid=$!
    wait "$sleep_pid" || true
    sleep_pid=""
done

# idrivecron stopped by itself: report a failure to Docker, so the restart policy applies
# (the first process's own exit status when it failed, otherwise 1).
echo "IDrive CRON service is no longer running." >&2
cron_rc=0
wait "$cron_pid" || cron_rc=$?
exit $(( cron_rc == 0 ? 1 : cron_rc ))
