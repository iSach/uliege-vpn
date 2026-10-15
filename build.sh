#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD_APP="$HERE/build/ULiege VPN.app"
# File-provider workspaces can restore FinderInfo while codesign is running.
# Assemble/sign on private temporary storage; preserve a clean ZIP for packaging.
STAGING="$(mktemp -d "${TMPDIR:-/tmp/}uliege-build.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/ULiege VPN.app"
RES="$APP/Contents/Resources"
INSTALL_APP="${INSTALL_APP:-0}"  # Set 0 to build without touching an installed copy.

if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Build on macOS with Xcode Command Line Tools.' >&2
    exit 1
fi
ARCH="$(uname -m)"
[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || { echo "Unsupported architecture: $ARCH" >&2; exit 1; }

# Find a supported BUILD-TIME Python. Users of the finished app need none.
PYTHON="${PYTHON:-}"
if [[ -z "$PYTHON" ]]; then
    for candidate in python3 "$HERE"/build/python-runtime/*/bin/python3.13 /opt/homebrew/bin/python3.13 /usr/local/bin/python3.13 \
                     /opt/homebrew/bin/python3.12 /usr/local/bin/python3.12 \
                     /opt/homebrew/bin/python3.11 /usr/local/bin/python3.11 \
                     python3; do
        if command -v "$candidate" >/dev/null 2>&1 &&
           "$candidate" -c 'import sys; assert (3,11) <= sys.version_info[:2] < (3,14)' >/dev/null 2>&1; then
            PYTHON="$candidate"
            break
        fi
    done
fi
if [[ -z "$PYTHON" ]] || ! "$PYTHON" -c 'import sys; assert (3,11) <= sys.version_info[:2] < (3,14)' >/dev/null 2>&1; then
    echo 'Build requires Python 3.11–3.13. Install via brew install python@3.13 or set PYTHON=/path/to/python3.' >&2
    exit 1
fi

# Bundle CPython, Playwright's driver, and the macOS Keychain backend using
# PyInstaller. The finished app NEVER invokes uv, python, or pip at runtime.
VENV="$HERE/build/.build-venv"
if [[ -x "$VENV/bin/python" ]] &&
   [[ "$("$VENV/bin/python" -c 'import sys; print(sys.base_prefix)')" != "$("$PYTHON" -c 'import sys; print(sys.base_prefix)')" ]]; then
    /bin/rm -rf "$VENV"  # Only this checkout's disposable build environment.
fi
if [[ ! -x "$VENV/bin/python" ]]; then
    "$PYTHON" -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install --disable-pip-version-check -r "$HERE/build-requirements.txt"
"$VENV/bin/python" -m PyInstaller \
    --noconfirm --clean --onedir --name uliege-auth \
    --paths "$HERE/Scripts" \
    --collect-all playwright \
    --collect-submodules keyring.backends \
    --hidden-import keyring.backends.macOS \
    --distpath "$HERE/build/auth-dist" \
    --workpath "$HERE/build/auth-work" \
    --specpath "$HERE/build/auth-spec" \
    "$HERE/Scripts/auth_runner.py"

mkdir -p "$APP/Contents/MacOS" "$RES"
/bin/rm -rf "$RES/AuthRuntime"
/usr/bin/ditto "$HERE/build/auth-dist/uliege-auth" "$RES/AuthRuntime"
if [[ ! -x "$RES/AuthRuntime/uliege-auth" ]]; then
    echo 'Failed to package authentication runtime.' >&2
    exit 1
fi

/bin/cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
/bin/cp "$HERE/Resources/ULiegeColor.png" "$RES/ULiegeColor.png"
/bin/cp "$HERE/Resources/ULiegeTemplate.png" "$RES/ULiegeTemplate.png"

# Build the pinned, patched runtime. A stock gof5 binary is not safe here.
"$HERE/Scripts/build-gof5.sh"
GOF5_BINARY="$HERE/build/gof5-hardened"
/bin/mkdir -p "$RES/VPNRuntime" "$RES/Support"
/usr/bin/install -m 0755 "$GOF5_BINARY" "$RES/VPNRuntime/gof5"
/bin/cp "$HERE/ThirdParty/GOF5-APACHE-2.0.txt" "$RES/VPNRuntime/GOF5-APACHE-2.0.txt"
for document in SECURITY.md PRIVACY.md BRANDING.md; do
    /bin/cp "$HERE/$document" "$RES/$document"
done
/usr/bin/shasum -a 256 "$GOF5_BINARY" | /usr/bin/awk '{print $1}' > "$RES/VPNRuntime/gof5.sha256"
for script in install-helper.sh uninstall-helper.sh; do
    /usr/bin/install -m 0755 "$HERE/$script" "$RES/Support/$script"
done
/usr/bin/install -m 0755 "$HERE/Helper/helper.sh" "$RES/Support/helper.sh"
/usr/bin/install -m 0755 "$HERE/Helper/install-root.sh" "$RES/Support/install-root.sh"
/usr/bin/install -m 0755 "$HERE/Packaging/Install VPN Support.command" \
    "$RES/Support/Install VPN Support.command"

ICONSET="$HERE/build/ULiegeVPN.iconset"
/bin/mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    /usr/bin/sips -s format png -z "$SIZE" "$SIZE" "$HERE/Resources/ULiegeColor.png" \
        --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    BIG=$((SIZE*2))
    /usr/bin/sips -s format png -z "$BIG" "$BIG" "$HERE/Resources/ULiegeColor.png" \
        --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICONSET" -o "$RES/ULiegeVPN.icns"

xcrun swiftc -parse-as-library -swift-version 5 -O \
    -target "${ARCH}-apple-macosx13.0" \
    -framework AppKit -framework SwiftUI \
    -framework LocalAuthentication -framework Security -framework CryptoKit \
    "$HERE/Sources/ULiegeVPNApp.swift" "$HERE/Sources/AutomaticSetup.swift" "$HERE/Sources/TunnelHealth.swift" \
    -o "$APP/Contents/MacOS/ULiegeVPN"
MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
"$VENV/bin/python" "$HERE/Scripts/check-macos-runtime.py" "$APP" --maximum "$MINIMUM_MACOS" --output "$RES/build-info.json"
# Development-only ad-hoc signing. Public distribution requires Developer ID
# signing of ALL nested binaries, plus notarization, and helper hardening.
# Finder may add these two metadata attributes while inspecting a local bundle.
# Remove only signing-incompatible metadata on our build output, not quarantine.
for attribute in com.apple.FinderInfo com.apple.ResourceFork; do
    /usr/bin/xattr -r -d "$attribute" "$APP" 2>/dev/null || true
done
/usr/bin/codesign --force --deep --sign - "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

# Smoke-test the frozen executable before replacing an existing installation.
# These help commands do not contact Microsoft or ask for credentials.
"$RES/AuthRuntime/uliege-auth" --help >/dev/null
"$RES/AuthRuntime/uliege-auth" --mode automatic --help >/dev/null
echo "Bundled authentication executable passed startup checks"
/usr/bin/ditto -c -k --keepParent --norsrc "$APP" "$HERE/build/ULiegeVPN.app.zip"
/bin/rm -rf "$BUILD_APP"
/usr/bin/ditto --norsrc "$APP" "$BUILD_APP"
echo "Built $BUILD_APP"
echo "Clean signed archive: $HERE/build/ULiegeVPN.app.zip"
if [[ "$INSTALL_APP" == 1 ]]; then
    /bin/mkdir -p "$HOME/Applications"
    /usr/bin/ditto "$APP" "$HOME/Applications/ULiege VPN.app"
    echo "Installed $HOME/Applications/ULiege VPN.app"
else
    echo 'INSTALL_APP=0: existing installation was not modified.'
fi
