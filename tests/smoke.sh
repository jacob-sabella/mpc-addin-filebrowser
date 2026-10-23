#!/usr/bin/env bash
# The real FileBrowser binary from a build (./build.sh [aarch64] first) run by filebrowser-run.sh in BusyBox, under QEMU
# for the device's CPU: the first run is restarted once its database exists (no new-database warning), the admin logs in
# with the default password and a wrong one fails, a second start (MPC restarted) replaces the first and doesn't give the
# password again, a changed password setting is given at the next start, an empty source folder is skipped, and
# FileBrowser stops once "MPC" (a sleep standing in for it) exits. Needs Docker with QEMU for the target.
# Usage: tests/smoke.sh [armv7|aarch64]
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH=${1:-armv7}
case "$ARCH" in
    armv7) PKG=build PLATFORM=linux/arm/v7 IMAGE=arm32v7/busybox ;;
    aarch64) PKG=build/aarch64 PLATFORM=linux/arm64 IMAGE=arm64v8/busybox ;;
    *) echo "usage: $0 [armv7|aarch64]" >&2; exit 2 ;;
esac
[ -x "$PKG/mpc_filebrowser_addin.so" ] && [ -f "$PKG/filebrowser" ] || { echo "no build in $PKG: run ./build.sh $ARCH" >&2; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/addin" "$T/m/Drive1/Samples" "$T/empty"
find "$PKG" -maxdepth 1 -type f -exec cp {} "$T/addin/" \;
chmod 644 "$T/addin/filebrowser"   # as the installer leaves it
echo x > "$T/m/Drive1/Samples/kick.wav"
sed -i 's#^sources=.*#sources=/m:/empty:/missing#; s#^log=.*#log=/addin/log.txt#' "$T/addin/mpc_filebrowser_addin.conf"
docker run --rm --platform "$PLATFORM" -v "$T/addin:/addin" -v "$T/m:/m" -v "$T/empty:/empty" "$IMAGE" sh -c '
fail=0; check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
up() { i=0; while [ $i -lt 90 ]; do wget -q -O /tmp/h http://127.0.0.1:6740/health 2>/dev/null && return 0; sleep 1; i=$((i + 1)); done; return 1; }
login() { wget -q -O /tmp/tok --header "X-Password: $1" --post-data "" "http://127.0.0.1:6740/api/auth/login?username=admin" 2>/dev/null; }
fb_pid() { cat /addin/filebrowser.pid 2>/dev/null; }
sleep 1000 & MPC1=$!
ADDIN_DIR=/addin MPC_PID=$MPC1 sh /addin/filebrowser-run.sh &
primed() { i=0; while [ $i -lt 120 ]; do grep -q "first run: starting FileBrowser again" /addin/log.txt 2>/dev/null && return 0; sleep 1; i=$((i + 1)); done; return 1; }
check "first run restarted once its database exists" primed
check "answers" up
PW=mpcadmin
check "admin logs in with the default password" "login \"$PW\" && [ -s /tmp/tok ]"
check "a wrong password fails" "! login wrong-password"
check "config readable by root only" "[ \"\$(stat -c %a /addin/config.yaml)\" = 600 ] && [ \"\$(stat -c %a /addin/password.given)\" = 600 ]"
check "empty and missing sources skipped" "grep -q \"path: \\\"/m\\\"\" /addin/config.yaml && ! grep -q /empty /addin/config.yaml && ! grep -q /missing /addin/config.yaml"
check "the admin is not greeted with the new-database warning" "wget -q -O /tmp/me --header \"Authorization: Bearer \$(cat /tmp/tok)\" \"http://127.0.0.1:6740/api/users?username=admin\" && grep -q \"\\\"showFirstLogin\\\":false\" /tmp/me"
check "no index by default" "grep -q \"viewable: true\" /addin/config.yaml"
FIRST=$(fb_pid)
sleep 1000 & MPC2=$!          # MPC restarted while the first run is still up
ADDIN_DIR=/addin MPC_PID=$MPC2 sh /addin/filebrowser-run.sh &
sleep 3
check "second start stops the first FileBrowser" "[ ! -d /proc/$FIRST ] || grep -q \"^State:.*Z\" /proc/$FIRST/status"
check "second start answers" up
check "password not given again" "grep -q \"adminPassword: \\\"\\\"\" /addin/config.yaml && login \"$PW\""
sed -i "s/^password=.*/password=changed-in-conf/" /addin/mpc_filebrowser_addin.conf
sleep 1000 & MPC3=$!          # MPC restarted after the setting changed
ADDIN_DIR=/addin MPC_PID=$MPC3 sh /addin/filebrowser-run.sh &
sleep 3
check "a changed setting is given at the next start" "up && login changed-in-conf && ! login \"$PW\""
SECOND=$(fb_pid)
kill $MPC1 $MPC2 $MPC3
sleep 6
check "stops when MPC exits" "[ ! -d /proc/$SECOND ] || grep -q \"^State:.*Z\" /proc/$SECOND/status"
check "pid file removed" "[ ! -e /addin/filebrowser.pid ]"
chmod -R a+rwX /addin 2>/dev/null; [ $fail = 0 ] || { echo "--- log"; tail -n 40 /addin/log.txt; exit 1; }
'
echo "PASSED ($ARCH)"
