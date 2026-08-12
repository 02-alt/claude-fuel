#!/bin/bash
# Cuts a release: builds + signs + notarizes + staples the DMG (via notarize.sh), then signs an
# appcast and publishes it + the DMG to GitHub Releases. Existing users then auto-update via Sparkle
# (the app's SUFeedURL points at .../releases/latest/download/appcast.xml).
set -e
cd "$(dirname "$0")"
REPO="02-alt/claude-fuel"
BIN="$(/bin/ls -d .build/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1)"

# 1. Build, Developer-ID sign (incl. the embedded Sparkle.framework), notarize + staple the DMG.
#    Skip by exporting SKIP_NOTARIZE=1 if TokenFuel.dmg is already freshly notarized.
[ -n "$SKIP_NOTARIZE" ] || ./notarize.sh

VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' ClaudeFuel.app/Contents/Info.plist)"
TAG="v$VER"
echo "▸ Publishing release $TAG"

# 2. Sign the DMG with the Sparkle EdDSA key and build an appcast whose enclosure points at the
#    DMG asset that will live on this GitHub release.
rm -rf releases; mkdir -p releases
cp TokenFuel.dmg releases/
"$BIN/generate_appcast" --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" releases/

# 3. Publish to GitHub Releases (create, or update assets if the tag already exists).
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" releases/TokenFuel.dmg releases/appcast.xml --repo "$REPO" --clobber
else
    gh release create "$TAG" releases/TokenFuel.dmg releases/appcast.xml \
        --repo "$REPO" --title "$VER" --notes "Token Fuel $VER"
fi
echo "✓ Released $TAG — existing users auto-update via Sparkle; new users download the notarized DMG."
