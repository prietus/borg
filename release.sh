#!/bin/bash
set -euo pipefail

# BorgMac Release Script
# Usage: ./release.sh 0.1.0
#        NOTARIZE=0 ./release.sh 0.1.0   # skip notarization (faster, dev only)
#        PUBLISH=0  ./release.sh 0.1.0   # notarize but don't upload to the site
#
# Builds, signs, and notarizes a Release .app with Developer ID, then
# publishes the zip + marketing site to borgmac.priet.us.
# Pending for later: DMG, brew cask, git tag.

VERSION="${1:?Usage: ./release.sh VERSION}"
NOTARIZE="${NOTARIZE:-1}"
PUBLISH="${PUBLISH:-1}"

TEAM_ID="LFTD9T269J"
SIGN_ID="Developer ID Application: carlos prieto ortiz ($TEAM_ID)"
KEYCHAIN_PROFILE="notarytool-profile"

SITE_DIR="/Users/carlos/borgmac-site"
PUBLISH_HOST="teraflops@192.168.1.37"
PUBLISH_PATH="/home/teraflops/borgmac/site"

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED="/tmp/BorgMac-build"
# Unversioned .app path so `cp -R "$APP_OUT" /Applications/` always
# overwrites the previous install instead of piling up
# `BorgMac-0.1.0.app`, `BorgMac-0.2.0.app`, … side by side. The zip
# keeps the version because it's the distribution artifact and we
# want different uploads to be distinguishable.
APP_OUT="/tmp/BorgMac.app"
ZIP_OUT="/tmp/BorgMac-${VERSION}.zip"

cd "$PROJECT_DIR"

echo "==> Generating Xcode project from project.yml..."
xcodegen generate

echo "==> Cleaning previous build artifacts..."
rm -rf "$DERIVED" "$APP_OUT" "$ZIP_OUT"

echo "==> Building Release v${VERSION}..."
xcodebuild \
    -project BorgMac.xcodeproj \
    -scheme BorgMac \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_ID" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES \
    OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
    build \
    | grep -E "^(===|warning:|error:|\*\*)" || true

BUILT_APP="$DERIVED/Build/Products/Release/BorgMac.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "ERROR: build did not produce $BUILT_APP" >&2
    exit 1
fi

echo "==> Copying to $APP_OUT..."
cp -R "$BUILT_APP" "$APP_OUT"

echo "==> Re-signing the bundle (hardened runtime)..."
# Sign inside-out so nested bundles get their entitlements preserved.
# `codesign --deep` drops per-bundle entitlements when you don't pass
# `--entitlements` at each step, which silently strips the widget's
# sandbox + temporary-exception flags and makes chronod refuse to
# load it with "Extension is not entitled to run in the App Sandbox".
WIDGET_APPEX="$APP_OUT/Contents/PlugIns/BorgMacWidget.appex"
WIDGET_ENTITLEMENTS="$PROJECT_DIR/BorgMacWidget/BorgMacWidget.entitlements"
codesign --force --options runtime --timestamp \
    --entitlements "$WIDGET_ENTITLEMENTS" \
    --sign "$SIGN_ID" "$WIDGET_APPEX"
codesign --force --options runtime --timestamp \
    --sign "$SIGN_ID" "$APP_OUT"

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_OUT"
codesign -dv --verbose=4 "$APP_OUT" 2>&1 \
    | grep -E "(Identifier|TeamIdentifier|Authority|Sealed Resources|Signature|Hardened)"

if [ "$NOTARIZE" != "1" ]; then
    echo
    echo "==> Notarization skipped (NOTARIZE=$NOTARIZE)."
    echo "    App: $APP_OUT (signed but NOT notarized)"
    exit 0
fi

echo "==> Wrapping into zip for notarization..."
ditto -c -k --keepParent "$APP_OUT" "$ZIP_OUT"

echo "==> Submitting to Apple notarization service (this can take 1-5 min)..."
xcrun notarytool submit "$ZIP_OUT" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

echo "==> Stapling notarization ticket to the .app..."
xcrun stapler staple "$APP_OUT"

echo "==> Re-zipping the stapled .app for distribution..."
rm -f "$ZIP_OUT"
ditto -c -k --keepParent "$APP_OUT" "$ZIP_OUT"

echo "==> Final Gatekeeper assessment (should now pass):"
spctl --assess --type exec --verbose=4 "$APP_OUT"

if [ "$PUBLISH" != "1" ]; then
    echo
    echo "==> Publish skipped (PUBLISH=$PUBLISH)."
    echo "    App: $APP_OUT"
    echo "    Zip: $ZIP_OUT"
    exit 0
fi

echo "==> Building marketing site with version ${VERSION}..."
# Astro reads PUBLIC_APP_VERSION at build time via import.meta.env.
# No file mutations — just an env var, so the source stays clean across
# releases and the single source of truth is $VERSION.
# node@18 is keg-only in homebrew (not linked into /opt/homebrew/bin),
# so prepend its bin dir here. Otherwise the script exits with
# "npm: command not found" mid-release.
NODE_BIN="/opt/homebrew/opt/node@18/bin"
(cd "$SITE_DIR" && PATH="$NODE_BIN:$PATH" PUBLIC_APP_VERSION="$VERSION" npm run build)

echo "==> Uploading zip ${ZIP_OUT} to ${PUBLISH_HOST}:${PUBLISH_PATH}/..."
scp "$ZIP_OUT" "${PUBLISH_HOST}:${PUBLISH_PATH}/"

echo "==> Syncing site ${SITE_DIR}/dist/ to ${PUBLISH_HOST}:${PUBLISH_PATH}/..."
# --delete cleans up stale hashed assets from previous builds. The
# --exclude keeps every versioned zip intact, so old download links
# keep resolving even after we ship a new build.
rsync -av --delete \
    --exclude 'BorgMac-*.zip' \
    "$SITE_DIR/dist/" \
    "${PUBLISH_HOST}:${PUBLISH_PATH}/"

echo
echo "==> Done."
echo "    App:     $APP_OUT"
echo "    Zip:     $ZIP_OUT"
echo "    Version: $VERSION"
echo "    Signed:  $SIGN_ID"
echo "    Status:  notarized + stapled + published"
echo "    Site:    https://borgmac.priet.us/"
echo
echo "    Open with: open \"$APP_OUT\""
