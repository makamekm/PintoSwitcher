#!/bin/zsh
# Сборка DMG для релиза: build/PintoSwitcher-<версия>.dmg
#   ./release.sh
set -euo pipefail
cd "${0:A:h}"

APP_NAME=PintoSwitcher
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
DMG="build/$APP_NAME-$VERSION.dmg"
STAGE="build/dmg"
RW="build/$APP_NAME-rw.dmg"
VOLUME="/Volumes/$APP_NAME"

./build.sh

echo "→ подготовка образа"
rm -rf "$STAGE" "$RW" "$DMG"
mkdir -p "$STAGE/.background"
cp -R "build/$APP_NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
if [[ -f Packaging/dmg-background.png && -f Packaging/dmg-background@2x.png ]]; then
  tiffutil -cathidpicheck Packaging/dmg-background.png Packaging/dmg-background@2x.png \
    -out "$STAGE/.background/background.tiff" >/dev/null
fi

[[ -d "$VOLUME" ]] && hdiutil detach "$VOLUME" -force >/dev/null || true
hdiutil create -srcfolder "$STAGE" -volname "$APP_NAME" -fs HFS+ -format UDRW -size 60m "$RW" >/dev/null
hdiutil attach "$RW" -readwrite -noverify -noautoopen >/dev/null

echo "→ оформление окна"
if ! osascript <<EOF
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 560}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    if exists file ".background:background.tiff" then
      set background picture of opts to file ".background:background.tiff"
    end if
    set position of item "$APP_NAME.app" of container window to {165, 190}
    set position of item "Applications" of container window to {495, 190}
    update without registering applications
    delay 1
    close
    -- повторное открытие закрепляет размер окна в .DS_Store
    open
    set the bounds of container window to {200, 120, 860, 560}
    delay 2
    close
  end tell
end tell
EOF
then
  echo "⚠️  Finder не дал оформить окно (нет разрешения на автоматизацию) — DMG будет без фона."
fi

# ждём, пока Finder запишет .DS_Store
for _ in {1..20}; do [[ -f "$VOLUME/.DS_Store" ]] && break; sleep 0.5; done
sleep 2
sync
chmod -Rf go-w "$VOLUME" || true
hdiutil detach "$VOLUME" >/dev/null
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"
rm -rf "$STAGE"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')}"
[[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "$DMG"

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✓ $DMG"
