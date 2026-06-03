#!/bin/bash
# Build and package DeepSeekStats as a macOS .app bundle
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="DeepSeekStats"
BUILD_DIR="$SCRIPT_DIR/.build/arm64-apple-macosx/debug"
ENTITLEMENTS="$SCRIPT_DIR/$APP_NAME.entitlements"

# Step 1: Build the Swift package
cd "$SCRIPT_DIR"
swift build -c debug

# Step 2: Create .app bundle structure
APP_BUNDLE="$SCRIPT_DIR/build/$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Step 3: Copy the binary
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Step 4: Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.deepseek.stats</string>
    <key>CFBundleName</key>
    <string>DeepSeekStats</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Step 5: Sign the app (ad-hoc signature for local use)
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

echo ""
echo "✅ Build complete!"
echo "App bundle: $APP_BUNDLE"
echo ""
echo "To install, copy to Applications:"
echo "  cp -R \"$APP_BUNDLE\" /Applications/"
echo ""
echo "To launch:"
echo "  open \"$APP_BUNDLE\""
echo ""
echo "To autostart on login:"
echo '  osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"/Applications/DeepSeekStats.app\", hidden:false}"'
