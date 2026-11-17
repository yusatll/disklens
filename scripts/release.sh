#!/bin/zsh
# Signed + notarized release: build/DiskLens-<version>.dmg and an update feed entry.
#
# Requirements (one-time):
#   - A "Developer ID Application" certificate in your keychain.
#   - Notary credentials stored with:
#       xcrun notarytool store-credentials disklens-notary --apple-id <id> --team-id <TEAMID>
#
# Usage:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=disklens-notary VERSION=1.1.0 \
#   UPDATE_FEED_URL=https://example.com/disklens/update.json \
#   DOWNLOAD_BASE_URL=https://example.com/disklens \
#   scripts/release.sh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
VERSION="${VERSION:-1.1.0}"
export SIGN_IDENTITY VERSION UPDATE_FEED_URL="${UPDATE_FEED_URL:-}"

scripts/build-app.sh

APP="build/DiskLens.app"
DMG="build/DiskLens-$VERSION.dmg"
STAGING="build/dmg"

echo "▸ Notarizing app"
ditto -c -k --keepParent "$APP" build/DiskLens-notarize.zip
xcrun notarytool submit build/DiskLens-notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f build/DiskLens-notarize.zip

echo "▸ Building disk image"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "DiskLens $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

echo "▸ Notarizing disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

if [[ -n "${DOWNLOAD_BASE_URL:-}" ]]; then
  cat > build/update.json <<JSON
{ "version": "$VERSION", "downloadURL": "$DOWNLOAD_BASE_URL/DiskLens-$VERSION.dmg", "notes": "" }
JSON
  echo "▸ Upload $DMG and build/update.json to $DOWNLOAD_BASE_URL"
fi
echo "✓ Release ready: $DMG"
