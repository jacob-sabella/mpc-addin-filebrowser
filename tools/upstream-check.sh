#!/usr/bin/env bash
# Whether FileBrowser Quantum has a stable release newer than upstream.env's. If so, rewrites upstream.env for it (the
# SHA-256 of each binary and of the licence, as downloaded now) and prints the new tag; prints nothing otherwise.
# Only "-stable" tags count (upstream also publishes "-beta" ones, not marked as prereleases). Needs gh and curl.
# Usage: tools/upstream-check.sh [<tag>]   (a tag: move to that one instead of the newest)
set -euo pipefail
cd "$(dirname "$0")/.."
. ./upstream.env
tag=${1:-$(gh api "repos/$FB_REPO/releases?per_page=50" \
    --jq '[.[] | select(.draft | not) | select(.prerelease | not) | select(.tag_name | endswith("-stable"))][0].tag_name')}
[ -n "$tag" ] && [ "$tag" != null ] || { echo "no stable release found in $FB_REPO" >&2; exit 1; }
[ "$tag" != "$FB_TAG" ] || exit 0
newest=$(printf '%s\n%s\n' "${FB_TAG#v}" "${tag#v}" | sort -V | tail -n 1)
[ $# -eq 1 ] || [ "$newest" = "${tag#v}" ] || exit 0   # never move back to an older one on its own
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sum() { curl -fsSL --retry 3 -o "$T/f" "$1" && sha256sum "$T/f" | cut -d' ' -f1; }
armv7=$(sum "https://github.com/$FB_REPO/releases/download/$tag/linux-armv7-filebrowser")
arm64=$(sum "https://github.com/$FB_REPO/releases/download/$tag/linux-arm64-filebrowser")
lic=$(sum "https://raw.githubusercontent.com/$FB_REPO/$tag/LICENSE")
sed -i "s/^FB_TAG=.*/FB_TAG=$tag/; s/^FB_SHA256_ARMV7=.*/FB_SHA256_ARMV7=$armv7/; s/^FB_SHA256_ARM64=.*/FB_SHA256_ARM64=$arm64/; s/^FB_SHA256_LICENSE=.*/FB_SHA256_LICENSE=$lic/" upstream.env
echo "$tag"
