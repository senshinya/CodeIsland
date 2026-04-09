#!/bin/bash
set -e

APP_NAME="CodeIsland"
BUILD_DIR=".build/debug"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# Kill existing instance
pkill -x "$APP_NAME" 2>/dev/null && echo "Killed existing $APP_NAME" || true

echo "Building $APP_NAME (debug)..."
swift build

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Helpers"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$BUILD_DIR/codeisland-bridge" "$APP_BUNDLE/Contents/Helpers/codeisland-bridge"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Copy SPM resource bundles
for bundle in "$BUILD_DIR"/*.bundle; do
    if [ -e "$bundle" ]; then
        cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
        break
    fi
done

echo "Signing..."
codesign --force --sign - "$APP_BUNDLE/Contents/Helpers/codeisland-bridge"
codesign --force --sign - --entitlements CodeIsland.entitlements "$APP_BUNDLE"

echo "Launching $APP_BUNDLE"
open "$APP_BUNDLE"
