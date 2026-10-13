#!/bin/bash
# User-visible, one-time setup. Runs the installer under the current account;
# sudo shows its own authorization prompt before modifying system files.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
echo 'ULiège VPN — Install VPN Support (UNOFFICIAL TEST BUILD)'
echo 'Read the security warning and confirm before approving administrator access.'
echo
/bin/bash "$HERE/install-helper.sh"
RESULT=$?
echo
if [[ $RESULT == 0 ]]; then echo 'Setup complete. Reopen ULiège VPN and select Connect.'
else echo "Setup failed (exit $RESULT). No VPN connection was started."; fi
read -r -p 'Press Return to close this window...' _ || true
exit "$RESULT"
