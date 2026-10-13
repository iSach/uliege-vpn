#!/bin/bash
# Create an unsigned, review-only disk image on macOS. Does not publish anything.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HERE/build/ULiege VPN.app"
ARCH="$(uname -m)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$(uname -s)" == Darwin ]] || { echo 'DMG creation requires macOS.' >&2; exit 1; }
[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || { echo 'Unknown architecture' >&2; exit 1; }
[[ -x "$APP/Contents/MacOS/ULiegeVPN" ]] || { echo 'Build the app first.' >&2; exit 1; }
[[ -x "$APP/Contents/Resources/AuthRuntime/uliege-auth" ]] || { echo 'Missing bundled auth runner.' >&2; exit 1; }
[[ -x "$APP/Contents/Resources/VPNRuntime/gof5" ]] || { echo 'Missing bundled gof5. Cannot make standalone preview.' >&2; exit 1; }
STAGING="$(mktemp -d "${TMPDIR:-/tmp/}uliege-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto "$APP" "$STAGING/ULiege VPN.app"
/bin/ln -s /Applications "$STAGING/Applications"
/bin/cp "$HERE/INSTALLING.md" "$STAGING/READ ME FIRST.txt"
/bin/mkdir -p "$HERE/dist"
DMG="$HERE/dist/ULiegeVPN-${VERSION}-preview-${ARCH}-UNSIGNED.dmg"
/bin/rm -f "$DMG"
/usr/bin/hdiutil create -quiet -ov -format UDZO -fs HFS+ \
    -volname 'ULiege VPN Preview' -srcfolder "$STAGING" "$DMG"
/usr/bin/shasum -a 256 "$DMG" > "$DMG.sha256"
echo "Created $DMG"
echo 'This build is ad-hoc signed, NOT notarized. Review SECURITY.md before sharing.'
