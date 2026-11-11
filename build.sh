#!/bin/zsh
# Builds Awake.app into ~/Applications
set -e
cd "$(dirname "$0")"
APP=~/Applications/Awake.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
# Universal binary: runs on Apple Silicon and Intel Macs (macOS 13+)
TMP=$(mktemp -d)
swiftc -O -target arm64-apple-macos13 Sources/*.swift -o "$TMP/Awake-arm64"
swiftc -O -target x86_64-apple-macos13 Sources/*.swift -o "$TMP/Awake-x86_64"
lipo -create "$TMP/Awake-arm64" "$TMP/Awake-x86_64" -o "$APP/Contents/MacOS/Awake"

# App icon from icon/Awake.png (regenerate the PNG with: swift icon/make_icon.swift icon/Awake.png)
ICONSET=$(mktemp -d)/Awake.iconset && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s icon/Awake.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) icon/Awake.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Awake.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Awake</string>
  <key>CFBundleIdentifier</key><string>io.github.valerijaspasojevic.awake</string>
  <key>CFBundleExecutable</key><string>Awake</string>
  <key>CFBundleIconFile</key><string>Awake</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"

# ./build.sh --zip  -> also creates dist/Awake.zip for a GitHub release
if [[ "$1" == "--zip" ]]; then
  mkdir -p dist && rm -f dist/Awake.zip
  ditto -c -k --keepParent "$APP" dist/Awake.zip
  echo "Packed dist/Awake.zip"
fi
