#!/bin/bash
# Build and upload a release zip to GitHub Enterprise (manual download — updates via git).
#
#   gh auth login -h github.jfrog.info
#   VERSION=1.3 ./publish.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.4}"
GITHUB_REPO="${GITHUB_REPO:-ishaybs/ai-usage}"
GITHUB_HOST="${GITHUB_HOST:-github.jfrog.info}"
export GH_HOST="$GITHUB_HOST"
RELEASE_TAG="v${VERSION}"
RELEASE_BASE="https://${GITHUB_HOST}/${GITHUB_REPO}/releases/download/${RELEASE_TAG}"

echo "== Packaging v${VERSION} =="
VERSION="$VERSION" ./package.sh

ZIP="dist/AIUsageTracker-${VERSION}.zip"
[ -f "$ZIP" ] || { echo "ERROR: expected $ZIP"; exit 1; }

if [ "${SKIP_GH_RELEASE:-}" = "1" ]; then
    echo "SKIP_GH_RELEASE=1 — skipped upload."
else
    command -v gh >/dev/null || { echo "ERROR: install gh && gh auth login -h $GITHUB_HOST"; exit 1; }
    gh auth status -h "$GITHUB_HOST" >/dev/null || { echo "ERROR: gh auth login -h $GITHUB_HOST"; exit 1; }
    echo "== Publishing ${RELEASE_TAG} =="
    if gh release view "$RELEASE_TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
        gh release upload "$RELEASE_TAG" "$ZIP" --repo "$GITHUB_REPO" --clobber
    else
        gh release create "$RELEASE_TAG" "$ZIP" --repo "$GITHUB_REPO" \
            --title "AIUsageTracker ${VERSION}" \
            --notes "Manual install zip. Teammates should prefer: git clone + ./setup.sh --auto-update"
    fi
fi

echo "Published: ${RELEASE_BASE}/AIUsageTracker-${VERSION}.zip"
