#!/bin/sh
set -eu

source_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
bundle="${1:-$source_dir/../out/MyKVM-BLE-Probe.app}"
mkdir -p "$bundle/Contents/MacOS"
cp "$source_dir/Info.plist" "$bundle/Contents/Info.plist"
xcrun swiftc -swift-version 5 -O -module-cache-path "$source_dir/../out/swift-module-cache" \
    -framework CoreBluetooth -framework IOBluetooth -framework AppKit \
    "$source_dir/main.swift" -o "$bundle/Contents/MacOS/MyKvmBleProbe"
codesign --force --sign - "$bundle"
printf '%s\n' "$bundle/Contents/MacOS/MyKvmBleProbe"
