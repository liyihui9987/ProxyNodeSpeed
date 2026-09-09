#!/bin/zsh
# 编译 ProxyNodeSpeed 并生成 App 包
set -euo pipefail
cd "${0:A:h}"

swiftc -O -o ProxyNodeSpeed Sources/TiZiMenu.swift -framework AppKit

app="dist/ProxyNodeSpeed.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ProxyNodeSpeed "$app/Contents/MacOS/ProxyNodeSpeed"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ProxyNodeSpeed</string>
    <key>CFBundleIdentifier</key><string>local.proxy.nodespeed</string>
    <key>CFBundleExecutable</key><string>ProxyNodeSpeed</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$app"
echo "已生成：$PWD/$app"
