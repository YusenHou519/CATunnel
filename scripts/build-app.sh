#!/bin/bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swift-common.sh"

swift build "${SWIFT_PACKAGE_ARGS[@]}" --configuration release --product CATunnel
BIN_DIRECTORY="$(swift build "${SWIFT_PACKAGE_ARGS[@]}" --configuration release --show-bin-path)"

APP_BUNDLE="${CATUNNEL_OUTPUT_DIR:-$PROJECT_ROOT/dist}/CATunnel.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
# Replace the executable inode atomically so an already-running version keeps its mapped image.
cp "$BIN_DIRECTORY/CATunnel" "$APP_BUNDLE/Contents/MacOS/CATunnel.next"
# Release binaries must not contain source-machine paths from debug symbols.
/usr/bin/strip -S "$APP_BUNDLE/Contents/MacOS/CATunnel.next"
mv -f "$APP_BUNDLE/Contents/MacOS/CATunnel.next" "$APP_BUNDLE/Contents/MacOS/CATunnel"
chmod 755 "$APP_BUNDLE/Contents/MacOS/CATunnel"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
mkdir -p "$APP_BUNDLE/Contents/Resources/FixedEntry"
for script in relay.py install.py; do
  cp "$PROJECT_ROOT/experimental/fixed_entry/$script" "$APP_BUNDLE/Contents/Resources/FixedEntry/$script"
  chmod 644 "$APP_BUNDLE/Contents/Resources/FixedEntry/$script"
done

swift "$PROJECT_ROOT/scripts/create-icon.swift" "$PROJECT_ROOT/.build/AppIcon.iconset"
/usr/bin/iconutil -c icns "$PROJECT_ROOT/.build/AppIcon.iconset" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
SIGNING_IDENTITY="${CATUNNEL_SIGNING_IDENTITY:--}"
SIGNING_OPTIONS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  SIGNING_OPTIONS+=(--timestamp=none)
else
  SIGNING_OPTIONS+=(--options runtime --timestamp)
fi
/usr/bin/codesign "${SIGNING_OPTIONS[@]}" "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
printf '%s\n' "$APP_BUNDLE"
