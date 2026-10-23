#!/usr/bin/env bash
# Host tests (x86): the library preloaded into a process named MPC starts filebrowser-run.sh as a detached process (own
# session, not MPC's child, no LD_PRELOAD, the settings' nice value), the script runs ./filebrowser (a stand-in here)
# with the config it wrote, and stops it once MPC exits; enabled=0, a process with another name and a missing script
# start nothing and leave MPC running. Runs the script in BusyBox too when it is installed. tests/smoke.sh runs the real
# FileBrowser binary under QEMU.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
cleanup() { pkill -f "$T/" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT
gcc -std=gnu11 -O1 -g -Wall -Wextra -Werror -fPIC -shared -fvisibility=hidden -o "$T/mpc_filebrowser_addin.so" src/filebrowser.c
mkdir -p "$T/bin" "$T/src/Samples"
cp "$(command -v sleep)" "$T/bin/MPC"
cp "$(command -v sleep)" "$T/bin/other"
echo x > "$T/src/Samples/kick.wav"
fail=0; check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
wait_for() { i=0; while [ $i -lt 50 ]; do eval "$1" && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
gone() { [ ! -d "/proc/$1" ] || grep -q '^State:.*Z' "/proc/$1/status"; }
field() { sed 's/.*) //' "/proc/$1/stat" | cut -d' ' -f"$2"; }   # fields counted from 3 (state)

# a fresh addin folder: the library, the script, a stand-in filebrowser and settings with the given extra lines
setup() {
    rm -rf "$T/addin"; mkdir -p "$T/addin"
    cp "$T/mpc_filebrowser_addin.so" filebrowser-run.sh "$T/addin/"
    cat > "$T/addin/filebrowser" <<'EOF'
#!/bin/sh
env > "$HOME/fake.env"; echo "$@" > "$HOME/fake.args"; echo $$ > "$HOME/fake.pid"
trap 'echo stopped > "$HOME/fake.stopped"; exit 0' TERM
while :; do sleep 0.2; done
EOF
    chmod 644 "$T/addin/filebrowser"   # as the installer leaves it
    { echo "sources=$T/src:$T/missing"; echo "nice=17"; echo "log=$T/addin/log.txt"; printf '%s\n' "$@"; } > "$T/addin/mpc_filebrowser_addin.conf"
}
mpc() {   # start "MPC" (or another program) with the addin preloaded; sets PID
    LD_PRELOAD="$T/addin/mpc_filebrowser_addin.so" "$T/bin/${1:-MPC}" 60 2> "$T/mpc.err" &
    PID=$!
}

for SH in /bin/sh $(command -v busybox >/dev/null && echo busybox); do
    echo "--- script run by $SH"
    if [ "$SH" = busybox ]; then
        printf '#!/bin/sh\nexec %s sh "$@"\n' "$(command -v busybox)" > "$T/bin/bbsh"; chmod 755 "$T/bin/bbsh"
        export MPC_FILEBROWSER_ADDIN_SH="$T/bin/bbsh"
    else
        unset MPC_FILEBROWSER_ADDIN_SH
    fi
    setup; mpc
    check "filebrowser started" 'wait_for "[ -s $T/addin/fake.pid ]"'
    FB=$(cat "$T/addin/fake.pid" 2>/dev/null || echo 0)
    RUNNER=$(field "$FB" 2 2>/dev/null || echo 0)   # its parent: the script
    check "started with the config it wrote" 'grep -q -- "-c $T/addin/config.yaml" "$T/addin/fake.args" && grep -q "path: \"$T/src\"" "$T/addin/config.yaml"'
    check "a missing source is skipped" '! grep -q "$T/missing" "$T/addin/config.yaml" && grep -q "no folder $T/missing" "$T/addin/log.txt"'
    check "no LD_PRELOAD in its environment" '! grep -q LD_PRELOAD "$T/addin/fake.env"'
    check "MPC_PID is MPC" 'grep -qx "MPC_PID=$PID" "$T/addin/fake.env"'
    check "Go limits set" 'grep -qx "GOMAXPROCS=2" "$T/addin/fake.env" && grep -qx "GOMEMLIMIT=192MiB" "$T/addin/fake.env"'
    check "script is not MPC's child" '[ "$(field "$RUNNER" 2)" != "$PID" ]'
    check "script has its own session" '[ "$(field "$RUNNER" 4)" != "$(field "$PID" 4)" ]'
    check "nice value from the settings" '[ "$(field "$FB" 17)" = 17 ]'
    check "binary made executable" '[ -x "$T/addin/filebrowser" ]'
    check "default password given at the first start" 'grep -qx mpcadmin "$T/addin/password.given" && grep -q "adminPassword: \"mpcadmin\"" "$T/addin/config.yaml"'
    check "MPC itself still running" '! gone "$PID"'
    kill "$PID"; wait "$PID" 2>/dev/null || true
    check "filebrowser stopped after MPC exits" 'wait_for "gone $FB" && [ -e "$T/addin/fake.stopped" ]'
    check "script gone too" 'wait_for "gone $RUNNER"'
done
unset MPC_FILEBROWSER_ADDIN_SH

echo "--- refusals"
setup "enabled=0"; mpc; sleep 1
check "enabled=0 starts nothing" '[ ! -e "$T/addin/fake.pid" ] && grep -q "disabled in" "$T/mpc.err"'
kill "$PID" 2>/dev/null || true
setup; mpc other; sleep 1
check "a process not named MPC starts nothing" '[ ! -e "$T/addin/fake.pid" ] && ! grep -q mpc-filebrowser-addin "$T/mpc.err"'
kill "$PID" 2>/dev/null || true
setup; rm "$T/addin/filebrowser-run.sh"; mpc; sleep 1
check "no script: says so, MPC keeps running" 'grep -q "reinstall the addin" "$T/mpc.err" && ! gone "$PID"'
kill "$PID" 2>/dev/null || true
setup "sources=$T/missing"; mpc; sleep 1
check "no usable source: nothing started, logged" '[ ! -e "$T/addin/fake.pid" ] && grep -q "no usable folder" "$T/addin/log.txt"'
kill "$PID" 2>/dev/null || true
setup "bind=1.2.3.4; rm -rf /" "port=99999"; mpc
check "bad bind and port fall back to the defaults" 'wait_for "[ -s $T/addin/fake.pid ]" && grep -q "listen: \"127.0.0.1\"" "$T/addin/config.yaml" && grep -q "port: 6760" "$T/addin/config.yaml"'
kill "$PID" 2>/dev/null || true
setup "password=admin"; mpc
check "password admin refused: the default given" 'wait_for "[ -s $T/addin/password.given ]" && grep -qx mpcadmin "$T/addin/password.given" && grep -q "won.t take" "$T/addin/log.txt"'
kill "$PID" 2>/dev/null || true

wait_for 'gone "$(cat "$T/addin/fake.pid" 2>/dev/null || echo 0)"' || true
[ $fail = 0 ] && echo PASSED || { echo FAILED; cat "$T/mpc.err" "$T/addin/log.txt" 2>/dev/null; exit 1; }
