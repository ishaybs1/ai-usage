#!/bin/bash
# Pull latest from git and rebuild if changed. Used by launchd and manual updates.
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/AIUsageTracker"
LOG="$HOME/Library/Logs/AIUsageTracker/source-update.log"
LOCK="$SUPPORT/update.lock"
REPO="${AIUSAGE_DIR:-$(dirname "$0")}"

[[ -f "$SUPPORT/repo-path" ]] && REPO="$(cat "$SUPPORT/repo-path")"
mkdir -p "$(dirname "$LOG")" "$SUPPORT"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

# Skip if another install/update is already running.
exec 9>"$LOCK"
if ! flock -n 9; then
    log "skipped — update already in progress"
    exit 0
fi

[[ -d "$REPO/.git" ]] || { log "ERROR: not a git repo: $REPO"; exit 1; }

cd "$REPO"
BRANCH="${AIUSAGE_BRANCH:-main}"

if ! git fetch origin "$BRANCH" >>"$LOG" 2>&1; then
    log "git fetch failed (VPN / GHE login?)"
    exit 0
fi

LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse "origin/$BRANCH")"

if [[ "$LOCAL" == "$REMOTE" ]]; then
    log "up to date ($LOCAL)"
    exit 0
fi

log "updating $LOCAL -> $REMOTE"
git pull --ff-only origin "$BRANCH" >>"$LOG" 2>&1
NO_OPEN=1 "$REPO/install.sh" >>"$LOG" 2>&1
VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/AIUsageTracker.app/Contents/Info.plist 2>/dev/null || echo "?")
log "done — v$VER"
