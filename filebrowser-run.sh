#!/bin/sh
# Started by mpc_filebrowser_addin.so each time MPC starts, as its own process (ADDIN_DIR = this folder, MPC_PID = MPC).
# Writes FileBrowser's config from mpc_filebrowser_addin.conf, runs ./filebrowser, starts it again if it exits (waiting
# longer each time it fails quickly), and stops it once MPC has exited. Plain POSIX sh: it runs in the device's BusyBox.
set -u
D=${ADDIN_DIR:?}
MPC=${MPC_PID:?}
cd "$D" || exit 1
umask 077
CONF=mpc_filebrowser_addin.conf
PIDFILE=filebrowser.pid

# The last value of a key in the settings file, without surrounding blanks or quotes ("" when it is missing).
conf() {
    v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=//p" "$CONF" 2>/dev/null | tail -n 1)
    v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"\(.*\)"$/\1/')
    printf '%s' "$v"
}
say() { echo "$(date '+%Y-%m-%d %H:%M:%S') filebrowser-run: $*" >> "$LOG"; }

LOG=$(conf log)
case "$LOG" in /*) ;; *) LOG=/dev/null ;; esac

BIND=$(conf bind); PORT=$(conf port); SOURCES=$(conf sources); INDEX=$(conf index); PREVIEWS=$(conf previews)
MEMORY=$(conf memory_mb); USERCFG=$(conf config)
case "$BIND" in ''|*[!0-9A-Fa-f.:]*) BIND=127.0.0.1 ;; esac
case "$PORT" in ''|*[!0-9]*) PORT=6740 ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || PORT=6740
[ -n "$SOURCES" ] || SOURCES=/media:/storage
[ "$INDEX" = 1 ] || INDEX=0
[ "$PREVIEWS" = 0 ] || PREVIEWS=1
case "$MEMORY" in ''|*[!0-9]*) MEMORY=192 ;; esac

# A YAML double-quoted string. The settings refuse " and \ in paths, so nothing needs escaping.
q() { printf '"%s"' "$1"; }

# The admin password: made once, kept in admin-password (readable by root only) and used for every config written.
if [ ! -s admin-password ]; then
    pw=$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16)
    [ ${#pw} -eq 16 ] || { say "can't make a password"; exit 1; }
    printf '%s\n' "$pw" > admin-password.new && mv admin-password.new admin-password
fi
PASSWORD=$(head -n 1 admin-password)

write_config() {
    {
        echo "# Written by filebrowser-run.sh each time MPC starts, from $CONF: edits here are lost."
        echo "# To run FileBrowser with a config of your own, set config=/path/to/it.yaml there."
        echo "http:"
        echo "  listen: $(q "$BIND")"
        echo "  port: $PORT"
        echo "server:"
        echo "  disableUpdateCheck: true"
        echo "  numImageProcessors: 1"
        [ "$PREVIEWS" = 1 ] && echo "  disablePreviews: false" || echo "  disablePreviews: true"
        echo "  cacheDir: $(q "$D/cache")"
        echo "  cacheDirCleanup: true"
        echo "  database:"
        echo "    path: $(q "$D/filebrowser.sqlite")"
        echo "  logging:"
        echo "    - levels: \"info|warning|error\""
        echo "      noColors: true"
        echo "  sources:"
        names=" "
        old_ifs=$IFS; IFS=:
        for p in $SOURCES; do
            IFS=$old_ifs
            case "$p" in /*) ;; *) say "sources: $p is not an absolute path, skipped"; continue ;; esac
            case "$p" in *\"*|*\\*) say "sources: $p holds a quote or backslash, skipped"; continue ;; esac
            [ -d "$p" ] || { say "sources: no folder $p, skipped"; continue; }
            [ -n "$(ls -A "$p" 2>/dev/null)" ] || { say "sources: $p is empty (nothing mounted there?), skipped"; continue; }
            n=${p%/}; n=${n##*/}; [ -n "$n" ] || n=root
            k=2; base=$n
            while case "$names" in *" $n "*) true ;; *) false ;; esac; do n="$base-$k"; k=$((k + 1)); done
            names="$names$n "
            echo "    - path: $(q "$p")"
            echo "      name: $(q "$n")"
            echo "      config:"
            echo "        defaultEnabled: true"
            if [ "$INDEX" = 0 ]; then   # browse only: no index of the whole drive, so no disk scan while MPC plays
                echo "        rules:"
                echo "          - folderPath: \"/\""
                echo "            viewable: true"
            fi
        done
        IFS=$old_ifs
        echo "auth:"
        echo "  adminUsername: admin"
        echo "  adminPassword: $(q "$PASSWORD")"
        echo "  methods:"
        echo "    password:"
        echo "      enabled: true"
        echo "      signup: false"
    } > config.yaml.new
    grep -q '^    - path:' config.yaml.new || { say "no usable folder in sources=$SOURCES"; rm -f config.yaml.new; return 1; }
    mv config.yaml.new config.yaml
}

