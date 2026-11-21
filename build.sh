#!/bin/sh
set -e
cd "$(dirname "$0")"
APP=Lyrics.app
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14" Lyrics.swift -o "$APP/Contents/MacOS/Lyrics"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.lyricssync</string>
  <key>CFBundleName</key><string>Lyrics</string>
  <key>CFBundleExecutable</key><string>Lyrics</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.1</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Lyrics reads what Music, Spotify or your browser is playing to show synced lyrics.</string>
</dict></plist>
EOF
codesign -s - --force "$APP"
echo "Built $APP"

# Install: quit the running copy (unsaved editor work is lost), replace /Applications/Lyrics.app, reopen.
pkill -x Lyrics && sleep 1 || true
rm -rf /Applications/Lyrics.app
ditto "$APP" /Applications/Lyrics.app
open /Applications/Lyrics.app
echo "Installed to /Applications/Lyrics.app"
