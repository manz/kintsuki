#!/usr/bin/env bash
# Compile + run the standalone Swift tests under app/Tests/.
# These don't use XCTest so no secondary Xcode target is needed.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT=/tmp/kintsuki_swift_tests
mkdir -p "$OUT"

swiftc -parse-as-library -o "$OUT/rewind_buffer_test" \
    Sources/Kintsuki/RewindBuffer.swift \
    Tests/RewindRingTest.swift

"$OUT/rewind_buffer_test"
