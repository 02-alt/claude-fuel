#!/bin/bash
# Builds a fully signed + notarized + stapled TokenFuel.dmg that opens with NO Gatekeeper
# warnings for anyone. Requires: a "Developer ID Application" cert in the keychain and a stored
# notarytool credential profile (see README-notarize note). One-time setup already done for this Mac.
#
# TIME-SENSITIVE NOTIFICATIONS — one-time portal setup so the refill banner breaks through Focus:
#   1. developer.apple.com → Identifiers → register an explicit App ID "com.claudefuel.tokenfuel"
#      and enable the "Time Sensitive Notifications" capability on it.
#   2. Profiles → create a *Developer ID* provisioning profile for that App ID, download it.
#   3. Save it as ClaudeFuel.provisionprofile next to this script (build_app.sh embeds it as
#      Contents/embedded.provisionprofile). Until that file exists the app still builds & notarizes
#      fine — the notification just falls back to the default interruption level.
set -e
cd "$(dirname "$0")"

IDENTITY="Developer ID Application: MATTHIEU FRANCOIS MILO COMALADA (JLR4F273N8)"
PROFILE="TokenFuel"     # xcrun notarytool store-credentials profile
APP="ClaudeFuel.app"
DMG="TokenFuel.dmg"

# 1. Assemble the .app (release build + bundle + flat resources), then RE-SIGN it with the
#    Developer ID cert, the hardened runtime, and a secure timestamp (all required to notarize).
echo "▸ Building app…"
./build_app.sh >/dev/null

echo "▸ Signing Sparkle.framework (inside-out) with Developer ID + hardened runtime…"
# Nested code must be Developer-ID + hardened-runtime signed before the app, or notarization fails.
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ -d "$SP" ]; then
    for item in "$SP/XPCServices/Downloader.xpc" "$SP/XPCServices/Installer.xpc" \
                "$SP/Autoupdate" "$SP/Updater.app"; do
        [ -e "$item" ] && codesign --force --options runtime --timestamp --sign "$IDENTITY" "$item"
    done
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
fi

echo "▸ Signing the app with Developer ID + hardened runtime…"
# The Time-Sensitive entitlement is RESTRICTED: signing it in WITHOUT an authorizing embedded
# Developer ID provisioning profile makes macOS refuse to launch the app ("Launchd job spawn
# failed"). So only apply the entitlement when the profile is actually present (see notarize.sh
# header for the one-time App ID setup). Without it we sign clean → the app launches fine and the
# refill notification just uses the default interruption level.
ENT_ARG=""
if [ -f "$APP/Contents/embedded.provisionprofile" ]; then
    ENT_ARG="--entitlements ClaudeFuel.entitlements"
    echo "  (Time-Sensitive notifications enabled via embedded profile)"
else
    echo "  (no provisioning profile — signing without the Time-Sensitive entitlement)"
fi
codesign --force --options runtime --timestamp $ENT_ARG --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 2. Notarize the APP (zip it, submit, wait), then staple the ticket so it's trusted even offline.
echo "▸ Notarizing app (this can take a few minutes)…"
rm -f ClaudeFuel.zip
ditto -c -k --keepParent "$APP" ClaudeFuel.zip
xcrun notarytool submit ClaudeFuel.zip --keychain-profile "$PROFILE" --wait
rm -f ClaudeFuel.zip
xcrun stapler staple "$APP"

# 3. Build the DMG (it packages the now-notarized, stapled app), then notarize + staple the DMG too.
echo "▸ Building DMG…"
./make_dmg.sh >/dev/null

echo "▸ Notarizing DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# 4. Verify. The app is checked with spctl (Gatekeeper exec assessment); the DMG is verified with
#    `stapler validate` — DMGs are notarized+stapled, not code-signed, so an spctl signature check
#    would misleadingly say "rejected / no usable signature".
echo "▸ Verifying…"
spctl -a -vvv -t exec "$APP" 2>&1 | sed 's/^/  app:  /'
xcrun stapler validate "$DMG" 2>&1 | tail -1 | sed 's/^/  dmg:  /'
echo "✓ Notarized + stapled: $(pwd)/$DMG"
