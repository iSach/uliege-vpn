#!/bin/bash
set -euo pipefail
ROOT=/Library/PrivilegedHelperTools/be.uliege.vpn
if [[ "$(uname -s)" != 'Darwin' ]]; then exit 1; fi
sudo -n "$ROOT/helper" stop || true
echo 'Removing privileged helper and its sudoers permission.'
sudo /bin/rm -f /etc/sudoers.d/uliege-vpn
sudo /bin/rm -rf "$ROOT"
echo 'Done. The user-side authentication script and its Keychain entries were not deleted.'
