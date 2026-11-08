#!/bin/sh
# Builds M560Mapper.app, a menu bar agent. Run ./build.sh then open the app.
set -eu
cd "$(dirname "$0")"

APP="M560Mapper.app"
MACOS_DIR="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"

swiftc -O \
	-framework AppKit -framework SwiftUI -framework CoreGraphics \
	-framework IOKit -framework CoreFoundation -framework ServiceManagement \
	Sources/EventMapper.swift Sources/Settings.swift Sources/PanelView.swift Sources/main.swift \
	-o "$MACOS_DIR/M560Mapper"

# A stable (ad-hoc) signature keeps the Accessibility grant and the login item
# registration attached to this bundle across rebuilds.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
