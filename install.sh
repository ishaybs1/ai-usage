#!/bin/bash
# Build from source, install to /Applications, enable auto-start at login, and launch.
#
#   First install:  ./install.sh
#   Update later:   git pull && ./install.sh      (rebuilds & replaces in place)
#   Uninstall:      ./install.sh --uninstall
#
# Building locally means NO Gatekeeper/quarantine prompt (the binary isn't downloaded), and no
# Apple Developer account needed. Requires the Swift toolchain: `xcode-select --install` once.
set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/AIUsageTracker.app"
NAME="AIUsageTracker"

if [ "${1:-}" = "--uninstall" ]; then
    killall "$NAME" 2>/dev/null || true
    osascript -e "tell application \"System Events\" to delete (every login item whose name is \"$NAME\")" 2>/dev/null || true
    rm -rf "$APP"
    echo "Uninstalled."
    exit 0
fi

command -v swift >/dev/null || { echo "Swift toolchain not found. Run: xcode-select --install"; exit 1; }

echo "[1/4] Building release (from source)..."
./package.sh >/tmp/aiu-install.log 2>&1 || { echo "Build failed — see /tmp/aiu-install.log"; tail -20 /tmp/aiu-install.log; exit 1; }

echo "[2/4] Installing to $APP ..."
killall "$NAME" 2>/dev/null || true
sleep 1
rm -rf "$APP"
cp -R "dist/$NAME/$NAME.app" "$APP"

echo "[3/4] Enabling auto-start at login..."
osascript -e "tell application \"System Events\" to delete (every login item whose name is \"$NAME\")" 2>/dev/null || true
osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"$APP\", hidden:true, name:\"$NAME\"}" >/dev/null || true

echo "[4/4] Launching..."
open "$APP"

VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
echo "Done - AIUsageTracker v$VER is running (🧠 in the menu bar) and will auto-start at login."
