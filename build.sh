#!/bin/bash
# Builds ToDo.app from source and packages it as an unsigned (ad-hoc signed)
# .app bundle right here in this folder. Re-run after any source change.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ToDo"
APP_DIR="${APP_NAME}.app"

echo "==> Building release binary…"
swift build -c release

echo "==> Assembling ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp ".build/release/ToDoApp" "$APP_DIR/Contents/MacOS/ToDoApp"
cp "Info.plist" "$APP_DIR/Contents/Info.plist"
mkdir -p "Tasks"

echo "==> Ad-hoc signing so macOS will run it…"
codesign --force --sign - "$APP_DIR"

echo "==> Done. Launch with: open \"$APP_DIR\""
