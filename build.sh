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
codesign -s - --force "$APP"
echo "OK → $APP"
