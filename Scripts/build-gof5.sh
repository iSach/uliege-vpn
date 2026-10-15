#!/bin/bash
# Build as the current user only. No network downloads occur as root.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/ThirdParty/gof5-source.env"
[[ "$(id -u)" != 0 ]] || { echo 'Do not build as root.' >&2; exit 1; }
command -v go >/dev/null || { echo 'Go is required to build the hardened VPN runtime.' >&2; exit 1; }
SOURCE="$HERE/build/gof5-source"
mkdir -p "$HERE/build"
if [[ ! -d "$SOURCE/.git" ]]; then
    git clone --no-checkout https://github.com/kayrus/gof5.git "$SOURCE"
fi
# This is a disposable build-only checkout, never the user's project.
git -C "$SOURCE" checkout --detach --force "$GOF5_COMMIT"
git -C "$SOURCE" clean -fd
git -C "$SOURCE" apply --check "$HERE/ThirdParty/gof5-hardening.patch"
git -C "$SOURCE" apply "$HERE/ThirdParty/gof5-hardening.patch"
(
    cd "$SOURCE"
    go mod download
    go mod verify
    go test ./cmd/gof5 ./pkg/config
    go build -trimpath -ldflags "-s -w -X main.Version=$GOF5_VERSION" -o "$HERE/build/gof5-hardened" ./cmd/gof5
)
"$HERE/build/gof5-hardened" --version
