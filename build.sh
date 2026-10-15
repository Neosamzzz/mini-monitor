#!/bin/zsh
# 编译并打包成 MiniMonitor.app(菜单栏应用,不显示 Dock 图标)
set -e
cd "$(dirname "$0")"
APP=MiniMonitor.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS
swiftc -O -parse-as-library -swift-version 5 main.swift -o $APP/Contents/MacOS/MiniMonitor
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.hyberiid.minimonitor</string>
  <key>CFBundleName</key><string>MiniMonitor</string>
  <key>CFBundleExecutable</key><string>MiniMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign -s - --force $APP >/dev/null 2>&1
echo "built $APP"
