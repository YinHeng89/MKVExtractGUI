#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Sources/main.swift"
APP="$ROOT/build/MKVExtractGUI.app"
EXE="$APP/Contents/MacOS/MKVExtractGUI"

echo "==> 编译 SwiftUI 应用"
mkdir -p "$APP/Contents/MacOS"
swiftc -parse-as-library \
    -o "$EXE" "$SRC" \
    -framework SwiftUI -framework AppKit -framework UniformTypeIdentifiers \
    -target arm64-apple-macosx13.0

echo "==> 写入 Info.plist"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>MKVExtract GUI</string>
    <key>CFBundleDisplayName</key>         <string>MKVExtract GUI</string>
    <key>CFBundleExecutable</key>          <string>MKVExtractGUI</string>
    <key>CFBundleIdentifier</key>          <string>com.workbuddy.mkvextractgui</string>
    <key>CFBundleVersion</key>             <string>1.0</string>
    <key>CFBundleShortVersionString</key>  <string>1.0</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundleIconName</key>            <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>      <string>13.0</string>
    <key>NSPrincipalClass</key>            <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSRequiresAquaSystemAppearance</key> <false/>
</dict>
</plist>
EOF

echo "==> 安装应用图标"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> 移除隔离属性（若曾被下载）"
xattr -cr "$APP" 2>/dev/null || true

echo "==> ad-hoc 签名（不启用沙箱）"
# 沙箱会把 mkvextract/mkvmerge 子进程一起关进去，而 NSOpenPanel 的
# security scope 不会传给子进程，导致在 Downloads 等受保护目录上报
# "open file error"。本地工具不需要沙箱，直接 ad-hoc 签名即可。
codesign --force --deep --sign - "$APP"

echo "==> 完成: $APP"
