#!/bin/bash
# Run as the owning user; privileged changes require explicit confirmation.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS required' >&2; exit 1; }
[[ "$(id -u)" != 0 ]] || { echo 'Run normally, not with sudo.' >&2; exit 1; }
USERNAME="$(id -un)"
[[ "$USERNAME" =~ ^[A-Za-z0-9_.-]+$ ]] || exit 1
if [[ -f "$HERE/helper.sh" ]]; then
    HELPER_SOURCE="$HERE/helper.sh"
    ROOT_INSTALLER="$HERE/install-root.sh"
    GOF5="$HERE/../VPNRuntime/gof5"
else
    HELPER_SOURCE="$HERE/Helper/helper.sh"
    ROOT_INSTALLER="$HERE/Helper/install-root.sh"
    GOF5="$HERE/build/gof5-hardened"
fi
for source in "$HELPER_SOURCE" "$ROOT_INSTALLER" "$GOF5"; do
    [[ -f "$source" && ! -L "$source" ]] || { echo 'Build the app first; hardened VPN support is missing.' >&2; exit 1; }
done
# Require the version supporting --config-dir and --session-stdin.
version="$(/usr/bin/env -i PATH=/usr/bin:/bin "$GOF5" --version)"
[[ "$version" == 'gof5 0.1.5-uliege.1 '* ]] || { echo 'Hardened gof5 required.' >&2; exit 1; }
echo 'This installs root-owned VPN support and limited passwordless start/stop/status permission.'
echo 'Any process in your account can use that permission. Touch ID is app confirmation only.'
echo 'A running VPN will not be stopped or replaced. Disconnect it yourself before updating support.'
read -r -p 'Type INSTALL to continue: ' CONFIRM
[[ "$CONFIRM" == INSTALL ]] || exit 1
sudo /bin/bash -p "$ROOT_INSTALLER" "$HELPER_SOURCE" "$GOF5" "$USERNAME"
echo 'Return to the menu bar app and select Refresh status.'
