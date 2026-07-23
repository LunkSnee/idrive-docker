#!/bin/bash
set -eo pipefail

VERSION_URL="https://www.idrivedownloads.com/downloads/linux/download-for-linux/version-linux.js"

# Try to extract the script version and its (cache-busted) download URL. Use curl -f to fail gracefully if unreachable.
RAW=$(curl -fsSL "$VERSION_URL" || true)
VERSION=$(echo "$RAW" | grep -oP 'var\s+linuxScriptVersion\s*=\s*"Version\s+\K[0-9.]+(?=")' || true)
URL=$(echo "$RAW" | grep -oP "var\s+linuxScriptPackageURL\s*=\s*'\K[^']+(?=')" || true)

if [ -n "$VERSION" ]; then
  echo "iDrive latest version: $VERSION"
  echo "idrive_version=$VERSION" >> $GITHUB_OUTPUT
else
  echo "iDrive latest version: (not found)"
  # Do NOT set idrive_version to an empty value. Leave it unset so workflow can guard on its existence.
fi

if [ -n "$URL" ]; then
  echo "iDrive download URL: $URL"
  echo "idrive_URL=$URL" >> $GITHUB_OUTPUT
else
  echo "iDrive download URL: (not found)"
  # Do NOT set idrive_URL to an empty value. Leave it unset so the Dockerfile's ARG default is used instead.
fi
