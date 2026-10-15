#!/bin/bash -p
# Fixed-function root helper. Paths, server and options are never client input.
set -euo pipefail
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C
ROOT=/Library/PrivilegedHelperTools/be.uliege.vpn
PIDFILE="$ROOT/gof5.pid"
STAMPFILE="$ROOT/gof5.started"
LOGFILE="$ROOT/gof5.log"
BINARY="$ROOT/gof5"
LOCK="$ROOT/operation.lock"

fail() { echo "$1" >&2; exit 78; }
[[ "$(/usr/bin/id -u)" == 0 ]] || { echo 'Helper must run as root' >&2; exit 77; }
[[ $# == 1 ]] || { echo 'Usage: helper start|stop|status' >&2; exit 64; }
case "$1" in start|stop|status) ;; *) echo 'Unsupported command' >&2; exit 64 ;; esac

# Refuse symlinks, writable ancestors, hard-linked state, and unexpected owners.
# Never repair an untrusted tree by recursively chowning it.
trusted() {
    local path="$1" metadata uid mode links
    [[ ! -L "$path" && -e "$path" ]] || return 1
    metadata="$(/usr/bin/stat -f '%u %Lp %l' "$path")" || return 1
    read -r uid mode links <<< "$metadata"
    [[ "$uid" == 0 && "$mode" =~ ^[0-7]+$ ]] || return 1
    (( (8#$mode & 8#022) == 0 )) || return 1
    [[ ! -f "$path" || "$links" == 1 ]]
}
for directory in /Library /Library/PrivilegedHelperTools "$ROOT" "$ROOT/.gof5"; do
    [[ -d "$directory" ]] && trusted "$directory" || fail 'Unsafe VPN support directory; reinstall from a trusted build.'
done
for file in "$BINARY" "$ROOT/helper" "$ROOT/.gof5/config.yaml"; do
    [[ -f "$file" ]] && trusted "$file" || fail 'Unsafe VPN support file; reinstall from a trusted build.'
done
for file in "$PIDFILE" "$STAMPFILE" "$LOGFILE" "$ROOT/.gof5/cookies.yaml"; do
    if [[ -e "$file" || -L "$file" ]]; then
        [[ -f "$file" ]] && trusted "$file" || fail 'Unsafe VPN state file.'
    fi
done

owned_process() {
    local pid owner executable expected actual
    [[ -r "$PIDFILE" ]] || return 1
    IFS= read -r pid < "$PIDFILE" || true
    [[ "${pid:-}" =~ ^[1-9][0-9]*$ ]] && (( pid > 1 )) || return 1
    # Never inspect argv: legacy versions may contain the session token.
    owner="$(/bin/ps -p "$pid" -o uid= 2>/dev/null)" || return 1
    [[ "${owner// /}" == 0 ]] || return 1
    executable="$(/bin/ps -ww -p "$pid" -o comm= 2>/dev/null)" || return 1
    [[ "$executable" == "$BINARY" ]] || return 1
    if [[ -r "$STAMPFILE" ]]; then
        IFS= read -r expected < "$STAMPFILE" || return 1
        actual="$(/bin/ps -p "$pid" -o lstart= 2>/dev/null)" || return 1
        [[ "$actual" == "$expected" ]] || return 1
    fi
    /bin/kill -0 "$pid" 2>/dev/null
}

# status is read-only; transient files during a serialized start can be absent.
if [[ "$1" == status ]]; then
    if owned_process; then echo RUNNING; else echo STOPPED; fi
    exit 0
fi

# Read and bound stdin before any early exit, preventing the GUI pipe race.
if [[ "$1" == start ]]; then
    session=''
    IFS= read -r -n 4097 session || true
    [[ ${#session} -ge 10 && ${#session} -le 4096 && "$session" =~ ^[[:graph:]]+$ ]] || {
        echo 'Invalid session token' >&2; exit 65;
    }
fi
/bin/mkdir -m 0700 "$LOCK" 2>/dev/null || { echo 'VPN support is busy. Retry shortly.' >&2; exit 75; }
trap '/bin/rmdir "$LOCK" 2>/dev/null || true' EXIT

case "$1" in
    start)
        if owned_process; then echo RUNNING; exit 0; fi
        # Require our patched, versioned binary: never silently fall back to a
        # gof5 build which ignores the explicit directory or leaks argv secrets.
        version="$(/usr/bin/env -i PATH="$PATH" "$BINARY" --version)"
        [[ "$version" == 'gof5 0.1.5-uliege.1 '* ]] || fail 'Hardened gof5 runtime required.'
        /bin/rm -f "$PIDFILE" "$STAMPFILE" "$ROOT/.gof5/cookies.yaml"
        : > "$LOGFILE"
        /bin/chmod 0600 "$LOGFILE"
        # Explicit pipe redirection keeps stdin available under nohup.
        # env -i removes SUDO_UID, proxy, Go and dynamic-loader overrides.
        /usr/bin/nohup /usr/bin/env -i PATH="$PATH" HOME="$ROOT" LC_ALL=C \
            "$BINARY" --server vpn-2fa.uliege.be \
            --config-dir "$ROOT/.gof5" --session-stdin \
            < <(printf '%s\n' "$session") >> "$LOGFILE" 2>&1 &
        child=$!
        printf '%s\n' "$child" > "$PIDFILE"
        /bin/ps -p "$child" -o lstart= > "$STAMPFILE" || true
        unset session
        echo STARTED
        ;;
    stop)
        if owned_process; then
            IFS= read -r pid < "$PIDFILE" || true
            /bin/kill -INT "$pid" 2>/dev/null || true
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                if ! owned_process; then break; fi
                /bin/sleep 1
            done
            if owned_process; then
                /bin/kill -TERM "$pid" 2>/dev/null || true
                /bin/sleep 2
            fi
            if owned_process; then
                echo 'gof5 did not exit; refusing to force-kill tunnel' >&2
                exit 1
            fi
        fi
        /bin/rm -f "$PIDFILE" "$STAMPFILE" "$ROOT/.gof5/cookies.yaml"
        echo STOPPED
        ;;
esac
