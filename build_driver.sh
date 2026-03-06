#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER_DIR="$SCRIPT_DIR/Driver"
BUILD_DIR="$SCRIPT_DIR/build"
BUNDLE_DIR="$BUILD_DIR/AppMixerDriver.driver"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

echo "Building AppMixerDriver..."

rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR"

# Compile the driver
clang -dynamiclib \
    -o "$MACOS_DIR/AppMixerDriver" \
    "$DRIVER_DIR/AppMixerDriver.c" \
    -framework CoreAudio \
    -framework CoreFoundation \
    -std=c11 \
    -O2 \
    -Wall -Wextra -Wno-unused-parameter

# Copy Info.plist
cp "$DRIVER_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

echo "Built: $BUNDLE_DIR"
echo ""
echo "To install, run:"
echo "  sudo bash install_driver.sh"
