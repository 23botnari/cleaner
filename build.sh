#!/bin/zsh
# Compilează „Cleaner MacOS”, asamblează .app, semnează și instalează în ~/Applications.
#   --install  instalează în ~/Applications
#   --dmg      build/CleanerMacOS.dmg, semnat cu identitatea de dezvoltare
#   --release  DMG pentru publicare: semnat cu „Developer ID Application” (dacă există în Keychain)
#              și notarizat când NOTARY_PROFILE numește un profil salvat cu
#              `xcrun notarytool store-credentials`.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Cleaner MacOS"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
# Aceeași identitate la fiecare build => permisiunea Full Disk Access rămâne valabilă.
# Implicit: certificatul cu care e semnată copia instalată, altfel primul „Apple Development” din Keychain.
INSTALLED_ID=""
for CANDIDATE in "$APP_NAME" "Cleaner" "Curățenie Mac"; do
  [[ -n "$INSTALLED_ID" ]] && break
  INSTALLED_ID="$(codesign -dvv "$HOME/Applications/$CANDIDATE.app" 2>&1 | sed -n 's/^Authority=\(Apple Development: .*\)/\1/p' | head -1 || true)"
done
SIGN_ID="${SIGN_ID:-${INSTALLED_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)}}"

MODE="${1:-}"
TIMESTAMP="--timestamp=none"
if [[ "$MODE" == "--release" ]]; then
  # Actualizările se instalează doar dacă sunt semnate cu aceeași identitate ca versiunea instalată:
  # păstrează aceeași identitate de la un release la altul.
  DEVID="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
  if [[ -n "$DEVID" ]]; then
    SIGN_ID="$DEVID"
    TIMESTAMP="--timestamp"
  else
    echo "Atenție: nu există „Developer ID Application” în Keychain; semnez cu '$SIGN_ID'. Gatekeeper va avertiza la prima deschidere."
  fi
fi

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
for LPROJ in Resources/*.lproj; do ditto "$LPROJ" "$APP/Contents/Resources/$(basename "$LPROJ")"; done

if [[ ! -f "$BUILD_DIR/AppIcon.icns" || scripts/make_icon.swift -nt "$BUILD_DIR/AppIcon.icns" ]]; then
  rm -rf "$BUILD_DIR/AppIcon.iconset"
  swift scripts/make_icon.swift "$BUILD_DIR/AppIcon.iconset"
  iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"
fi
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "$SIGN_ID" ]] && security find-identity -v -p codesigning | grep -qF "$SIGN_ID"; then
  codesign --force --options runtime $TIMESTAMP --entitlements Resources/CuratenieMac.entitlements --sign "$SIGN_ID" "$APP"
else
  echo "Identitatea '$SIGN_ID' lipsește; semnez ad-hoc (Full Disk Access se va cere din nou după fiecare build)."
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

if [[ "$MODE" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  pkill -x Cleaner 2>/dev/null || true
  rm -rf "$HOME/Applications/$APP_NAME.app"
  # Copia cu numele vechi (același bundle ID) ar încurca LaunchServices: o mut la Coș, recuperabil.
  for OLD in "Cleaner" "Curățenie Mac"; do
    if [[ -d "$HOME/Applications/$OLD.app" ]]; then
      mv "$HOME/Applications/$OLD.app" "$HOME/.Trash/$OLD $(date +%H.%M.%S).app"
      echo "Mutat la Coș: $HOME/Applications/$OLD.app"
    fi
  done
  ditto "$APP" "$HOME/Applications/$APP_NAME.app"
  echo "Instalat: $HOME/Applications/$APP_NAME.app"
fi

if [[ "$MODE" == "--dmg" || "$MODE" == "--release" ]]; then
  STAGE="$BUILD_DIR/dmg"
  rm -rf "$STAGE" "$BUILD_DIR/CleanerMacOS.dmg"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/$APP_NAME.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$BUILD_DIR/CleanerMacOS.dmg" >/dev/null
  rm -rf "$STAGE"
  if [[ "$MODE" == "--release" ]]; then
    DMG="$BUILD_DIR/CleanerMacOS.dmg"
    if [[ "$TIMESTAMP" == "--timestamp" ]]; then codesign --force --timestamp --sign "$SIGN_ID" "$DMG"; fi
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
      xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
      xcrun stapler staple "$DMG"
    else
      echo "NOTARY_PROFILE nu e setat: DMG-ul nu e notarizat."
    fi
  fi
  echo "DMG: $PWD/$BUILD_DIR/CleanerMacOS.dmg"
fi
