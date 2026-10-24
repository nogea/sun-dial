#!/bin/zsh
# Builds Sun Dial.app next to this script. Needs only the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"
APP="Sun Dial.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos13 \
  -o "$APP/Contents/MacOS/SunDial" Sources/main.swift 2>&1 | grep -v "^$" || true
test -x "$APP/Contents/MacOS/SunDial"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Sun Dial</string>
  <key>CFBundleIdentifier</key><string>local.sundial</string>
  <key>CFBundleExecutable</key><string>SunDial</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
