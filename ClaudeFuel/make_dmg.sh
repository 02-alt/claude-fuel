#!/bin/bash
# Builds TokenFuel.dmg — a drag-to-Applications installer with an instructions background.
# The pretty background/icon layout needs Finder automation (run on an interactive Mac);
# if that's unavailable the DMG is still produced, just without the styled background.
set -e
cd "$(dirname "$0")"

APP="ClaudeFuel.app"
[ -d "$APP" ] || ./build_app.sh

VOL="Token Fuel"
STAGE="dmg_stage"; TMP="TokenFuel-tmp.dmg"; FINAL="TokenFuel.dmg"
rm -rf "$STAGE" "$TMP" "$FINAL"

# A volume named "$VOL" left mounted from a previous build/open collides with the staging
# image (it mounts as "$VOL 1"), so the Finder styling targets the wrong disk and no
# .DS_Store gets baked in — the DMG then opens as a plain, unstyled window. Detach any first.
while [ -d "/Volumes/$VOL" ]; do hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || break; done

mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"
cp README.txt "$STAGE/README.txt"
swift Icon/make_dmg_bg.swift "$STAGE/.background/bg.png"

echo "▸ Creating disk image…"
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$TMP" >/dev/null
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP" | egrep '^/dev/' | head -1 | awk '{print $1}')

echo "▸ Styling window (Finder)…"
perl -e 'alarm 25; exec @ARGV' osascript - "$VOL" "$APP" >/dev/null 2>&1 <<'OSA' \
    || echo "  (skipped Finder styling — run on an interactive Mac to bake the background)"
on run argv
  set vol to item 1 of argv
  set appName to item 2 of argv
  tell application "Finder"
    tell disk vol
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {160, 120, 880, 600}
      set opts to the icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 104
      set background picture of opts to file ".background:bg.png"
      set position of item appName of container window to {210, 180}
      set position of item "Applications" of container window to {510, 180}
      set position of item "README.txt" of container window to {360, 360}
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
OSA

sync
hdiutil detach "$DEV" >/dev/null 2>&1 || true

echo "▸ Compressing…"
hdiutil convert "$TMP" -format UDZO -imagekey zlib-level=9 -o "$FINAL" >/dev/null
rm -f "$TMP"; rm -rf "$STAGE"

echo "✓ Built $(pwd)/$FINAL"
echo "  Share it — recipients drag Token Fuel to Applications, then right-click → Open the first time."
