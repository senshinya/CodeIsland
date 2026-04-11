#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodeIsland"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"
INFO_PLIST="$REPO_ROOT/Info.plist"
BUILD_ROOT="$REPO_ROOT/.build/pack-dmg"
STAGING_ROOT="$BUILD_ROOT/staging"
APP_BUNDLE="$STAGING_ROOT/${APP_NAME}.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DMG_ROOT="$BUILD_ROOT/dmg-root"

if [[ ! -f "$INFO_PLIST" ]]; then
    echo "Info.plist not found at $INFO_PLIST" >&2
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "swift is required but was not found in PATH" >&2
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun is required but was not found in PATH" >&2
    exit 1
fi

if ! command -v hdiutil >/dev/null 2>&1; then
    echo "hdiutil is required but was not found in PATH" >&2
    exit 1
fi

read_plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

VERSION="${1:-$(read_plist_value CFBundleShortVersionString)}"
VOL_NAME="${APP_NAME} ${VERSION}"
OUTPUT_DMG="${2:-$REPO_ROOT/dist/${APP_NAME}-${VERSION}.dmg}"
OUTPUT_DIR="$(dirname "$OUTPUT_DMG")"

ARM_BUILD_DIR="$BUILD_ROOT/arm64-apple-macosx/release"
X86_BUILD_DIR="$BUILD_ROOT/x86_64-apple-macosx/release"

echo "==> Building ${APP_NAME} ${VERSION} (release, universal)"
rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"

cd "$REPO_ROOT"
swift build -c release --arch arm64 --build-path "$BUILD_ROOT"
swift build -c release --arch x86_64 --build-path "$BUILD_ROOT"

echo "==> Assembling app bundle"
mkdir -p "$MACOS_DIR" "$HELPERS_DIR" "$RESOURCES_DIR"

lipo -create \
    "$ARM_BUILD_DIR/CodeIsland" \
    "$X86_BUILD_DIR/CodeIsland" \
    -output "$MACOS_DIR/CodeIsland"

lipo -create \
    "$ARM_BUILD_DIR/codeisland-bridge" \
    "$X86_BUILD_DIR/codeisland-bridge" \
    -output "$HELPERS_DIR/codeisland-bridge"

cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS_DIR/Info.plist"

xcrun actool \
    --output-format human-readable-text \
    --notices --warnings --errors \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist /dev/null \
    --compile "$RESOURCES_DIR" \
    "$REPO_ROOT/Assets.xcassets" \
    "$REPO_ROOT/AppIcon.icon"

shopt -s nullglob
for bundle in "$BUILD_ROOT"/*-apple-macosx/release/*.bundle; do
    cp -R "$bundle" "$APP_BUNDLE/"
done
shopt -u nullglob

chmod +x "$MACOS_DIR/CodeIsland" "$HELPERS_DIR/codeisland-bridge"

echo "==> Preparing DMG staging"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
cp -R "$APP_BUNDLE" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"

rm -f "$OUTPUT_DMG"

echo "==> Creating DMG at $OUTPUT_DMG"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDZO \
    "$OUTPUT_DMG"

echo "==> Done"
echo "DMG: $OUTPUT_DMG"
