#!/bin/bash
set -eo pipefail

VERSION_URL="https://www.idrivedownloads.com/downloads/linux/download-for-linux/version-linux.js"

# Try to extract the script version and its (cache-busted) download URL. Use curl -f to fail gracefully if unreachable.
RAW=$(curl -fsSL "$VERSION_URL" || true)
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
