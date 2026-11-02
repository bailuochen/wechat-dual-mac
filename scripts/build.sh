#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
APP_NAME="微信分身助手"
APP="dist/${APP_NAME}.app"
mkdir -p dist

if [[ "${1:-}" == "--universal" ]]; then
    swift build -c release --arch arm64 --build-path .build/arm64
    swift build -c release --arch x86_64 --build-path .build/x86_64
    ARM_BIN="$(swift build -c release --arch arm64 --build-path .build/arm64 --show-bin-path)/WeChatDual"
    INTEL_BIN="$(swift build -c release --arch x86_64 --build-path .build/x86_64 --show-bin-path)/WeChatDual"
    mkdir -p "$APP/Contents/MacOS"
    lipo -create "$ARM_BIN" "$INTEL_BIN" -output "$APP/Contents/MacOS/WeChatDual"
else
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/WeChatDual"
    mkdir -p "$APP/Contents/MacOS"
    cp "$BIN" "$APP/Contents/MacOS/WeChatDual"
fi

mkdir -p "$APP/Contents/Resources"
/usr/libexec/PlistBuddy -c 'Clear dict' -c 'Add :CFBundleDevelopmentRegion string zh_CN' \
    -c 'Add :CFBundleExecutable string WeChatDual' \
    -c 'Add :CFBundleIdentifier string io.github.bailuochen.wechat-dual-mac' \
    -c "Add :CFBundleName string $APP_NAME" \
    -c "Add :CFBundleDisplayName string $APP_NAME" \
    -c 'Add :CFBundlePackageType string APPL' \
    -c "Add :CFBundleShortVersionString string $VERSION" \
    -c "Add :CFBundleVersion string $VERSION" \
    -c 'Add :LSMinimumSystemVersion string 13.0' \
    -c 'Add :NSHighResolutionCapable bool true' \
    -c 'Add :NSPrincipalClass string NSApplication' \
    -c 'Add :NSHumanReadableCopyright string Copyright © 2026 bailuochen. MIT License.' \
    -c 'Add :CFBundleIconFile string AppIcon' \
    "$APP/Contents/Info.plist"

swift scripts/make-icon.swift dist/AppIcon.iconset
iconutil -c icns dist/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/WeChatDual-${VERSION}-macOS.zip"
(
    cd dist
    LC_ALL=C shasum -a 256 "WeChatDual-${VERSION}-macOS.zip" > SHA256SUMS.txt
)
echo "Built: $APP"
