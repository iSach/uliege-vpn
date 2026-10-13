#!/bin/bash
# Source install / experimental local development only.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
[[ "$(uname -s)" == Darwin ]] || { echo 'Requires macOS.'; exit 1; }
[[ "$(id -u)" != 0 ]] || { echo 'Do not run as root.'; exit 1; }
if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo 'Xcode Command Line Tools required. Install those and retry.'
    xcode-select --install || true
    exit 1
fi
if ! command -v brew >/dev/null 2>&1; then
    echo 'Homebrew is required for gof5. Install it from https://brew.sh and retry.'
    exit 1
fi
if [[ ! -d '/Applications/Google Chrome.app' && ! -d "$HOME/Applications/Google Chrome.app" ]]; then
    echo 'Google Chrome is required for university SSO: https://www.google.com/chrome/'
    exit 1
fi
if ! command -v gof5 >/dev/null 2>&1; then
    brew install gof5
fi
# Python 3.11+ is needed ONLY when building from source; no runtime dependency.
if ! python3 -c 'import sys; assert sys.version_info[:2] >= (3,11)' >/dev/null 2>&1; then
    echo 'The build needs Python 3.11+. Installing build-only Python 3.13.'
    brew install python@3.13
fi
./build.sh
echo 'WARNING: experimental privileged helper still uses NOPASSWD sudoers.'
echo 'Read SECURITY.md before agreeing to install it or sharing this build.'
./install-helper.sh
open "$HOME/Applications/ULiege VPN.app"
