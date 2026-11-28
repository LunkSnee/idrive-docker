#!/bin/sh
# idrive-fetch.sh <url> <file> <pattern>: download <url> from IDrive's servers to <file>, and
# check that its first 4 KB match the grep pattern <pattern> (the installer starts with "#!",
# the version file names linuxScriptVersion).
#
# IDrive's servers sometimes answer GitHub's runners with a web page instead, still HTTP 200, so
# curl -f cannot tell. Such an answer is tried again, at most 3 times, 60 s apart (gently, in case
# it is a rate limit), and each miss is reported with the HTTP status, the address it ended up at
# and the page's title. Requests name this project in their User-Agent.
# Used by the Dockerfile (plain sh), scripts/version.sh and the Build and Publish workflow.
set -eu
url=$1
out=$2
pattern=$3
ua="idrive-docker-build (+${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-LunkSnee/idrive-docker})"

for attempt in 1 2 3; do
    rc=0
    meta=$(curl -fsSL --connect-timeout 20 -A "$ua" -w '%{http_code} %{url_effective}' -o "$out" "$url") || rc=$?
    if [ "$rc" = 0 ] && head -c 4096 "$out" | grep -q -- "$pattern"; then
        exit 0
    fi
    title=$(head -c 65536 "$out" 2>/dev/null | tr -d '\r\n' |
        sed -n 's:.*<[Tt][Ii][Tt][Ll][Ee][^>]*>\([^<]*\)<.*:\1:p' | head -c 200)
    echo "Attempt $attempt: $url did not return the expected file" \
        "(curl exit $rc, HTTP ${meta%% *} from ${meta#* }${title:+, page title \"$title\"})." >&2
    if [ "$attempt" = 3 ]; then
        echo "It starts: $(head -c 160 "$out" 2>/dev/null | tr -cd '[:print:]')" >&2
        exit 1
    fi
    echo "Trying again in 60 s." >&2
    sleep 60
done
