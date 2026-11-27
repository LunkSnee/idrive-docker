#!/usr/bin/env bash
set -euo pipefail

# Live test against IDrive's servers: automated first-time setup from secret files (with 2FA
# when a TOTP key is given), real backups including non-ASCII file names, then the same volume
# started again on each following image (an upgrade when the images differ).
#
# Usage: ./tests/e2e-upgrade-test.sh <image> [<next image>...]
# Reads IDRIVE_ACCOUNT, IDRIVE_PASSWORD and optionally IDRIVE_TOTP_SECRET, IDRIVE_ENCRYPTION_TYPE
# and IDRIVE_ENCRYPTION_KEY as plain values from .env in the repo root (or $ENV_FILE).
# Use a separate test account: each run creates an E2E-Test-... backup location there and
# uploads a few small files.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <image> [<next image>...]" >&2
    exit 2
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: Missing .env file at $ENV_FILE" >&2
    exit 1
fi

# Parse KEY=VALUE safely without executing shell expansions (handles unquoted values with spaces, e.g. TOTP secrets).
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    line="${raw_line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        key="${BASH_REMATCH[2]}"
        val="${BASH_REMATCH[3]}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        if [[ ( "$val" == \"*\" && "$val" == *\" ) || ( "$val" == \'*\' && "$val" == *\' ) ]] && [ "${#val}" -ge 2 ]; then
            val="${val:1:${#val}-2}"
        fi
        printf -v "$key" '%s' "$val"
        export "${key?}"
    fi
done < "$ENV_FILE"

if [ -z "${IDRIVE_ACCOUNT:-}" ] || [ -z "${IDRIVE_PASSWORD:-}" ]; then
    echo "ERROR: IDRIVE_ACCOUNT and IDRIVE_PASSWORD must be set in $ENV_FILE" >&2
    exit 1
fi

RUN_ID="idrive-e2e-$$"
VOL_NAME="${RUN_ID}-vol"
SRC_VOL="${RUN_ID}-src"
SEC_VOL="${RUN_ID}-sec"
CONTAINERS=()

scrub() {
    python3 -c '
import os, re, sys
txt = sys.stdin.read()
for var in ("IDRIVE_PASSWORD", "IDRIVE_ENCRYPTION_KEY", "IDRIVE_TOTP_SECRET", "IDRIVE_ACCOUNT"):
    val = os.environ.get(var, "")
    if val:
        txt = txt.replace(val, "<REDACTED>")
        if var == "IDRIVE_TOTP_SECRET":
            compact = re.sub(r"[\s-]+", "", val)
            if compact:
                txt = txt.replace(compact, "<REDACTED>")
        if var == "IDRIVE_ACCOUNT" and "@" in val:
            txt = txt.replace(val.lower(), "<REDACTED>")
            txt = txt.replace(val.split("@", 1)[0], "<REDACTED>")
sys.stdout.write(txt)
'
}

cleanup() {
    set +e
    for c in "${CONTAINERS[@]:-}"; do
        if [ -n "$c" ]; then docker rm -f "$c" >/dev/null 2>&1 || true; fi
    done
    docker volume rm -f "$VOL_NAME" "$SRC_VOL" "$SEC_VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_healthy() {
    local c="$1" i=0 status
    while [ "$i" -lt 45 ]; do
        status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo "missing")
        if [ "$status" = "healthy" ]; then
            return 0
        fi
        sleep 2
        i=$((i + 1))
    done
    echo "ERROR: Container $c did not become healthy (last status: $status)" >&2
    docker logs "$c" 2>&1 | scrub >&2 || true
    return 1
}

docker volume create "$VOL_NAME" >/dev/null
docker volume create "$SRC_VOL" >/dev/null
docker volume create "$SEC_VOL" >/dev/null

docker run --rm -v "${SRC_VOL}:/source/e2e" --entrypoint /bin/bash "$1" -c '
set -euo pipefail
printf "e2e test payload step 1\n" > /source/e2e/sample1.txt
printf "utf8 french accent test\n" > "/source/e2e/café-résumé.txt"
printf "utf8 japanese test\n" > "/source/e2e/日本語テスト.txt"
printf "utf8 umlaut test\n" > "/source/e2e/über-daten-2026.txt"
'

# Populate secret files inside a transient Docker volume via container stdin so credentials never appear in `docker inspect`.
docker run --rm -i -v "${SEC_VOL}:/sec" --entrypoint /bin/bash "$1" -c '
set -euo pipefail
IFS= read -r acct
IFS= read -r pwd
IFS= read -r ekey || true
IFS= read -r totp || true
printf "%s" "$acct" > /sec/idrive_account
printf "%s" "$pwd" > /sec/idrive_password
chmod 0400 /sec/idrive_account /sec/idrive_password
if [ -n "$ekey" ]; then
    printf "%s" "$ekey" > /sec/idrive_enc_key
    chmod 0400 /sec/idrive_enc_key
