#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$HERE/build/tests"
xcrun swiftc -swift-version 5 -parse-as-library "$HERE/Sources/TunnelHealth.swift" \
    "$HERE/tests/TunnelHealthTests.swift" -o "$HERE/build/tests/tunnel-health-tests"
"$HERE/build/tests/tunnel-health-tests"
xcrun swiftc -swift-version 5 -parse-as-library "$HERE/Sources/TunnelHealth.swift" \
    "$HERE/Sources/SessionReuse.swift" "$HERE/Sources/SessionValidation.swift" \
    "$HERE/tests/SessionReuseTests.swift" -o "$HERE/build/tests/session-reuse-tests"
"$HERE/build/tests/session-reuse-tests"
xcrun swiftc -parse-as-library -swift-version 5 -warnings-as-errors \
    -target "$(uname -m)-apple-macosx13.0" -typecheck "$HERE"/Sources/*.swift
