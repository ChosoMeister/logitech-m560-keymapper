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
	Sources/Logging.swift Sources/EventMapper.swift Sources/Settings.swift Sources/PanelView.swift Sources/main.swift \
	-o "$MACOS_DIR/M560Mapper"

# TCC binds an Accessibility grant to the signing identity. With an ad-hoc
# signature that is the binary's cdhash, so every rebuild voided the grant. A
# self-signed certificate keeps one stable identity across rebuilds instead.
# Create it once (see README), or the build falls back to ad-hoc.
IDENTITY="M560Mapper Self-Signed"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
	codesign --force --deep --sign "$IDENTITY" "$APP"
else
	echo "warning: '$IDENTITY' not found, signing ad-hoc; the Accessibility grant will not survive rebuilds" >&2
	codesign --force --deep --sign - "$APP"
fi

echo "Built $APP"

# A login-item agent belongs in /Applications; the Accessibility grant follows
# the signing certificate, not the path, so moving it costs nothing.
if [ "${1:-}" = "--install" ]; then
	rm -rf "/Applications/$APP"
	cp -R "$APP" /Applications/
	echo "Installed /Applications/$APP"
fi
