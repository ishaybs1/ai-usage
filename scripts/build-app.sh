#!/usr/bin/env bash
# Build AIUsageTracker as a real macOS .app bundle (menu-bar agent) without Xcode.
#
# Why a script? Full Xcode isn't required to ship a menu-bar app: `swift build` produces the
# executable, and we wrap it in a minimal .app bundle with an Info.plist that sets LSUIElement
# (so it lives in the menu bar with no Dock icon). Run with: scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root (the package dir)

APP_NAME="AIUsageTracker"
BUNDLE_ID="com.company.aiusagetracker"
CONFIG="${1:-release}"     # release (default) or debug

echo "▶︎ Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
APP_DIR=".build/bundle/${APP_NAME}.app"

echo "▶︎ Assembling ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# App icon (brain) so the Dock icon isn't a blank generic square.
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>AI Usage Tracker</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <!-- Menu-bar agent: no Dock icon. The 🧠 lives only in the top menu bar. -->
    <key>LSUIElement</key>             <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc code signature so macOS is willing to launch it locally.
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || \
    echo "  (codesign skipped — app will still run locally)"

echo "✓ Built ${APP_DIR}"
echo "  Launch with:  open \"${APP_DIR}\""
