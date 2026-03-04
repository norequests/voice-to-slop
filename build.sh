#!/bin/bash
# Build a proper .app bundle you can double-click and drag to /Applications
set -e

# Build TDLib if not already built
if [ ! -f "tdlib-local/lib/libtdjson.dylib" ]; then
    echo "📦 TDLib not found. Building (this takes a few minutes first time)..."
    chmod +x scripts/setup-tdlib.sh
    scripts/setup-tdlib.sh
fi

echo "🔨 Building..."
swift build -c release

APP="TelegramVoiceHotkey.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources/lib"

cp .build/release/TelegramVoiceHotkey "$APP/Contents/MacOS/"

# Bundle TDLib
# Copy all dylib files (resolving symlinks) so versioned names are present
for f in tdlib-local/lib/libtdjson*.dylib; do
    cp -L "$f" "$APP/Contents/Resources/lib/"
done
# Fix rpath in the binary
install_name_tool -add_rpath "@executable_path/../Resources/lib" "$APP/Contents/MacOS/TelegramVoiceHotkey" 2>/dev/null || true
echo "📦 Bundled TDLib ($(ls "$APP/Contents/Resources/lib/" | grep tdjson | tr '\n' ' '))"

# Bundle ffmpeg for OGG/Opus conversion
SYS_FFMPEG=$(which ffmpeg 2>/dev/null || echo "")
if [ -n "$SYS_FFMPEG" ]; then
    cp "$SYS_FFMPEG" "$APP/Contents/Resources/ffmpeg"
    echo "📦 Bundled ffmpeg"
else
    echo "⚠️  ffmpeg not found — install: brew install ffmpeg"
fi

# Generate .icns icon
if command -v iconutil &>/dev/null && [ -f Assets/icon.png ]; then
    ICONSET="$APP/Contents/Resources/AppIcon.iconset"
    mkdir -p "$ICONSET"
    sips -z 16 16     Assets/icon.png --out "$ICONSET/icon_16x16.png"      2>/dev/null
    sips -z 32 32     Assets/icon.png --out "$ICONSET/icon_16x16@2x.png"   2>/dev/null
    sips -z 32 32     Assets/icon.png --out "$ICONSET/icon_32x32.png"      2>/dev/null
    sips -z 64 64     Assets/icon.png --out "$ICONSET/icon_32x32@2x.png"   2>/dev/null
    sips -z 128 128   Assets/icon.png --out "$ICONSET/icon_128x128.png"    2>/dev/null
    sips -z 256 256   Assets/icon.png --out "$ICONSET/icon_128x128@2x.png" 2>/dev/null
    sips -z 256 256   Assets/icon.png --out "$ICONSET/icon_256x256.png"    2>/dev/null
    sips -z 512 512   Assets/icon.png --out "$ICONSET/icon_256x256@2x.png" 2>/dev/null
    sips -z 512 512   Assets/icon.png --out "$ICONSET/icon_512x512.png"    2>/dev/null
    sips -z 1024 1024 Assets/icon.png --out "$ICONSET/icon_512x512@2x.png" 2>/dev/null
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
    echo "🎨 Icon generated"
fi

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>TelegramVoiceHotkey</string>
    <key>CFBundleIdentifier</key>
    <string>com.funktools.telegram-voice-hotkey</string>
    <key>CFBundleName</key>
    <string>Telegram Voice Hotkey</string>
    <key>CFBundleDisplayName</key>
    <string>Telegram Voice Hotkey</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Records audio to send as voice messages to Telegram.</string>
</dict>
</plist>
EOF

echo ""
echo "✅ Built: $APP"
echo ""
echo "To install:"
echo "  cp -r TelegramVoiceHotkey.app /Applications/"
