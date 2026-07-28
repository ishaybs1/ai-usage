#!/bin/bash
# One-time teammate setup: clone from GHE, build, install, optional daily auto-update.
#
# Uses your normal git/SSO credentials — no GitHub PAT in the app.
#
#   curl -fsSL .../setup.sh | bash                    # or download and run
#   ./setup.sh                                        # clone to ~/Developer/ai-usage
#   ./setup.sh --auto-update                          # + launchd git pull daily
#   AIUSAGE_DIR=~/code/ai-usage ./setup.sh
#
# Prerequisites (once): xcode-select --install
set -euo pipefail

REPO_URL="${AIUSAGE_REPO_URL:-git@github.jfrog.info:ishaybs/ai-usage.git}"
INSTALL_DIR="${AIUSAGE_DIR:-$HOME/Developer/ai-usage}"
AUTO_UPDATE=false

for arg in "$@"; do
    case "$arg" in
        --auto-update) AUTO_UPDATE=true ;;
        -h|--help)
            sed -n '2,14p' "$0"
            exit 0
            ;;
    esac
done

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Installing Swift toolchain (one-time)..."
    xcode-select --install
    echo "Re-run ./setup.sh after the Xcode tools finish installing."
    exit 1
fi

if [[ ! -d "$INSTALL_DIR/.git" ]]; then
    echo "Cloning $REPO_URL -> $INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    git clone "$REPO_URL" "$INSTALL_DIR"
else
    echo "Repo already exists at $INSTALL_DIR — pulling latest..."
    git -C "$INSTALL_DIR" pull --ff-only
fi

cd "$INSTALL_DIR"
./install.sh

if $AUTO_UPDATE; then
    ./install.sh --enable-auto-update
    echo ""
    echo "Auto-update enabled (daily git pull + rebuild)."
else
    echo ""
    echo "To enable daily auto-update:  cd $INSTALL_DIR && ./install.sh --enable-auto-update"
fi

echo ""
echo "AIUsageTracker is in your menu bar (🧠)."
echo "Manual update anytime:  cd $INSTALL_DIR && git pull && ./install.sh"
