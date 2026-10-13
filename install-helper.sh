#!/bin/bash
# Personal-use installer; run as the owning user, not as root.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT=/Library/PrivilegedHelperTools/be.uliege.vpn
RULE=/etc/sudoers.d/uliege-vpn

[[ "$(uname -s)" == "Darwin" ]] || { echo 'macOS required' >&2; exit 1; }
[[ "$(id -u)" != 0 ]] || { echo 'Run this normally, not with sudo' >&2; exit 1; }
USERNAME="$(id -un)"
[[ "$USERNAME" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo 'Unexpected account name' >&2; exit 1; }

# Prefer the binary bundled with this app. Do not fetch code while privileged.
# When installing from the source tree, fall back to a local build or PATH.
GOF5=''
for candidate in "$HERE/../VPNRuntime/gof5" \
                 "$HERE/build/ULiege VPN.app/Contents/Resources/VPNRuntime/gof5"; do
  if [[ -f "$candidate" && -x "$candidate" && ! -L "$candidate" ]]; then
    GOF5="$candidate"; break
  fi
done
if [[ -z "$GOF5" ]]; then
  GOF5="$(command -v gof5 || true)"
fi
[[ -n "$GOF5" && -f "$GOF5" && -x "$GOF5" && ! -L "$GOF5" ]] || {
  echo 'The gof5 executable was not found. Rebuild with GOF5_BINARY set.' >&2; exit 1;
}
if [[ -f "$HERE/helper.sh" ]]; then
  HELPER_SOURCE="$HERE/helper.sh"
else
  HELPER_SOURCE="$HERE/Helper/helper.sh"
fi
[[ -f "$HELPER_SOURCE" && ! -L "$HELPER_SOURCE" ]] || {
  echo 'The helper source is missing.' >&2; exit 1;
}

# Warn explicitly before installing a limited but passwordless root command.
echo 'This will install a root-owned copy of gof5 and a limited helper.'
echo 'Your macOS account will be able to call helper start/stop/status without sudo password.'
echo 'Touch ID in the app is a confirmation preference, NOT a sudo authorization requirement.'
read -r -p 'Type INSTALL to continue: ' CONFIRM
[[ "$CONFIRM" == 'INSTALL' ]] || exit 1

sudo /bin/mkdir -p "$ROOT/.gof5"
sudo /usr/sbin/chown -R root:wheel "$ROOT"
sudo /bin/chmod 0755 "$ROOT"
sudo /bin/chmod 0700 "$ROOT/.gof5"
sudo /usr/bin/install -o root -g wheel -m 0755 "$HELPER_SOURCE" "$ROOT/helper"
sudo /usr/bin/install -o root -g wheel -m 0755 "$GOF5" "$ROOT/gof5"
# Never read user-controlled routing files while running as root.
TMP="$(mktemp)"
RULETMP="$(mktemp)"
trap 'rm -f "$TMP" "$RULETMP"' EXIT
cat > "$TMP" <<'EOF'
routes:
  - 0.0.0.0/0
overrideDNS:
  - 139.165.214.214
EOF
sudo /usr/bin/install -o root -g wheel -m 0600 "$TMP" "$ROOT/.gof5/config.yaml"
cat > "$RULETMP" <<EOF
$USERNAME ALL=(root) NOPASSWD: $ROOT/helper start, $ROOT/helper stop, $ROOT/helper status
EOF
# Validate a root-owned 0440 candidate BEFORE making it active.
# A dot in the filename prevents sudoers from auto-including the staging file.
sudo /usr/bin/install -o root -g wheel -m 0440 "$RULETMP" "$RULE.tmp"
if ! sudo /usr/sbin/visudo -cf "$RULE.tmp"; then
  sudo /bin/rm -f "$RULE.tmp"
  echo 'sudoers validation failed; rules were not installed' >&2
  exit 1
fi
sudo /bin/mv -f "$RULE.tmp" "$RULE"
sudo /usr/sbin/visudo -cf "$RULE"
echo 'Helper installed.'
echo 'VPN support is installed. Return to the menu bar app and click Refresh status.'
