#!/bin/zsh
# Compila BtoPrompter.app en dist/ a partir de Sources/ (todas las capas).
set -e
cd "$(dirname "$0")"
APP=dist/BtoPrompter.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# El piso de despliegue se fija al declarado en Info.plist: sin -target el
# binario hereda la versión del Mac que compila y no arranca en Macs antiguos.
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)
ARCH=$(uname -m)
swiftc -O -target "${ARCH}-apple-macos${MIN_OS}" \
  -o "$APP/Contents/MacOS/BtoPrompter" Sources/**/*.swift
# Identidad de firma: si existe un certificado local propio se usa ese, porque
# mantiene estable el requisito de la firma y los permisos del sistema
# (Accesibilidad, micrófono) sobreviven a cada recompilación. Si no existe, se
# firma ad-hoc y macOS pedirá los permisos otra vez tras cada build.
SIGN_ID="${BTOPROMPTER_SIGN_ID:-BtoPrompter Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  # Con runtime reforzado hay que declarar los permisos que la app usa
  # (micrófono, eventos de otras apps); si no, macOS los deniega sin preguntar.
  codesign -s "$SIGN_ID" --force --options runtime \
    --entitlements BtoPrompter.entitlements "$APP"
else
  codesign -s - --force "$APP"
fi
echo "OK → $APP"
