#!/bin/bash
set -euo pipefail

APP_NAME="AppMixer"
BUILD_DIR=".build"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Building ${APP_NAME}..."
swift build -c release

echo "Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BUILD_DIR}/release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"
cp "Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"

echo "Signing app bundle..."
codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || true

echo ""
echo "Build complete: ${APP_BUNDLE}"
echo ""
echo "To install, copy to /Applications:"
echo "  cp -r ${APP_BUNDLE} /Applications/"
echo ""
echo "To run directly:"
echo "  open ${APP_BUNDLE}"
