#!/bin/zsh
# Builds DiskLens.app (universal: arm64 + x86_64) into ./build/
#
# Usage: scripts/build-app.sh [--arm64-only]
# Environment:
#   SIGN_IDENTITY    codesigning identity (default "-" = ad-hoc), e.g.
#                    "Developer ID Application: Your Name (TEAMID)"
#   UPDATE_FEED_URL  JSON feed for update checks (optional)
#   VERSION          marketing version (default 1.1.0)
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

APP_NAME="DiskLens"
BUNDLE_ID="com.disklens.DiskLens"
VERSION="${VERSION:-1.1.0}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
UPDATE_FEED_URL="${UPDATE_FEED_URL:-}"

ARCH_FLAGS=(--arch arm64 --arch x86_64)
if [[ "${1:-}" == "--arm64-only" ]]; then
  ARCH_FLAGS=(--arch arm64)
fi

echo "▸ Compiling (release)…"
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

echo "▸ Localizations"
for lproj in "$ROOT"/Localization/*.lproj; do
  dest="$APP/Contents/Resources/${lproj:t}"
  mkdir -p "$dest"
  for f in "$lproj"/*; do
    # Validate and convert to binary plist like Xcode does.
    plutil -lint -s "$f"
    plutil -convert binary1 -o "$dest/${f:t}" "$f"
  done
done

echo "▸ Rendering icon"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>tr</string></array>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>DiskLens</string>
  <key>DLUpdateFeedURL</key><string>$UPDATE_FEED_URL</string>
</dict>
</plist>
PLIST

echo "▸ Signing ($SIGN_IDENTITY)"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - --options runtime "$APP"
else
  codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --strict "$APP"

echo "✓ Built $APP ($VERSION, $BUILD_NUMBER)"
