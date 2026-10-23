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
case "$PORT" in ''|*[!0-9]*) PORT=6760 ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || PORT=6760
[ -n "$SOURCES" ] || SOURCES=/media:/storage
[ "$INDEX" = 1 ] || INDEX=0
[ "$PREVIEWS" = 0 ] || PREVIEWS=1
case "$MEMORY" in ''|*[!0-9]*) MEMORY=192 ;; esac

# A YAML double-quoted string. The settings refuse " and \ in paths, so nothing needs escaping.
q() { printf '"%s"' "$1"; }

# The admin password. FileBrowser sets the admin's password to auth.adminPassword at every start (unless it is blank or
# "admin"), which would undo a change made in its settings page. So the password from the settings goes into the config
# only when the database is new or the setting differs from the one last given (kept in password.given, root only);
# otherwise the config has it blank and the password set in FileBrowser stays.
DEFAULT_PASSWORD=mpcadmin
PASSWORD=$(conf password)
case "$PASSWORD" in
    '') PASSWORD=$DEFAULT_PASSWORD ;;
    admin|*\"*|*\\*) say "password: FileBrowser won't take \"admin\", a quote or a backslash; using $DEFAULT_PASSWORD"
        PASSWORD=$DEFAULT_PASSWORD ;;
esac
[ ${#PASSWORD} -ge 5 ] || { say "password: shorter than FileBrowser's 5 characters; using $DEFAULT_PASSWORD"; PASSWORD=$DEFAULT_PASSWORD; }
GIVE=""
if [ ! -e filebrowser.sqlite ] || [ "$(cat password.given 2>/dev/null)" != "$PASSWORD" ]; then GIVE=$PASSWORD; fi

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
            case "${p%/}" in   # the name shown for it: the device's two usual folders by what they hold
                /media) n=Drives ;; /storage) n=Storage ;; *) n=${p%/}; n=${n##*/}; [ -n "$n" ] || n=root ;;
            esac
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
        echo "  adminPassword: $(q "$GIVE")"
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
GIVEN=""
start() {
    # The password went to an earlier run that made the database: give it no more (blank leaves the stored one alone),
    # so a restart (a crash, the first-run restart) keeps a password set in FileBrowser meanwhile.
    if [ -n "$GIVEN" ] && [ -e filebrowser.sqlite ]; then GIVEN=""; GIVE=""; write_config; fi
    ./filebrowser -c "$CFG" < /dev/null >> "$LOG" 2>&1 &
    FB=$!
    echo "$FB" > "$PIDFILE"
    STARTED=$(date +%s)
    say "started FileBrowser $FB on $BIND:$PORT"
    if [ -n "$GIVE" ] && [ -z "$USERCFG" ]; then
        say "admin password set from $CONF"
        printf '%s\n' "$PASSWORD" > password.given.new && mv password.given.new password.given
        GIVEN=1
    fi
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

# FileBrowser greets the admin with a "new database was created" warning for as long as the run that made the
# database lasts. So the first run, once it answers, is stopped and started again at once: the warning is never seen.
answers() {
    case "$BIND" in 0.0.0.0|::) h=127.0.0.1 ;; *:*) h="[$BIND]" ;; *) h=$BIND ;; esac
    wget -q -O /dev/null "http://$h:$PORT/health" 2>/dev/null
}
prime() {
    [ -z "$USERCFG" ] || return 0   # a config of your own may keep its database elsewhere
    command -v wget > /dev/null 2>&1 || return 0
    i=0; while ! answers; do alive "$FB" && kill -0 "$MPC" 2>/dev/null && [ $i -lt 120 ] || return 0; sleep 1; i=$((i + 1)); done
    say "first run: starting FileBrowser again now that its database exists"
    kill "$FB" 2>/dev/null
    i=0; while alive "$FB" && [ $i -lt 25 ]; do sleep 0.2; i=$((i + 1)); done
    alive "$FB" && kill -9 "$FB" 2>/dev/null
    wait "$FB" 2>/dev/null
    start
}

say "MPC $MPC started; sources=$SOURCES index=$INDEX"
DELAY=5
NEWDB=0; [ -e filebrowser.sqlite ] || NEWDB=1
start
[ $NEWDB = 1 ] && prime
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
