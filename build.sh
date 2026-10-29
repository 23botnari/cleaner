#!/bin/zsh
# Compilează „Cleaner”, asamblează .app, semnează și instalează în ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Cleaner"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
# Aceeași identitate la fiecare build => permisiunea Full Disk Access rămâne valabilă.
# Implicit: certificatul cu care e semnată copia instalată, altfel primul „Apple Development” din Keychain.
INSTALLED_ID="$(codesign -dvv "$HOME/Applications/$APP_NAME.app" 2>&1 | sed -n 's/^Authority=\(Apple Development: .*\)/\1/p' | head -1)"
SIGN_ID="${SIGN_ID:-${INSTALLED_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)}}"

# Command Line Tools pe macOS 27 nu au pluginul SwiftUIMacros cerut de SDK-ul 27: compilăm cu SDK-ul 26.
CLT_SDKS="/Library/Developer/CommandLineTools/SDKs"
if [[ -z "${SDKROOT:-}" && "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d "$CLT_SDKS/MacOSX26.sdk" ]] \
   && ! ls /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/*SwiftUIMacros* >/dev/null 2>&1; then
  export SDKROOT="$CLT_SDKS/MacOSX26.sdk"
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/CuratenieMac"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cleaner"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f "$BUILD_DIR/AppIcon.icns" ]]; then
  swift scripts/make_icon.swift "$BUILD_DIR/AppIcon.iconset"
  iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"
fi
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "$SIGN_ID" ]] && security find-identity -v -p codesigning | grep -qF "$SIGN_ID"; then
  codesign --force --options runtime --timestamp=none --entitlements Resources/CuratenieMac.entitlements --sign "$SIGN_ID" "$APP"
else
  echo "Identitatea '$SIGN_ID' lipsește; semnez ad-hoc (Full Disk Access se va cere din nou după fiecare build)."
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x Cleaner 2>/dev/null || true
  rm -rf "$HOME/Applications/$APP_NAME.app"
  ditto "$APP" "$HOME/Applications/$APP_NAME.app"
  echo "Instalat: $HOME/Applications/$APP_NAME.app"
fi

if [[ "${1:-}" == "--dmg" ]]; then
  STAGE="$BUILD_DIR/dmg"
  rm -rf "$STAGE" "$BUILD_DIR/Cleaner.dmg"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/$APP_NAME.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$BUILD_DIR/Cleaner.dmg" >/dev/null
  rm -rf "$STAGE"
  echo "DMG: $PWD/$BUILD_DIR/Cleaner.dmg"
fi
