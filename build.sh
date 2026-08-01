#!/bin/zsh
# Compila BtoPrompter.app en dist/
set -e
cd "$(dirname "$0")"
APP=dist/BtoPrompter.app
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -o "$APP/Contents/MacOS/BtoPrompter" Sources/main.swift
codesign -s - --force "$APP"
echo "OK → $APP"
