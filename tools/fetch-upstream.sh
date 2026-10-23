#!/usr/bin/env bash
# Downloads the FileBrowser Quantum release named in upstream.env (the binary for one CPU, and the licence) into a
# folder and refuses them unless their SHA-256 matches upstream.env. Nothing downloaded is committed.
# Usage: tools/fetch-upstream.sh armv7|aarch64 <folder>
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 2 ] || { echo "usage: $0 armv7|aarch64 <folder>" >&2; exit 2; }
arch=$1 out=$2
. ./upstream.env
case "$arch" in
    armv7) asset=linux-armv7-filebrowser sum=$FB_SHA256_ARMV7 want="ELF 32-bit LSB executable, ARM" ;;
    aarch64) asset=linux-arm64-filebrowser sum=$FB_SHA256_ARM64 want="ELF 64-bit LSB executable, ARM aarch64" ;;
    *) echo "unknown arch $arch" >&2; exit 2 ;;
esac
mkdir -p "$out"
get() {   # url, file, sha256
    curl -fsSL --retry 3 -o "$out/$2.part" "$1"
    got=$(sha256sum "$out/$2.part" | cut -d' ' -f1)
    if [ "$got" != "$3" ]; then
        rm -f "$out/$2.part"
        echo "$2 from $1: sha256 $got, upstream.env expects $3" >&2
        exit 1
    fi
    mv "$out/$2.part" "$out/$2"
}
get "https://github.com/$FB_REPO/releases/download/$FB_TAG/$asset" filebrowser "$sum"
get "https://raw.githubusercontent.com/$FB_REPO/$FB_TAG/LICENSE" LICENSE-filebrowser "$FB_SHA256_LICENSE"
# it must not depend on the device's libraries: a static executable for the device's CPU
info=$(file -b "$out/filebrowser")
case "$info" in "$want"*"statically linked"*) ;; *) echo "filebrowser is not a static $arch executable: $info" >&2; exit 1 ;; esac
echo "FileBrowser Quantum $FB_TAG ($arch): $out/filebrowser ($(du -h "$out/filebrowser" | cut -f1))"
