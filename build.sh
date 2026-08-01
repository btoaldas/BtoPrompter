#!/bin/zsh
# Compila BtoPrompter.app en dist/ a partir de Sources/ (todas las capas).
set -e
cd "$(dirname "$0")"
APP=dist/BtoPrompter.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -o "$APP/Contents/MacOS/BtoPrompter" Sources/**/*.swift
codesign -s - --force "$APP"
echo "OK → $APP"