fi
if [ -n "$totp" ]; then
    printf "%s" "$totp" > /sec/idrive_totp_secret
    chmod 0400 /sec/idrive_totp_secret
fi
' <<EOF
${IDRIVE_ACCOUNT}
${IDRIVE_PASSWORD}
${IDRIVE_ENCRYPTION_KEY:-}
${IDRIVE_TOTP_SECRET:-}
EOF

LOC_NAME="E2E-Test-${RUN_ID}"
STEP=0
for img in "$@"; do
    STEP=$((STEP + 1))
    cname="${RUN_ID}-step${STEP}"
    CONTAINERS+=("$cname")
    echo "=== Step ${STEP}: Starting ${img} ==="

    env_args=(
        -e "TZ=${TZ:-Etc/UTC}"
        -e "IDRIVE_ACCOUNT_FILE=/run/secrets/idrive_account"
        -e "IDRIVE_PASSWORD_FILE=/run/secrets/idrive_password"
        -e "IDRIVE_BACKUP_LOCATION=${LOC_NAME}"
    )
    if [ -n "${IDRIVE_ENCRYPTION_TYPE:-}" ]; then
        env_args+=(-e IDRIVE_ENCRYPTION_TYPE)
    fi
    if [ -n "${IDRIVE_ENCRYPTION_KEY:-}" ]; then
        env_args+=(-e "IDRIVE_ENCRYPTION_KEY_FILE=/run/secrets/idrive_enc_key")
    fi
    if [ -n "${IDRIVE_TOTP_SECRET:-}" ]; then
        env_args+=(-e "IDRIVE_TOTP_SECRET_FILE=/run/secrets/idrive_totp_secret")
    fi

    docker run -d --name "$cname" \
        --health-interval=5s --health-start-period=3s \
        "${env_args[@]}" \
        -v "${VOL_NAME}:/opt/IDriveForLinux/idriveIt" \
        -v "${SRC_VOL}:/source/e2e:ro" \
        -v "${SEC_VOL}:/run/secrets:ro" \
        "$img" >/dev/null

    wait_healthy "$cname"

    if [ "$STEP" -eq 1 ]; then
        docker exec "$cname" /bin/bash -c '
        set -euo pipefail
        acct_dir=$(find /opt/IDriveForLinux/idriveIt/user_profile/root -mindepth 1 -maxdepth 1 -type d ! -name ".*" | head -n 1)
        printf "/source/e2e\n" > /tmp/bkset.txt
        /opt/IDriveForLinux/bin/idrive --utilities ENCRYPT /tmp/bkset.txt "$acct_dir/Backup/DefaultBackupSet/BackupsetFile.enc" >/dev/null
        rm -f /tmp/bkset.txt
        '
    else
        docker run --rm -e "STEP=${STEP}" -v "${SRC_VOL}:/source/e2e" --entrypoint /bin/bash "$img" -c '
        set -euo pipefail
        printf "e2e test payload step %s\n" "$STEP" > "/source/e2e/sample${STEP}.txt"
        printf "utf8 incremental step %s\n" "$STEP" > "/source/e2e/naïve-über-step${STEP}.txt"
        '
    fi

    docker exec "$cname" /opt/IDriveForLinux/bin/idrive --backup --silent 2>&1 | scrub

    docker exec "$cname" /bin/bash -c '
    set -euo pipefail
    acct_dir=$(find /opt/IDriveForLinux/idriveIt/user_profile/root -mindepth 1 -maxdepth 1 -type d ! -name ".*" | head -n 1)
    latest=$(ls -1t "$acct_dir/Backup/DefaultBackupSet/LOGS" | head -n 1)
    [ -n "$latest" ] || { echo "No backup log generated" >&2; exit 1; }
    log_path="$acct_dir/Backup/DefaultBackupSet/LOGS/$latest"
    grep -E "Files considered for backup|Files backed up now|Files failed to backup|Summary|Backup End Time" "$log_path" || true
    grep -Eq "Files failed to backup[[:space:]]*:[[:space:]]*0" "$log_path" || { echo "Backup reported failed files" >&2; cat "$log_path" >&2; exit 1; }
    grep -qE "\[SUCCESS\].*(café-résumé\.txt|日本語テスト\.txt|über-daten-2026\.txt|naïve-über-step)" "$log_path" || { echo "Expected UTF-8 non-ASCII filename [SUCCESS] entry in log" >&2; cat "$log_path" >&2; exit 1; }
    ' | scrub

    docker stop -t 10 "$cname" >/dev/null
done

echo "PASS: E2E upgrade chain succeeded across $STEP image versions."
