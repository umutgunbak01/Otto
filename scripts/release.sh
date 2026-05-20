#!/usr/bin/env bash
# Publish an Otto release after you've notarized + stapled it via Xcode.
#
# Workflow:
#   1. In Xcode: Product → Archive
#   2. In Organizer: Distribute App → Developer ID → Upload (or Export).
#      Wait for the green "Ready to Distribute" / notarization-complete state,
#      then Export to a folder. You end up with a stapled Otto.app on disk.
#   3. Run this script with the version tag and the path to that Otto.app.
#
# Usage:   scripts/release.sh <version> <path/to/Otto.app>
# Example: scripts/release.sh v1.0.1 ~/Desktop/Otto-1.0.1/Otto.app
#
# What this does:
#   - Verifies the bundle is stapled (notarization ticket attached).
#   - Zips with ditto so bundle metadata survives.
#   - EdDSA-signs the zip via Sparkle's sign_update (private key from Keychain).
#   - Prepends a new <item> to docs/appcast.xml.
#   - Creates the GitHub release with the zip attached.
#   - Commits + pushes docs/appcast.xml so GitHub Pages serves the new feed.
#
# Requires:
#   - GitHub CLI (gh) authenticated: gh auth login
#   - Sparkle's EdDSA private key in the Keychain (created once via generate_keys)
#   - Otto.xcodeproj resolved at least once so sign_update is in DerivedData

set -euo pipefail

VERSION_TAG="${1:-}"
APP_PATH="${2:-}"
if [[ -z "$VERSION_TAG" || -z "$APP_PATH" ]]; then
  echo "usage: $0 <version> <path/to/Otto.app>" >&2
  echo "  e.g. $0 v1.0.1 ~/Desktop/Otto-1.0.1/Otto.app" >&2
  exit 1
fi

# Strip leading "v" — Sparkle wants the bare marketing version in the feed.
VERSION="${VERSION_TAG#v}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: not a directory: $APP_PATH" >&2
  exit 1
fi

# ---------- sanity-check the bundle is notarized + stapled ----------
echo "==> Validating notarization staple"
xcrun stapler validate "$APP_PATH"

echo "==> Verifying Gatekeeper acceptance"
spctl --assess --type execute -vv "$APP_PATH"

# ---------- locate Sparkle's sign_update helper ----------
SIGN_UPDATE="$(find ~/Library/Developer/Xcode/DerivedData -type f -name sign_update 2>/dev/null \
  | grep -m1 Sparkle || true)"
if [[ -z "$SIGN_UPDATE" ]]; then
  echo "error: sign_update not found. Open Otto.xcodeproj in Xcode (or run" >&2
  echo "       'xcodebuild -resolvePackageDependencies ...') to populate" >&2
  echo "       DerivedData with the Sparkle SPM checkout, then re-run." >&2
  exit 1
fi
echo "==> sign_update: $SIGN_UPDATE"

# ---------- zip ----------
BUILD_DIR="$(mktemp -d -t otto-release)"
ZIP_PATH="$BUILD_DIR/Otto.app.zip"

echo "==> Zipping $APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
ZIP_SIZE="$(stat -f%z "$ZIP_PATH")"
echo "    -> $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1), $ZIP_SIZE bytes)"

# ---------- EdDSA sign update payload ----------
echo "==> EdDSA-signing zip with Sparkle's sign_update"
SIGN_OUTPUT="$("$SIGN_UPDATE" "$ZIP_PATH")"
echo "    $SIGN_OUTPUT"
ED_SIGNATURE="$(echo "$SIGN_OUTPUT" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')"
if [[ -z "$ED_SIGNATURE" ]]; then
  echo "error: could not parse EdDSA signature from sign_update output" >&2
  exit 1
fi

# ---------- update appcast.xml ----------
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
echo "==> Build number: $BUILD_NUMBER"

echo "==> Updating docs/appcast.xml"
python3 scripts/update_appcast.py \
  --version "$VERSION" \
  --build "$BUILD_NUMBER" \
  --tag "$VERSION_TAG" \
  --zip-size "$ZIP_SIZE" \
  --ed-signature "$ED_SIGNATURE"

# ---------- publish release ----------
echo "==> Creating GitHub release $VERSION_TAG"
gh release create "$VERSION_TAG" "$ZIP_PATH" \
  --title "Otto $VERSION_TAG" \
  --generate-notes

# ---------- commit + push appcast ----------
echo "==> Committing and pushing updated appcast"
git add docs/appcast.xml
git commit -m "appcast: $VERSION_TAG"
git push

echo
echo "Done. Release: $(gh release view "$VERSION_TAG" --json url -q .url)"
echo "Feed:    https://umutgunbak01.github.io/Otto/appcast.xml"
