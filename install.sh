#!/bin/bash
# Build from source, install to /Applications, enable auto-start at login, and launch.
#
#   First install:  ./setup.sh   (or ./install.sh after git clone)
#   Update later:   git pull && ./install.sh
#   Auto-update:    ./install.sh --enable-auto-update   (daily git pull + rebuild)
#   Uninstall:      ./install.sh --uninstall
#
# Building locally means NO Gatekeeper/quarantine prompt (the binary isn't downloaded), and no
# Apple Developer account needed. Requires the Swift toolchain: `xcode-select --install` once.
set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/AIUsageTracker.app"
NAME="AIUsageTracker"
SUPPORT="$HOME/Library/Application Support/AIUsageTracker"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.aiusagetracker.source-update.plist"
LAUNCH_LABEL="com.aiusagetracker.source-update"
LOGIN_AGENT="$HOME/Library/LaunchAgents/com.aiusagetracker.login.plist"
LOGIN_LABEL="com.aiusagetracker.login"
REPO_DIR="$(pwd)"

save_repo_path() {
    mkdir -p "$SUPPORT"
    echo "$REPO_DIR" > "$SUPPORT/repo-path"
}

disable_auto_update() {
    launchctl bootout "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null || true
    rm -f "$LAUNCH_AGENT"
}

disable_login() {
    launchctl bootout "gui/$(id -u)/$LOGIN_LABEL" 2>/dev/null || true
    rm -f "$LOGIN_AGENT"
}

# Auto-start via LaunchAgent (no System Events / Automation permission prompt).
enable_login() {
    mkdir -p "$(dirname "$LOGIN_AGENT")"
    cat > "$LOGIN_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LOGIN_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-ga</string>
    <string>${APP}</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)/$LOGIN_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$LOGIN_AGENT"
}

enable_auto_update() {
    save_repo_path
    mkdir -p "$(dirname "$LAUNCH_AGENT")"
    cat > "$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LAUNCH_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${REPO_DIR}/update-from-source.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>9</integer>
    <key>Minute</key><integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>${HOME}/Library/Logs/AIUsageTracker/source-update.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME}/Library/Logs/AIUsageTracker/source-update.log</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)/$LAUNCH_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT"
    echo "Auto-update enabled — checks git daily at 9:00 AM."
    echo "Log: ~/Library/Logs/AIUsageTracker/source-update.log"
}

case "${1:-}" in
    --uninstall)
        killall "$NAME" 2>/dev/null || true
        disable_auto_update
        disable_login
        rm -rf "$APP"
        echo "Uninstalled."
        exit 0
        ;;
    --enable-auto-update)
        enable_auto_update
        exit 0
        ;;
    --disable-auto-update)
        disable_auto_update
        echo "Auto-update disabled."
        exit 0
        ;;
    --update-now)
        exec ./update-from-source.sh
        ;;
esac

command -v swift >/dev/null || { echo "Swift toolchain not found. Run: xcode-select --install"; exit 1; }

save_repo_path

echo "[1/4] Building release (from source)..."
./package.sh >/tmp/aiu-install.log 2>&1 || {
    echo "Build failed — see /tmp/aiu-install.log"
    tail -20 /tmp/aiu-install.log
    exit 1
}

echo "[2/4] Installing to $APP ..."
killall "$NAME" 2>/dev/null || true
sleep 1
rm -rf "$APP"
cp -R "dist/AIUsageTracker.app" "$APP"

echo "[3/4] Enabling auto-start at login..."
enable_login

echo "[4/4] Launching..."
if [[ "${NO_OPEN:-}" != "1" ]]; then
    open "$APP"
fi

VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "?")
echo "Done - AIUsageTracker v$VER is running (🧠 in the menu bar) and will auto-start at login."
echo "Update: git pull && ./install.sh   (or ./install.sh --enable-auto-update for daily checks)"
