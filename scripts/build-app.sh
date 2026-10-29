#!/bin/bash
# 在 macOS 上打包菜单栏程序：build/Wallpaper4Mac.app
#   Contents/MacOS/Wallpaper4Mac  菜单栏界面（gui.swift）
#   Contents/MacOS/wallpaper-cli  壁纸主程序（Go + bridge.m）
# 用法：scripts/build-app.sh [--install]   --install 复制到 /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Wallpaper4Mac.app
VERSION=$(git describe --tags --always 2>/dev/null || echo dev)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> wallpaper-cli"
CGO_ENABLED=1 go build -o "$APP/Contents/MacOS/wallpaper-cli" .

echo "==> Wallpaper4Mac (SwiftUI)"
swiftc -O -parse-as-library gui.swift -o "$APP/Contents/MacOS/Wallpaper4Mac"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.xstation.wallpaper4mac</string>
    <key>CFBundleName</key>
    <string>Wallpaper4Mac</string>
    <key>CFBundleDisplayName</key>
    <string>动态壁纸</string>
    <key>CFBundleExecutable</key>
    <string>Wallpaper4Mac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP/Contents/MacOS/wallpaper-cli"
codesign --force --sign - "$APP"
echo "==> $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Wallpaper4Mac 2>/dev/null || true
    rm -rf /Applications/Wallpaper4Mac.app
    cp -R "$APP" /Applications/
    echo "==> 已安装到 /Applications/Wallpaper4Mac.app"
fi
