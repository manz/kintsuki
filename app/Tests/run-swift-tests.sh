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

swiftc -parse-as-library -o "$OUT/input_mapper_test" \
    Sources/Kintsuki/InputMapper.swift \
    Tests/InputMapperTest.swift

"$OUT/input_mapper_test"

swiftc -parse-as-library -o "$OUT/tile_sheet_test" \
    Sources/Kintsuki/TileDecoder.swift \
    Sources/Kintsuki/TileSheet.swift \
    Tests/TileSheetTest.swift

"$OUT/tile_sheet_test"

swiftc -parse-as-library -o "$OUT/vram_map_test" \
    Sources/Kintsuki/VRAMMap.swift \
    Tests/VRAMMapTest.swift

"$OUT/vram_map_test"
