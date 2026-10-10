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
#
# Sparkle: the DMG is signed with the EdDSA key in your keychain (created with
# `generate_keys --account loupe`) and dist/site/appcast.xml is written, so
# installed copies update themselves after scripts/deploy-site.sh. Release
# notes come from release-notes/<version>.html.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/release.sh <version>" >&2
  exit 1
fi
ROOT="${0:A:h:h}"
cd "$ROOT"
PROFILE="${LOUPE_NOTARY_PROFILE:-loupe-notary}"
SITE_URL="${LOUPE_SITE_URL:-https://loupe.pics}"
SPARKLE_VERSION="2.10.0"
SPARKLE_BIN="$ROOT/.build/sparkle-$SPARKLE_VERSION/bin"

if [[ ! -f "$ROOT/release-notes/$VERSION.html" ]]; then
  echo "Missing release-notes/$VERSION.html (shown in the update window)." >&2
  exit 1
fi
if [[ ! -x "$SPARKLE_BIN/sign_update" ]]; then
  echo "Downloading Sparkle $SPARKLE_VERSION tools…"
  mkdir -p "$ROOT/.build/sparkle-$SPARKLE_VERSION"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$ROOT/.build/sparkle-$SPARKLE_VERSION"
fi

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

# Sparkle signature (after stapling, which modifies the DMG).
SPARKLE_SIGNATURE="$("$SPARKLE_BIN/sign_update" --account loupe "$DMG")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

# Landing page.
SITE="$DIST/site"
# Keep the Vercel project link (dist/site/.vercel) across regenerations.
VERCEL_LINK="$(mktemp -d)"
[[ -d "$SITE/.vercel" ]] && mv "$SITE/.vercel" "$VERCEL_LINK/"
rm -rf "$SITE"
mkdir -p "$SITE"
[[ -d "$VERCEL_LINK/.vercel" ]] && mv "$VERCEL_LINK/.vercel" "$SITE/"
rmdir "$VERCEL_LINK" 2>/dev/null || true
sips -Z 512 "$ROOT/Resources/AppIcon.png" --out "$SITE/icon.png" >/dev/null
cp "$ROOT/site/og-image.png" "$ROOT/site/editor.png" "$SITE/"
if [[ -n "${LOUPE_DOWNLOAD_URL:-}" ]]; then
  export PAGE_URL="$LOUPE_DOWNLOAD_URL"
  export DOWNLOAD_PATH="$LOUPE_DOWNLOAD_URL"
else
  cp "$DMG" "$SITE/"
  export PAGE_URL="Loupe-$VERSION.dmg"
  export DOWNLOAD_PATH="/Loupe-$VERSION.dmg"
fi
# Sparkle update feed.
if [[ "$PAGE_URL" == http* ]]; then DMG_URL="$PAGE_URL"; else DMG_URL="$SITE_URL/$PAGE_URL"; fi
cat > "$SITE/appcast.xml" <<APPCAST
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Loupe</title>
    <link>$SITE_URL/appcast.xml</link>
    <item>
      <title>Loupe $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
$(cat "$ROOT/release-notes/$VERSION.html")
      ]]></description>
      <enclosure url="$DMG_URL" type="application/octet-stream" $SPARKLE_SIGNATURE />
    </item>
  </channel>
</rss>
APPCAST

# Vercel config: DMG download headers and a stable /download link to this release.
perl -pe 's/\{\{DOWNLOAD_PATH\}\}/$ENV{DOWNLOAD_PATH}/g' "$ROOT/site/vercel.json" > "$SITE/vercel.json"
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
echo "  version: $VERSION ($BUILD_NUMBER)"
echo "  status:  $STATUS"
echo "  sha256:  $(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "  size:    $(du -h "$DMG" | awk '{print $1}')"
echo "  site:    $SITE (upload this folder; download link → $PAGE_URL)"
echo "  updates: $SITE_URL/appcast.xml (signed with your Sparkle key)"
