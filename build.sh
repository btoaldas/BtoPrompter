#!/bin/zsh
# Compila BtoPrompter.app en dist/ a partir de Sources/ (todas las capas).
set -e
cd "$(dirname "$0")"
APP=dist/BtoPrompter.app
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -o "$APP/Contents/MacOS/BtoPrompter" Sources/**/*.swift
codesign -s - --force "$APP"
echo "OK → $APP"
