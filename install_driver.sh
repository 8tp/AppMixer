#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$SCRIPT_DIR/build/AppMixerDriver.driver"
INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"
INSTALLED="$INSTALL_DIR/AppMixerDriver.driver"

if [ ! -d "$BUNDLE" ]; then
    echo "Error: Driver not built. Run build_driver.sh first."
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "Error: Must run as root (sudo)."
    exit 1
fi

echo "Installing AppMixerDriver..."

# Remove old version if present
if [ -d "$INSTALLED" ]; then
    echo "Removing old driver..."
    rm -rf "$INSTALLED"
fi

# Copy new driver
cp -R "$BUNDLE" "$INSTALLED"
chown -R root:wheel "$INSTALLED"

echo "Restarting coreaudiod..."
sudo killall coreaudiod

echo "Done. AppMixer device should now appear in Audio MIDI Setup."
