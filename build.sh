#!/bin/zsh
# Сборка PintoSwitcher.app (Universal: Apple Silicon + Intel).
#   ./build.sh           — собрать в build/PintoSwitcher.app и прогнать самотест
#   ./build.sh install   — собрать, установить в /Applications и запустить
set -euo pipefail
cd "${0:A:h}"

APP_NAME=PintoSwitcher
BUILD=build
APP="$BUILD/$APP_NAME.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  echo "→ swiftc ($arch)"
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    Sources/*.swift -o "$BUILD/$APP_NAME-$arch" \
    -framework AppKit -framework Carbon -framework ApplicationServices -framework ServiceManagement
done
lipo -create "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64" -output "$APP/Contents/MacOS/$APP_NAME"
rm "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Иконка: Resources/AppIcon-1024.png → AppIcon.icns
if [[ -f Resources/AppIcon-1024.png ]]; then
  echo "→ иконка"
  ICONSET="$BUILD/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size*2)) $((size*2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

# Постоянная подпись нужна, чтобы macOS не сбрасывала разрешение «Универсальный доступ» после пересборки.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  echo "⚠️  Сертификат не найден — ad-hoc подпись (разрешение придётся выдавать заново после каждой сборки)."
fi
echo "→ codesign: $IDENTITY"
codesign --force --sign "$IDENTITY" --identifier local.makame.pintoswitcher "$APP"

echo "→ самотест"
"$APP/Contents/MacOS/$APP_NAME" --selftest

if [[ "${1:-}" == "install" ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  # Обновляем кэш иконок, чтобы Finder и «Программы» сразу показали новую иконку.
  touch "/Applications/$APP_NAME.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP_NAME.app" || true
  open "/Applications/$APP_NAME.app"
  echo "✓ Установлено в /Applications и запущено."
else
  echo "✓ Готово: $APP"
fi
