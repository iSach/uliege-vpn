#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/build/ULiege VPN.app"
RES="$APP/Contents/Resources"
INSTALL_APP="${INSTALL_APP:-1}"  # Set 0 to build without touching an installed copy.

if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Build on macOS with Xcode Command Line Tools.' >&2
    exit 1
fi
ARCH="$(uname -m)"
[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || { echo "Unsupported architecture: $ARCH" >&2; exit 1; }

# Find a supported BUILD-TIME Python. Users of the finished app need none.
PYTHON="${PYTHON:-}"
if [[ -z "$PYTHON" ]]; then
    for candidate in /opt/homebrew/bin/python3.13 /usr/local/bin/python3.13 \
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

# Public-preview packaging: include a specific gof5 binary and one-time support
# installer so the end user doesn't have to install Homebrew. For source builds,
# pass GOF5_BINARY=/path/to/gof5 if it is not on PATH.
GOF5_BINARY="${GOF5_BINARY:-$(command -v gof5 || true)}"
if [[ ! -f "$GOF5_BINARY" || ! -x "$GOF5_BINARY" ]]; then
    echo 'Build requires gof5 (brew install gof5, or set GOF5_BINARY).' >&2
    exit 1
fi
/bin/mkdir -p "$RES/VPNRuntime" "$RES/Support"
/usr/bin/install -m 0755 "$GOF5_BINARY" "$RES/VPNRuntime/gof5"
/bin/cp "$HERE/ThirdParty/GOF5-APACHE-2.0.txt" "$RES/VPNRuntime/GOF5-APACHE-2.0.txt"
for script in install-helper.sh uninstall-helper.sh; do
    /usr/bin/install -m 0755 "$HERE/$script" "$RES/Support/$script"
done
/usr/bin/install -m 0755 "$HERE/Helper/helper.sh" "$RES/Support/helper.sh"
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
    "$HERE/Sources/ULiegeVPNApp.swift" "$HERE/Sources/AutomaticSetup.swift" \
    -o "$APP/Contents/MacOS/ULiegeVPN"
# Development-only ad-hoc signing. Public distribution requires Developer ID
# signing of ALL nested binaries, plus notarization, and helper hardening.
/usr/bin/codesign --force --deep --sign - "$APP"

# Smoke-test the frozen executable before replacing an existing installation.
# These help commands do not contact Microsoft or ask for credentials.
"$RES/AuthRuntime/uliege-auth" --help >/dev/null
"$RES/AuthRuntime/uliege-auth" --mode automatic --help >/dev/null
echo "Bundled authentication executable passed startup checks"
echo "Built $APP"
if [[ "$INSTALL_APP" == 1 ]]; then
    /bin/mkdir -p "$HOME/Applications"
    /usr/bin/ditto "$APP" "$HOME/Applications/ULiege VPN.app"
    echo "Installed $HOME/Applications/ULiege VPN.app"
else
    echo 'INSTALL_APP=0: existing installation was not modified.'
fi
