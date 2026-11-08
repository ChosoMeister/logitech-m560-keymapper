#!/bin/sh
# Builds M560Mapper.app, a menu bar agent.
#
#   ./build.sh              build in place
#   ./build.sh --install    build and copy to /Applications
#   ./build.sh --release    build for distribution and zip it
#
set -eu
cd "$(dirname "$0")"

MODE="${1:-}"

APP="M560Mapper.app"
MACOS_DIR="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The icon is generated rather than stored as a binary, so it stays editable.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
swiftc -O Tools/make-icon.swift -o "$ICONSET/../make-icon"
"$ICONSET/../make-icon" "$ICONSET/../icon.png" >/dev/null
for pixels in 16 32 64 128 256 512 1024; do
	sips -z "$pixels" "$pixels" "$ICONSET/../icon.png" --out "$ICONSET/icon_${pixels}x${pixels}.png" >/dev/null
done
# Retina variants are the same image at double the nominal size.
for pixels in 16 32 128 256 512; do
	cp "$ICONSET/icon_$((pixels * 2))x$((pixels * 2)).png" "$ICONSET/icon_${pixels}x${pixels}@2x.png"
done
rm -f "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

swiftc -O \
	-framework AppKit -framework SwiftUI -framework CoreGraphics \
	-framework IOKit -framework CoreFoundation -framework ServiceManagement \
	Sources/Logging.swift Sources/Devices.swift Sources/HIDPlusPlus.swift Sources/EventMapper.swift Sources/Settings.swift Sources/PanelView.swift Sources/main.swift \
	-o "$MACOS_DIR/M560Mapper"

# TCC binds an Accessibility grant to the signing identity. With an ad-hoc
# signature that is the binary's cdhash, so every rebuild voided the grant. A
# self-signed certificate keeps one stable identity across rebuilds instead.
# Create it once (see README), or the build falls back to ad-hoc.
# A release is signed ad-hoc: the self-signed certificate exists only on the
# machine that made it, so a signature from it means nothing to anyone else.
# Neither is a Developer ID, so a download is quarantined either way and the
# README says how to open it.
IDENTITY="M560Mapper Self-Signed"
if [ "$MODE" = "--release" ]; then
	codesign --force --deep --sign - "$APP"
elif security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
	codesign --force --deep --sign "$IDENTITY" "$APP"
else
	echo "warning: '$IDENTITY' not found, signing ad-hoc; the Accessibility grant will not survive rebuilds" >&2
	codesign --force --deep --sign - "$APP"
fi

echo "Built $APP"

# A login-item agent belongs in /Applications; the Accessibility grant follows
# the signing certificate, not the path, so moving it costs nothing.
if [ "$MODE" = "--install" ]; then
	rm -rf "/Applications/$APP"
	cp -R "$APP" /Applications/
	echo "Installed /Applications/$APP"
fi

if [ "$MODE" = "--release" ]; then
	VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
	ARCHIVE="M560Mapper-$VERSION.zip"
	rm -f "$ARCHIVE"
	# ditto keeps the bundle's symlinks and extended attributes intact, which
	# plain zip does not, and a mangled bundle will not launch.
	ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
	codesign --verify --deep --strict "$APP"
	echo "Packaged $ARCHIVE"
fi
