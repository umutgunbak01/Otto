#!/usr/bin/env bash
# Build, zip, and publish an Otto release to GitHub.
#
# Usage:   scripts/release.sh <version>
# Example: scripts/release.sh v1.0.0
#
# Requires:
#   - Xcode command-line tools (xcodebuild)
#   - GitHub CLI (gh) authenticated: gh auth login
#
# What this does:
#   1. Archives Otto in Release configuration via xcodebuild.
#   2. Zips the resulting Otto.app with `ditto` (preserves bundle metadata).
#   3. Creates a GitHub release with the zip attached and auto-generated notes.
#
# If you have a Developer ID and want notarization, use Xcode's
# Organizer -> Direct Distribution flow instead and skip this script's
# archive step (manually drop the notarized Otto.app next to this script
# and re-run from the `ditto` line).

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <version>  (e.g. $0 v1.0.0)" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$(mktemp -d -t otto-release)"
ARCHIVE_PATH="$BUILD_DIR/Otto.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/Otto.app"
ZIP_PATH="$BUILD_DIR/Otto.app.zip"

echo "==> Archiving Otto ($VERSION)"
xcodebuild \
  -project Otto.xcodeproj \
  -scheme Otto \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  archive

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: archive succeeded but $APP_PATH not found" >&2
  exit 1
fi

echo "==> Zipping $APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
echo "    -> $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"

echo "==> Creating GitHub release $VERSION"
gh release create "$VERSION" "$ZIP_PATH" \
  --title "Otto $VERSION" \
  --generate-notes

echo
echo "Done. Release: $(gh release view "$VERSION" --json url -q .url)"
