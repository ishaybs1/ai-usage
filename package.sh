#!/bin/bash
# Package AIUsageTracker as a distributable .app + zip (with INSTALL.txt) for teammates.
#
# Signing is automatic:
#   * Developer ID cert in your keychain  -> Developer ID signed (hardened runtime)
#         + notarized & stapled IF a notary profile exists  -> teammates DOUBLE-CLICK.
#   * No cert (or override with "-")      -> ad-hoc signed   -> teammates RIGHT-CLICK > Open once.
#
# One-time Developer ID setup (needs an Apple Developer account):
#   1. Create a "Developer ID Application" cert in Xcode > Settings > Accounts, or developer.apple.com.
#   2. Store notary creds once:
#        xcrun notarytool store-credentials AIUsageNotary \
#          --apple-id you@company.com --team-id TEAMID --password <app-specific-password>
#   3. ./package.sh          (auto-detects the cert + profile; notarizes; staples)
#
# Usage: ./package.sh [signing-identity]     (identity optional; "-" forces ad-hoc)
set -euo pipefail
cd "$(dirname "$0")"

NOTARY_PROFILE="${NOTARY_PROFILE:-AIUsageNotary}"

# Resolve signing identity: explicit arg > auto-detected Developer ID > ad-hoc.
# `|| true` so a no-match grep doesn't trip `set -e` when there's no Developer ID cert.
SIGN_ID="${1:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
                | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
    if [ -z "$SIGN_ID" ]; then SIGN_ID="-"; fi
fi

STAGE="dist/AIUsageTracker"                 # folder that gets zipped (app + README)
APP="$STAGE/AIUsageTracker.app"

echo "[1/5] Building release binary..."
swift build -c release

echo "[2/5] Assembling $APP ..."
rm -rf dist
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AIUsageTracker "$APP/Contents/MacOS/AIUsageTracker"
cp INSTALL.txt "$STAGE/INSTALL.txt"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AIUsageTracker</string>
  <key>CFBundleExecutable</key><string>AIUsageTracker</string>
  <key>CFBundleIdentifier</key><string>com.aiusagetracker.app</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>1.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

echo "[3/5] Signing ($SIGN_ID) ..."
codesign --force --deep --options runtime --sign "$SIGN_ID" "$APP"

echo "[4/5] Notarizing..."
if [ "$SIGN_ID" = "-" ]; then
    echo "  skipped: ad-hoc signed (no Developer ID cert). Teammates right-click > Open once."
elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    ditto -c -k --keepParent "$APP" dist/_notarize.zip
    xcrun notarytool submit dist/_notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f dist/_notarize.zip
    echo "  notarized + stapled -> teammates can double-click."
else
    echo "  Developer ID signed but NOT notarized (no notary profile '$NOTARY_PROFILE')."
    echo "  Set one up (see header) for a double-click install."
fi

echo "[5/5] Zipping..."
( cd dist && ditto -c -k --keepParent AIUsageTracker AIUsageTracker.zip )

echo "Done -> $(pwd)/dist/AIUsageTracker.zip"
ls -lh dist/AIUsageTracker.zip
