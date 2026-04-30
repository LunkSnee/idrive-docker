#!/bin/bash
set -eo pipefail

VERSION_URL="https://www.idrivedownloads.com/downloads/linux/download-for-linux/linux-backup.script.js"

# Try to extract a version like 1.2.3 (numbers and dots). Use curl -f to fail gracefully if unreachable.
RAW=$(curl -fsSL "$VERSION_URL" || true)
VERSION=$(echo "$RAW" | grep -oP 'var\s+linuxVersion\s*=\s*"\K[0-9.]+(?=")' || true)

if [ -n "$VERSION" ]; then
  echo "iDrive latest version: $VERSION"
  echo "idrive_version=$VERSION" >> $GITHUB_OUTPUT
else
  echo "iDrive latest version: (not found)"
  # Do NOT set idrive_version to an empty value. Leave it unset so workflow can guard on its existence.
fi
