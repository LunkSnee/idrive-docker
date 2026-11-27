#!/bin/bash
set -eo pipefail

VERSION_URL="https://www.idrivedownloads.com/downloads/linux/download-for-linux/version-linux.js"

# Extract the script version and its (cache-busted) download URL. curl -f makes an
# unreachable or erroring endpoint fail here, with curl's own diagnostic, rather than
# surfacing later as a confusing "not found".
RAW=$(curl -fsSL "$VERSION_URL")
VERSION=$(echo "$RAW" | grep -oP 'var\s+linuxScriptVersion\s*=\s*"Version\s+\K[0-9.]+(?=")' || true)
URL=$(echo "$RAW" | grep -oP "var\s+linuxScriptPackageURL\s*=\s*'\K[^']+(?=')" || true)

if [ -z "$VERSION" ] || [ -z "$URL" ]; then
  echo "Error: iDrive latest version or download URL not found at $VERSION_URL"
  exit 1
fi

echo "iDrive latest version: $VERSION"
echo "iDrive download URL: $URL"
echo "idrive_version=$VERSION" >> $GITHUB_OUTPUT
echo "idrive_URL=$URL" >> $GITHUB_OUTPUT

# Release date, used to hold the :latest tag back until a release has had time to
# surface problems, rather than following a brand-new version the day it appears.
#
# The page carries it as: var linuxScriptDate = "Released on MM/DD/YYYY";
REL_DATE=$(echo "$RAW" | grep -oP 'var\s+linuxScriptDate\s*=\s*"Released on\s+\K[0-9]{2}/[0-9]{2}/[0-9]{4}(?=")' || true)
# MM/DD/YYYY -> YYYY-MM-DD so date(1) can read it. Empty input yields empty output.
REL_ISO=$(printf '%s' "$REL_DATE" | awk -F/ 'NF==3{printf "%s-%s-%s", $3, $1, $2}')

if [ -n "$REL_ISO" ] && REL_EPOCH=$(date -u -d "$REL_ISO" +%s 2>/dev/null); then
  AGE_DAYS=$(( ( $(date -u +%s) - REL_EPOCH ) / 86400 ))
  echo "iDrive release date: $REL_ISO (${AGE_DAYS} days ago)"
  echo "idrive_release_date=$REL_ISO" >> $GITHUB_OUTPUT
  echo "idrive_age_days=$AGE_DAYS" >> $GITHUB_OUTPUT
else
  # Deliberately leave idrive_age_days unset. The workflow treats an unknown age as
  # "do not move :latest", so a format change here freezes :latest on the last known
  # good version instead of silently promoting an untested one.
  echo "WARNING: could not determine the iDrive release date from $VERSION_URL;" >&2
  echo "         :latest will not be promoted until this is resolved." >&2
fi
