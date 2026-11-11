#!/bin/zsh
# Builds Awake.app into ~/Applications
set -e
cd "$(dirname "$0")"
APP=~/Applications/Awake.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
swiftc -O main.swift -o "$APP/Contents/MacOS/Awake"

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
  <key>CFBundleIdentifier</key><string>local.awake</string>
  <key>CFBundleExecutable</key><string>Awake</string>
  <key>CFBundleIconFile</key><string>Awake</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
