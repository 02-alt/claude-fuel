#!/bin/bash
# Builds ClaudeFuel.app — a menu-bar (agent) app you can double-click / drag to /Applications.
set -e
cd "$(dirname "$0")"

echo "▸ Building release binary…"
swift build -c release

APP="ClaudeFuel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/ClaudeFuel "$APP/Contents/MacOS/ClaudeFuel"

# Bundled resources (PCB art + startup sounds) copied FLAT into Contents/Resources, loaded at
# runtime via Bundle.main. We deliberately avoid Bundle.module (the SwiftPM sub-bundle accessor):
# it fatalErrors — crashing the app — if it can't find its sub-bundle, which happened on some Macs.
cp Sources/ClaudeFuel/Resources/pcb.png "$APP/Contents/Resources/" 2>/dev/null || echo "⚠️  pcb.png missing"
cp Sources/ClaudeFuel/Resources/*.mp3 Sources/ClaudeFuel/Resources/*.m4a "$APP/Contents/Resources/" 2>/dev/null || echo "⚠️  sounds missing"

# Embed Sparkle.framework (auto-updater) and point the executable's @rpath at Contents/Frameworks.
SPARKLE_FW="$(/bin/ls -d .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework 2>/dev/null | head -1)"
if [ -d "$SPARKLE_FW" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/ClaudeFuel" 2>/dev/null || true
    echo "▸ Embedded Sparkle.framework"
else
    echo "⚠️  Sparkle.framework not found (run: swift build -c release)"
fi

# App icon: regenerate the .icns from the source art (rounded macOS mask), then bundle it.
if [ -f Icon/AppIcon-source.png ]; then
    echo "▸ Building app icon…"
    rm -rf Icon/AppIcon.iconset
    swift Icon/make_icon.swift Icon/AppIcon-source.png Icon/AppIcon.iconset >/dev/null 2>&1 \
        && iconutil -c icns Icon/AppIcon.iconset -o Icon/AppIcon.icns >/dev/null 2>&1
    [ -f Icon/AppIcon.icns ] && cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Date-based version: marketing version is 1.<YY>.<MM> (the release month, e.g. 1.26.02 for
# Feb 2026); the build number is a monotonic timestamp so Sparkle can always tell which is newer.
# Override the marketing string by putting one in a VERSION file (e.g. to pin "1.0").
SHORT="$( [ -f VERSION ] && cat VERSION || date "+1.%y.%m" )"
BUILD="$(date +%Y%m%d%H%M)"
# Sparkle appcast URL + EdDSA public key (empty until Sparkle is set up — see release-appcast.sh).
FEED_URL="https://github.com/02-alt/claude-fuel/releases/latest/download/appcast.xml"
ED_KEY="$( [ -f sparkle_public_key.txt ] && cat sparkle_public_key.txt || echo '' )"
echo "▸ Version $SHORT ($BUILD)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Token Fuel</string>
    <key>CFBundleDisplayName</key>     <string>Claude Token Fuel</string>
    <key>CFBundleIdentifier</key>      <string>com.claudefuel.tokenfuel</string>
    <key>CFBundleExecutable</key>      <string>ClaudeFuel</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${SHORT}</string>
    <key>CFBundleVersion</key>         <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>SUFeedURL</key>               <string>${FEED_URL}</string>
    <key>SUPublicEDKey</key>           <string>${ED_KEY}</string>
    <key>SUEnableInstallerLauncherService</key> <false/>
</dict>
</plist>
PLIST

# Embed the Developer ID provisioning profile if present — it's what authorizes the restricted
# Time-Sensitive notification entitlement at runtime (see notarize.sh header for how to get it).
# Optional: the app builds and runs fine without it.
if [ -f ClaudeFuel.provisionprofile ]; then
    cp ClaudeFuel.provisionprofile "$APP/Contents/embedded.provisionprofile"
    echo "✓ Embedded provisioning profile (Time-Sensitive notifications enabled)"
fi

# Ad-hoc code signature so macOS is happy launching it. A broken/failed signature makes
# Gatekeeper report the app as "damaged", so surface any error instead of hiding it.
codesign --force --deep --sign - "$APP" && codesign --verify --deep --strict "$APP" \
    && echo "✓ Code signature valid" || echo "⚠️  codesign failed — the app may be reported as damaged"

echo "✓ Built $(pwd)/$APP"
echo "  Run it:   open '$(pwd)/$APP'"
echo "  Install:  cp -R '$(pwd)/$APP' /Applications/"
