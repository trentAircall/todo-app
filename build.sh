#!/bin/bash
# Builds ToDo.app from source and packages it as an unsigned (ad-hoc signed)
# .app bundle right here in this folder. Re-run after any source change.
#
# Tests run first by default. The Swift app and the MCP server implement the
# same file format in two languages, and the suites check they still agree —
# shipping a build that drifted from the server is the failure mode worth
# spending twenty seconds to avoid. SKIP_TESTS=1 to bypass.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ToDo"
APP_DIR="${APP_NAME}.app"

if [ "${SKIP_TESTS:-0}" != "1" ]; then
    echo "==> Running Swift tests…"
    swift test

    if [ -d "mcp-server/node_modules" ] && command -v npm >/dev/null 2>&1; then
        echo "==> Running MCP server tests…"
        (cd mcp-server && npm test --silent)
    else
        echo "==> Skipping MCP server tests (run 'npm install' in mcp-server/ to enable)"
    fi
fi

echo "==> Building release binary…"
swift build -c release

echo "==> Assembling ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp ".build/release/ToDoApp" "$APP_DIR/Contents/MacOS/ToDoApp"
cp "Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
mkdir -p "Tasks"

echo "==> Ad-hoc signing so macOS will run it…"
codesign --force --sign - "$APP_DIR"

echo "==> Done. Launch with: open \"$APP_DIR\""
