#!/bin/bash
set -e

APP_NAME="CodeIsland"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ICON_CATALOG="Assets.xcassets"
ICON_SOURCE="AppIcon.icon"
ICON_INFO_PLIST=".build/AppIcon.partial.plist"

echo "Building $APP_NAME (universal)..."
swift build -c release --arch arm64
swift build -c release --arch x86_64

echo "Creating universal binaries..."
ARM_DIR=".build/arm64-apple-macosx/release"
X86_DIR=".build/x86_64-apple-macosx/release"

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Helpers"
mkdir -p "$APP_BUNDLE/Contents/Resources"

lipo -create "$ARM_DIR/$APP_NAME" "$X86_DIR/$APP_NAME" \
     -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
lipo -create "$ARM_DIR/codeisland-bridge" "$X86_DIR/codeisland-bridge" \
     -output "$APP_BUNDLE/Contents/Helpers/codeisland-bridge"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

echo "Compiling app icon assets..."
xcrun actool \
    --output-format human-readable-text \
    --warnings \
    --errors \
    --notices \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ICON_INFO_PLIST" \
    --compile "$APP_BUNDLE/Contents/Resources" \
    "$ICON_CATALOG" \
    "$ICON_SOURCE"

# Copy SPM resource bundles into Contents/Resources/ (required for code signing)
for bundle in .build/*/release/*.bundle; do
    if [ -e "$bundle" ]; then
        cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
        break
    fi
done

ENTITLEMENTS="CodeIsland.entitlements"

# Use SIGN_ID env var, or auto-detect first valid codesigning identity, or fall back to ad-hoc
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning | head -1 | sed 's/.*"\(.*\)".*/\1/' 2>/dev/null || true)
fi
if [ -z "$SIGN_ID" ]; then
    echo "No developer certificate found, using ad-hoc signing..."
    SIGN_ID="-"
fi

echo "Code signing ($SIGN_ID)..."
codesign --force --sign "$SIGN_ID" "$APP_BUNDLE/Contents/Helpers/codeisland-bridge"
codesign --force --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

echo "Done: $APP_BUNDLE"
echo "Run: open $APP_BUNDLE"
