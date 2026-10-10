#!/bin/zsh
# Builds a distributable dist/Loupe-<version>.dmg.
#
# Usage: scripts/release.sh <version>        e.g. scripts/release.sh 0.2.0
#
# With a "Developer ID Application" certificate in the keychain, the app and
# DMG are signed with it (hardened runtime), notarized by Apple, and stapled,
# so they open without Gatekeeper warnings on any Mac. One-time setup:
#
#   xcrun notarytool store-credentials loupe-notary \
#     --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
#
# Override the profile name with $LOUPE_NOTARY_PROFILE.
#
# Without a Developer ID certificate the DMG is still built, but recipients
# must approve it once on first launch (see INSTALL.md).
#
# Also generates dist/site/: the landing page (site/index.html filled in with
# this release's version) plus the DMG, ready to upload to any static host. To host the
# DMG elsewhere (e.g. a GitHub Release asset), set $LOUPE_DOWNLOAD_URL and the
# DMG is left out of the folder.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/release.sh <version>" >&2
  exit 1
fi
ROOT="${0:A:h:h}"
cd "$ROOT"
PROFILE="${LOUPE_NOTARY_PROFILE:-loupe-notary}"

LOUPE_VERSION="$VERSION" scripts/build-app.sh release

APP="$ROOT/build/Loupe.app"
IDENTITY="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ {print $2; exit}')"
if [[ "$IDENTITY" == Developer\ ID\ Application* ]]; then
  SIGNED=1
else
  SIGNED=0
fi

# DMG with the app and an Applications shortcut for drag-to-install.
DIST="$ROOT/dist"
DMG="$DIST/Loupe-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$DIST"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Loupe $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

NOTARIZED=0
if (( SIGNED )); then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  echo "Submitting to Apple for notarization (usually a few minutes)…"
  if xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait; then
    xcrun stapler staple "$DMG"
    NOTARIZED=1
    spctl --assess --type open --context context:primary-signature -v "$DMG"
    STATUS="signed with Developer ID, notarized and stapled"
  else
    STATUS="signed with Developer ID but NOT notarized (check the notarytool output and the '$PROFILE' profile)"
  fi
else
  STATUS="NOT notarized (no Developer ID certificate) — recipients must approve it on first launch, see INSTALL.md"
fi

# Landing page.
SITE="$DIST/site"
rm -rf "$SITE"
mkdir -p "$SITE"
sips -Z 512 "$ROOT/Resources/AppIcon.png" --out "$SITE/icon.png" >/dev/null
if [[ -n "${LOUPE_DOWNLOAD_URL:-}" ]]; then
  export PAGE_URL="$LOUPE_DOWNLOAD_URL"
else
  cp "$DMG" "$SITE/"
  export PAGE_URL="Loupe-$VERSION.dmg"
fi
export PAGE_VERSION="$VERSION"
if (( NOTARIZED )); then
  export PAGE_GK_OPEN=""
  export PAGE_GK_INTRO="Loupe is notarized by Apple, so you shouldn’t see this. If you do:"
else
  export PAGE_GK_OPEN=" open"
  export PAGE_GK_INTRO="This build isn’t notarized by Apple yet, so macOS asks you to confirm it the first time:"
fi
perl -pe '
  s/\{\{DOWNLOAD_URL\}\}/$ENV{PAGE_URL}/g; s/\{\{VERSION\}\}/$ENV{PAGE_VERSION}/g;
  s/\{\{GATEKEEPER_OPEN\}\}/$ENV{PAGE_GK_OPEN}/g; s/\{\{GATEKEEPER_INTRO\}\}/$ENV{PAGE_GK_INTRO}/g;
' "$ROOT/site/index.html" > "$SITE/index.html"

echo
echo "Built $DMG"
echo "  version: $VERSION ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"
echo "  status:  $STATUS"
echo "  sha256:  $(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "  size:    $(du -h "$DMG" | awk '{print $1}')"
echo "  site:    $SITE (upload this folder; download link → $PAGE_URL)"
