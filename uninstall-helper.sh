#!/bin/bash
set -euo pipefail
ROOT=/Library/PrivilegedHelperTools/be.uliege.vpn
[[ "$(uname -s)" == Darwin ]] || exit 1
[[ -d "$ROOT" && ! -L "$ROOT" && -x "$ROOT/helper" ]] || { echo 'No trusted helper installation found.' >&2; exit 1; }
echo 'This stops the VPN and removes its privileged helper and sudoers permission.'
echo 'Keychain entries and browser profiles will be preserved.'
# Any failure preserves the installation. Never delete a running helper.
sudo "$ROOT/helper" stop
status="$(sudo "$ROOT/helper" status)"
[[ "$status" == STOPPED ]] || { echo 'VPN stop could not be confirmed; removal refused.' >&2; exit 1; }
sudo /bin/rm -f /etc/sudoers.d/uliege-vpn
sudo /bin/rm -rf "$ROOT"
echo 'VPN support removed. Local credentials were not deleted.'
