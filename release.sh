#!/bin/bash
set -euo pipefail

# BorgMac Release Script
# Usage: ./release.sh 0.1.0
#        NOTARIZE=0 ./release.sh 0.1.0   # skip notarization (faster, dev only)
#        PUBLISH=0  ./release.sh 0.1.0   # notarize, but no tag / GitHub release / tap bump
#
# Builds, signs, and notarizes a Release .app with Developer ID and leaves
# the signed (and, by default, notarized + stapled) artifacts in ./dist.
# With PUBLISH=1 (default) it then tags v<VERSION>, pushes, creates a
# GitHub release with the zip attached, and bumps version + sha256 in the
# Homebrew cask at $TAP_DIR (clone of prietus/homebrew-tap), so that
# `brew upgrade --cask borgmac` picks the new build up.

VERSION="${1:?Usage: ./release.sh VERSION}"
NOTARIZE="${NOTARIZE:-1}"
PUBLISH="${PUBLISH:-1}"

GH_REPO="prietus/borg"
TAP_DIR="${TAP_DIR:-$HOME/homebrew-tap}"
CASK_FILE="Casks/borgmac.rb"

TEAM_ID="LFTD9T269J"
SIGN_ID="Developer ID Application: carlos prieto ortiz ($TEAM_ID)"
KEYCHAIN_PROFILE="notarytool-profile"

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED="/tmp/BorgMac-build"
# Local output folder for the release artifacts.
OUT_DIR="$PROJECT_DIR/dist"
# Unversioned .app path so `cp -R "$APP_OUT" /Applications/` always
# overwrites the previous install instead of piling up
# `BorgMac-0.1.0.app`, `BorgMac-0.2.0.app`, … side by side. The zip
# keeps the version because it's the distribution artifact and we
# want different builds to be distinguishable.
APP_OUT="$OUT_DIR/BorgMac.app"
ZIP_OUT="$OUT_DIR/BorgMac-${VERSION}.zip"

cd "$PROJECT_DIR"

if [ "$PUBLISH" = "1" ]; then
    echo "==> Pre-flight checks for publishing..."
    if [ "$NOTARIZE" != "1" ]; then
        echo "ERROR: PUBLISH=1 requires NOTARIZE=1 (never ship an un-notarized build)." >&2
        exit 1
    fi
    if [ -n "$(git status --porcelain)" ]; then
        echo "ERROR: working tree is dirty — commit or stash before publishing." >&2
        exit 1
    fi
    if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then
        echo "ERROR: tag v${VERSION} already exists." >&2
        exit 1
    fi
    if [ ! -f "$TAP_DIR/$CASK_FILE" ]; then
        echo "ERROR: cask not found at $TAP_DIR/$CASK_FILE (clone prietus/homebrew-tap there, or set TAP_DIR)." >&2
        exit 1
    fi
    gh auth status >/dev/null 2>&1 || { echo "ERROR: gh is not authenticated." >&2; exit 1; }
fi

echo "==> Generating Xcode project from project.yml..."
xcodegen generate

echo "==> Cleaning previous build artifacts..."
rm -rf "$DERIVED" "$APP_OUT" "$ZIP_OUT"
mkdir -p "$OUT_DIR"

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
    echo "    App: $APP_OUT (notarized + stapled)"
    echo "    Zip: $ZIP_OUT"
    exit 0
fi

SHA256="$(shasum -a 256 "$ZIP_OUT" | awk '{print $1}')"
echo "==> sha256: $SHA256"

echo "==> Tagging v${VERSION} and pushing to origin..."
git tag -a "v${VERSION}" -m "BorgMac ${VERSION}"
git push origin HEAD "v${VERSION}"

echo "==> Creating GitHub release v${VERSION} with $(basename "$ZIP_OUT") attached..."
gh release create "v${VERSION}" "$ZIP_OUT" \
    --repo "$GH_REPO" \
    --title "BorgMac ${VERSION}" \
    --notes "Signed and notarized build. Install with \`brew install --cask prietus/tap/borgmac\`." \
    --generate-notes

echo "==> Bumping cask to ${VERSION} in ${TAP_DIR}..."
(
    cd "$TAP_DIR"
    git pull -q --ff-only
    sed -i '' -E \
        -e "s|^(  version \").*(\")$|\1${VERSION}\2|" \
        -e "s|^(  sha256 \").*(\")$|\1${SHA256}\2|" \
        "$CASK_FILE"
    git add "$CASK_FILE"
    git commit -q -m "borgmac ${VERSION}"
    git push -q
)

echo
echo "==> Done."
echo "    App:     $APP_OUT"
echo "    Zip:     $ZIP_OUT"
echo "    Version: $VERSION"
echo "    Signed:  $SIGN_ID"
echo "    Release: https://github.com/${GH_REPO}/releases/tag/v${VERSION}"
echo "    Cask:    ${TAP_DIR}/${CASK_FILE}"
echo
echo "    Install: brew install --cask prietus/tap/borgmac"