if [ -n "$USERCFG" ]; then
    CFG=$USERCFG
    [ -r "$CFG" ] || { say "config=$CFG can't be read"; exit 1; }
else
    CFG=$D/config.yaml
    write_config || exit 1
fi

alive() { [ -r "/proc/$1/stat" ] && ! sed 's/.*) //' "/proc/$1/stat" | grep -q '^Z'; }

# A FileBrowser left by an earlier MPC (still stopping, or started by a launcher that doesn't stop it): stop it first.
if [ -s "$PIDFILE" ]; then
    old=$(cat "$PIDFILE")
    case "$old" in ''|*[!0-9]*) ;; *)
        # ours: run from this folder as ./filebrowser -c (by cwd and command line; exe can name an emulator in tests)
        if alive "$old" && [ "$(readlink "/proc/$old/cwd" 2>/dev/null)" = "$D" ] &&
            tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q '\./filebrowser -c '; then
            say "stopping the FileBrowser of an earlier MPC run ($old)"
            kill "$old" 2>/dev/null
            i=0; while alive "$old" && [ $i -lt 25 ]; do sleep 0.2; i=$((i + 1)); done
            alive "$old" && kill -9 "$old" 2>/dev/null
        fi ;;
    esac
fi

chmod 755 filebrowser 2>/dev/null   # the installer copies every file as 644
export GOMAXPROCS=2 GOMEMLIMIT="${MEMORY}MiB" HOME="$D"
FB=""
start() {
    ./filebrowser -c "$CFG" < /dev/null >> "$LOG" 2>&1 &
    FB=$!
    echo "$FB" > "$PIDFILE"
    STARTED=$(date +%s)
    say "started FileBrowser $FB on $BIND:$PORT"
}
stop() {
    trap - TERM INT HUP
    if [ -n "$FB" ] && alive "$FB"; then
        kill "$FB" 2>/dev/null
        i=0; while alive "$FB" && [ $i -lt 25 ]; do sleep 0.2; i=$((i + 1)); done
        alive "$FB" && kill -9 "$FB" 2>/dev/null
        wait "$FB" 2>/dev/null
    fi
    rm -f "$PIDFILE"
    say "stopped"
    exit 0
}
trap stop TERM INT HUP

say "MPC $MPC started; sources=$SOURCES index=$INDEX"
DELAY=5
start
while kill -0 "$MPC" 2>/dev/null; do
    if ! alive "$FB"; then
        wait "$FB" 2>/dev/null; rc=$?
        ran=$(( $(date +%s) - STARTED ))
        [ $ran -ge 60 ] && DELAY=5
        say "FileBrowser exited ($rc) after ${ran}s; starting it again in ${DELAY}s"
        sleep "$DELAY"
        DELAY=$((DELAY * 2)); [ $DELAY -le 300 ] || DELAY=300
        kill -0 "$MPC" 2>/dev/null || break
        start
    fi
    sleep 2
done
say "MPC $MPC has exited"
stop
