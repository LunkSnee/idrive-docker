#!/bin/sh
# fetch-installer.sh <url> <file>: download IDrive's installer to <file>.
#
# IDrive's download link sometimes answers with a web page instead of the installer, still with
# HTTP 200, so curl -f cannot tell. The installer is a shell script: anything not starting with
# "#!" is downloaded again, up to 5 times, 15 s apart, before failing with the start of what came
# back. Used by the Dockerfile (plain sh) and by the Build and Publish workflow.
set -eu
url=$1
out=$2
for attempt in 1 2 3 4 5; do
    if curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 20 -o "$out" "$url" &&
        [ "$(head -c 2 "$out")" = '#!' ]; then
        exit 0
    fi
    if [ "$attempt" = 5 ]; then
        echo "IDrive's download link did not return its installer. It returned: $(head -c 120 "$out" 2>/dev/null | tr -cd '[:print:]')" >&2
        exit 1
    fi
    echo "Download attempt $attempt did not return IDrive's installer; trying again in 15 s." >&2
    sleep 15
done
