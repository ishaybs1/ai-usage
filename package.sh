#!/bin/bash
# Package AIUsageTracker as a distributable .app + zip.
#
# Updates are via git pull + ./install.sh (see setup.sh). This zip is for manual download only.
#
# Usage: ./package.sh [signing-identity]     ("-" forces ad-hoc)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.4}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AIUsageNotary}"

SIGN_ID="${1:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
                | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
    if [ -z "$SIGN_ID" ]; then SIGN_ID="-"; fi
fi

STAGE="dist"
APP="$STAGE/AIUsageTracker.app"
ZIP="$STAGE/AIUsageTracker-${VERSION}.zip"

echo "[1/4] Building release..."
swift build -c release

echo "[2/4] Assembling $APP ..."
rm -rf dist
mkdir -p "$APP/Contents/MacOS"

cp .build/release/AIUsageTracker "$APP/Contents/MacOS/AIUsageTracker"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AIUsageTracker</string>
  <key>CFBundleExecutable</key><string>AIUsageTracker</string>
  <key>CFBundleIdentifier</key><string>com.aiusagetracker.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

cp INSTALL.txt "$STAGE/INSTALL.txt" 2>/dev/null || true

echo "[3/4] Signing ($SIGN_ID) ..."
codesign --force --deep --options runtime --sign "$SIGN_ID" "$APP"

echo "[4/4] Zipping ($ZIP)..."
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Done: $(pwd)/$APP"
ls -lh "$ZIP"
