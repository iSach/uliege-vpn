#!/bin/bash
# Create an unsigned, review-only disk image on macOS. Does not publish anything.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="$(mktemp -d "${TMPDIR:-/tmp/}uliege-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ARCHIVE="$HERE/build/ULiegeVPN.app.zip"
[[ -f "$ARCHIVE" ]] || { echo 'Build the app first.' >&2; exit 1; }
/usr/bin/ditto -x -k "$ARCHIVE" "$STAGING"
APP="$STAGING/ULiege VPN.app"
ARCH="$(uname -m)"
[[ "$(uname -s)" == Darwin ]] || { echo 'DMG creation requires macOS.' >&2; exit 1; }
[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || { echo 'Unknown architecture' >&2; exit 1; }
[[ -x "$APP/Contents/MacOS/ULiegeVPN" ]] || { echo 'Build the app first.' >&2; exit 1; }
[[ -x "$APP/Contents/Resources/AuthRuntime/uliege-auth" ]] || { echo 'Missing bundled auth runner.' >&2; exit 1; }
[[ -x "$APP/Contents/Resources/VPNRuntime/gof5" ]] || { echo 'Missing bundled gof5. Cannot make standalone preview.' >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid version.' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$APP"
for binary in "$APP/Contents/MacOS/ULiegeVPN" "$APP/Contents/Resources/AuthRuntime/uliege-auth" "$APP/Contents/Resources/VPNRuntime/gof5"; do
    /usr/bin/lipo -verify_arch "$ARCH" "$binary"
done
/bin/ln -s /Applications "$STAGING/Applications"
/bin/cp "$HERE/INSTALLING.md" "$STAGING/READ ME FIRST.txt"
/bin/cp "$HERE/SECURITY.md" "$STAGING/SECURITY.md"
/bin/cp "$HERE/PRIVACY.md" "$STAGING/PRIVACY.md"
/bin/mkdir -p "$HERE/dist"
DMG="$HERE/dist/ULiegeVPN-${VERSION}-preview-${ARCH}-UNSIGNED.dmg"
/bin/rm -f "$DMG"
/usr/bin/hdiutil create -quiet -ov -format UDZO -fs HFS+ \
    -volname 'ULiege VPN Preview' -srcfolder "$STAGING" "$DMG"
/usr/bin/hdiutil verify -quiet "$DMG"
# A basename makes the checksum portable to another Mac or CI download folder.
(cd "$HERE/dist" && /usr/bin/shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Created $DMG"
echo 'This build is ad-hoc signed, NOT notarized. Review SECURITY.md before sharing.'
