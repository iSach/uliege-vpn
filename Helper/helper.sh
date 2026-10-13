#!/bin/bash
# Privileged, root-owned fixed-function helper. NEVER install a user-writable
# copy in sudoers. No user-provided executable paths or shell evaluation.
set -euo pipefail
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
ROOT=/Library/PrivilegedHelperTools/be.uliege.vpn
PIDFILE="$ROOT/gof5.pid"
LOGFILE="$ROOT/gof5.log"
BINARY="$ROOT/gof5"

if [[ "$(id -u)" != 0 ]]; then
    echo 'Helper must run as root' >&2
    exit 77
fi
if [[ $# != 1 ]]; then
    echo 'Usage: helper start|stop|status' >&2
    exit 64
fi

owned_process() {
    local pid
    [[ -r "$PIDFILE" ]] || return 1
    IFS= read -r pid < "$PIDFILE" || true
    [[ "${pid:-}" =~ ^[0-9]+$ ]] || return 1
    # Protect against PID reuse. Inspect silently: process args include a token.
    local command_line
    command_line="$(/bin/ps -p "$pid" -o command= 2>/dev/null)" || return 1
    [[ "$command_line" == "$BINARY "* ]] || return 1
    /bin/kill -0 "$pid" 2>/dev/null || return 1
    return 0
}

case "$1" in
    status)
        if owned_process; then echo RUNNING; else echo STOPPED; fi
        ;;
    start)
        # Read stdin BEFORE checking whether a tunnel already exists. This
        # prevents the GUI's stdin writer from racing an early helper exit.
        session=''
        IFS= read -r session || true
        if [[ ${#session} -lt 10 || ${#session} -gt 4096 || ! "$session" =~ ^[[:graph:]]+$ ]]; then
            echo 'Invalid session token' >&2
            exit 65
        fi
        if owned_process; then echo RUNNING; exit 0; fi
        [[ -x "$BINARY" ]] || { echo 'gof5 not installed in privileged directory' >&2; exit 69; }
        export HOME="$ROOT"
        cd "$ROOT"
        /usr/bin/touch "$LOGFILE"
        /bin/chmod 0600 "$LOGFILE"
        # gof5 needs to keep running after the helper exits. Session will be
        # present in gof5 argv (upstream CLI limitation); avoid logging it.
        /usr/bin/nohup "$BINARY" --server vpn-2fa.uliege.be --session "$session" \
            >> "$LOGFILE" 2>&1 < /dev/null &
        child=$!
        printf '%s\n' "$child" > "$PIDFILE"
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
        /bin/rm -f "$PIDFILE"
        echo STOPPED
        ;;
    *) echo 'Unsupported command' >&2; exit 64 ;;
esac
