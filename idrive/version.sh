#!/bin/bash

VERSION_URL="https://www.idrivedownloads.com/downloads/linux/download-for-linux/version-linux.js"
VERSION_JS=$(curl -s $VERSION_URL)
VERSION=$(echo "$VERSION_JS" | grep '^var linuxScriptVersion =' | sed 's/var linuxScriptVersion = "Version \([0-9.]*\)".*/\1/')
DL_URL=$(echo "$VERSION_JS" | grep '^var linuxScriptPackageURL = ' | sed "s|var linuxScriptPackageURL = '\(https://.*\)'.*|\1|")

if [ -z "$VERSION" ] || [ -z "$DL_URL" ]; then
  echo "Error: iDrive latest version or download URL not found"
  exit 1
fi

echo "iDrive latest version: $VERSION"
echo "iDrive download URL: $DL_URL"
echo "idrive_version=$VERSION" >> $GITHUB_OUTPUT
echo "idrive_URL=$DL_URL" >> $GITHUB_OUTPUT
exit 0
