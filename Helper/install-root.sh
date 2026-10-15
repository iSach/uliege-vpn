#!/bin/bash
# Invoked only by the interactive installer after explicit admin approval.
set -euo pipefail
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
ROOT=/Library/PrivilegedHelperTools/be.uliege.vpn
RULE=/etc/sudoers.d/uliege-vpn
[[ "$(id -u)" == 0 && $# == 3 ]] || exit 64
HELPER_SOURCE="$1"
GOF5="$2"
USERNAME="$3"
[[ "$USERNAME" =~ ^[A-Za-z0-9_.-]+$ ]] && /usr/bin/id "$USERNAME" >/dev/null || exit 64
for source in "$HELPER_SOURCE" "$GOF5"; do
    [[ -f "$source" && ! -L "$source" ]] || { echo 'Invalid installer source.' >&2; exit 78; }
done
trusted() {
    local path="$1" uid mode links
    [[ -e "$path" && ! -L "$path" ]] || return 1
    read -r uid mode links <<< "$(/usr/bin/stat -f '%u %Lp %l' "$path")"
    [[ "$uid" == 0 && "$mode" =~ ^[0-7]+$ ]] || return 1
    (( (8#$mode & 8#022) == 0 )) || return 1
    [[ ! -f "$path" || "$links" == 1 ]]
}
for directory in /Library /private /private/etc; do
    [[ -d "$directory" ]] && trusted "$directory" || { echo 'Unsafe installation directory.' >&2; exit 78; }
done
for directory in /Library/PrivilegedHelperTools /etc/sudoers.d; do
    if [[ -e "$directory" || -L "$directory" ]]; then
        [[ -d "$directory" ]] && trusted "$directory" || { echo 'Unsafe support directory.' >&2; exit 78; }
    else
        /usr/bin/install -d -o root -g wheel -m 0755 "$directory"
    fi
done
if [[ -e "$ROOT" || -L "$ROOT" ]]; then
    [[ -d "$ROOT" ]] && trusted "$ROOT" || { echo 'Unsafe existing helper directory.' >&2; exit 78; }
else
    /usr/bin/install -d -o root -g wheel -m 0755 "$ROOT"
fi
if [[ -e "$RULE" || -L "$RULE" ]]; then
    [[ -f "$RULE" ]] && trusted "$RULE" || { echo 'Unsafe existing sudoers rule.' >&2; exit 78; }
fi
for file in helper gof5 gof5.pid gof5.started gof5.log .gof5/config.yaml .gof5/cookies.yaml; do
    if [[ -e "$ROOT/$file" || -L "$ROOT/$file" ]]; then
        [[ -f "$ROOT/$file" ]] && trusted "$ROOT/$file" || { echo 'Unsafe existing helper file.' >&2; exit 78; }
    fi
done
if [[ -e "$ROOT/.gof5" || -L "$ROOT/.gof5" ]]; then
    [[ -d "$ROOT/.gof5" ]] && trusted "$ROOT/.gof5" || { echo 'Unsafe configuration directory.' >&2; exit 78; }
fi
/bin/mkdir -m 0700 "$ROOT/operation.lock" 2>/dev/null || { echo 'Helper is busy; retry after it finishes.' >&2; exit 75; }
STAGE=''
RULE_CANDIDATE=''
cleanup() {
    [[ -z "$STAGE" ]] || /bin/rm -rf "$STAGE"
    [[ -z "$RULE_CANDIDATE" ]] || /bin/rm -f "$RULE_CANDIDATE"
    /bin/rmdir "$ROOT/operation.lock" 2>/dev/null || true
}
trap cleanup EXIT
STAGE="$(/usr/bin/mktemp -d "$ROOT/.install.XXXXXX")"
# Never stop or overwrite a running installation. The old helper's status is
# the sole existing-state check; failure means refuse the update.
if [[ -e "$ROOT/helper" ]]; then
    [[ -x "$ROOT/helper" ]] || { echo 'Existing helper is not executable; state is unknown.' >&2; exit 75; }
    status="$(/usr/bin/env -i PATH="$PATH" "$ROOT/helper" status)" || {
        echo 'Cannot verify existing VPN state; installation refused.' >&2; exit 75;
    }
    [[ "$status" == STOPPED ]] || { echo 'Disconnect the VPN yourself before updating support.' >&2; exit 75; }
elif [[ -e "$ROOT/gof5.pid" ]]; then
    echo 'Existing VPN state has no usable helper; installation refused.' >&2
    exit 75
fi
/usr/bin/install -o root -g wheel -m 0755 "$HELPER_SOURCE" "$STAGE/helper"
/usr/bin/install -o root -g wheel -m 0755 "$GOF5" "$STAGE/gof5"
version="$(/usr/bin/env -i PATH="$PATH" "$STAGE/gof5" --version)"
[[ "$version" == 'gof5 0.1.5-uliege.1 '* ]] || { echo 'Hardened gof5 required.' >&2; exit 78; }
cat > "$STAGE/config.yaml" <<'CONFIG'
# Keep server-provided routing. Do not force a public internet default route.
driver: wireguard
insecureTLS: false
CONFIG
printf '%s ALL=(root) NOPASSWD: NOSETENV: %s/helper start, %s/helper stop, %s/helper status\n' \
    "$USERNAME" "$ROOT" "$ROOT" "$ROOT" > "$STAGE/sudoers"
/bin/chmod 0440 "$STAGE/sudoers"
# A dotted candidate is ignored by sudoers until its atomic activation.
RULE_CANDIDATE="$(/usr/bin/mktemp /etc/sudoers.d/.uliege-vpn.XXXXXX)"
/usr/bin/install -o root -g wheel -m 0440 "$STAGE/sudoers" "$RULE_CANDIDATE"
/usr/sbin/visudo -cf "$RULE_CANDIDATE"
# Stage every file before activation. All destinations are in trusted dirs.
/usr/bin/install -d -o root -g wheel -m 0700 "$ROOT/.gof5"
/usr/bin/install -o root -g wheel -m 0600 "$STAGE/config.yaml" "$ROOT/.gof5/config.yaml"
/bin/mv -f "$STAGE/gof5" "$ROOT/gof5"
/bin/mv -f "$STAGE/helper" "$ROOT/helper"
/bin/mv -f "$RULE_CANDIDATE" "$RULE"
RULE_CANDIDATE=''
echo 'VPN support installed. No connection was started.'
