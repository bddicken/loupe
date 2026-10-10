#!/bin/zsh
# Builds, publishes and deploys a Loupe release.
#
# Usage: scripts/release.sh <version> [--no-publish]     e.g. scripts/release.sh 1.0.1
#
# 1. Checks you're on an up-to-date, clean main (so the build matches GitHub).
# 2. Builds the universal app and dist/Loupe-<version>.dmg, signed with your
#    code signing identity. With a "Developer ID Application" certificate it's
#    also notarized and stapled (one-time setup below).
# 3. Signs the DMG with your Sparkle key (`generate_keys --account loupe`).
# 4. Publishes GitHub Release v<version> with the DMG attached.
# 5. Writes web/ (the loupe.pics site: page, appcast.xml, vercel.json) linking
#    to that DMG, then commits and pushes. Vercel deploys web/ on push, and
#    installed copies pick up the update from loupe.pics/appcast.xml.
#
# --no-publish stops after step 3 and writes web/ without committing, for a
# local look (preview with `python3 -m http.server --directory web`).
#
# Release notes (shown in the update window and on GitHub) come from
# release-notes/<version>.html.
#
# Notarization setup (needs a paid Apple Developer account):
#   xcrun notarytool store-credentials loupe-notary \
#     --apple-id <you@example.com> --team-id <TEAMID>
# Override the profile name with $LOUPE_NOTARY_PROFILE.
set -euo pipefail

VERSION="${1:-}"
PUBLISH=1
[[ "${2:-}" == "--no-publish" ]] && PUBLISH=0
if [[ -z "$VERSION" || "$VERSION" == --* ]]; then
  echo "usage: scripts/release.sh <version> [--no-publish]" >&2
  exit 1
fi
ROOT="${0:A:h:h}"
cd "$ROOT"
PROFILE="${LOUPE_NOTARY_PROFILE:-loupe-notary}"
SITE_URL="${LOUPE_SITE_URL:-https://loupe.pics}"
REPO="${LOUPE_GITHUB_REPO:-bddicken/loupe}"
TAG="v$VERSION"
DMG_URL="https://github.com/$REPO/releases/download/$TAG/Loupe-$VERSION.dmg"
SPARKLE_VERSION="2.10.0"
SPARKLE_BIN="$ROOT/.build/sparkle-$SPARKLE_VERSION/bin"
NOTES="$ROOT/release-notes/$VERSION.html"

# --- Preflight -------------------------------------------------------------
fail() { echo "release: $*" >&2; exit 1; }
[[ -f "$NOTES" ]] || fail "missing release-notes/$VERSION.html (shown in the update window)"
if (( PUBLISH )); then
  [[ "$(git branch --show-current)" == "main" ]] || fail "switch to main first"
  [[ -z "$(git status --porcelain)" ]] || fail "commit or stash your changes first (the build must match GitHub)"
  git fetch -q origin
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main isn't in sync with origin/main; pull (or push) first"
  ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "tag $TAG already exists"
  gh auth status >/dev/null 2>&1 || fail "log in to GitHub CLI first (gh auth login)"
fi
if [[ ! -x "$SPARKLE_BIN/sign_update" ]]; then
  echo "Downloading Sparkle $SPARKLE_VERSION tools…"
  mkdir -p "$ROOT/.build/sparkle-$SPARKLE_VERSION"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar -xJ -C "$ROOT/.build/sparkle-$SPARKLE_VERSION"
fi

# --- Build -----------------------------------------------------------------
LOUPE_VERSION="$VERSION" scripts/build-app.sh release

APP="$ROOT/build/Loupe.app"
IDENTITY="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ {print $2; exit}')"
SIGNED=0
[[ "$IDENTITY" == Developer\ ID\ Application* ]] && SIGNED=1

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
  STATUS="NOT notarized (no Developer ID certificate); recipients approve it on first launch, see INSTALL.md"
fi

# Sparkle signature (after stapling, which modifies the DMG).
SPARKLE_SIGNATURE="$("$SPARKLE_BIN/sign_update" --account loupe "$DMG")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

# --- Site (web/) -----------------------------------------------------------
WEB="$ROOT/web"
rm -rf "$WEB"
mkdir -p "$WEB"
sips -Z 512 "$ROOT/Resources/AppIcon.png" --out "$WEB/icon.png" >/dev/null
cp "$ROOT/site/og-image.png" "$ROOT/site/editor.png" "$ROOT/site/robots.txt" "$WEB/"

export PAGE_URL="$DMG_URL" PAGE_VERSION="$VERSION"
if (( NOTARIZED )); then
  export PAGE_GK_OPEN="" PAGE_GK_INTRO="Loupe is notarized by Apple, so you shouldn’t see this. If you do:"
else
  export PAGE_GK_OPEN=" open" PAGE_GK_INTRO="This build isn’t notarized by Apple yet, so macOS asks you to confirm it the first time:"
fi
perl -pe '
  s/\{\{DOWNLOAD_URL\}\}/$ENV{PAGE_URL}/g; s/\{\{VERSION\}\}/$ENV{PAGE_VERSION}/g;
  s/\{\{GATEKEEPER_OPEN\}\}/$ENV{PAGE_GK_OPEN}/g; s/\{\{GATEKEEPER_INTRO\}\}/$ENV{PAGE_GK_INTRO}/g;
' "$ROOT/site/index.html" > "$WEB/index.html"
# Vercel config: a stable /download link to this release; only deploy when web/ changes.
DOWNLOAD_PATH="$DMG_URL" perl -pe 's/\{\{DOWNLOAD_PATH\}\}/$ENV{DOWNLOAD_PATH}/g' "$ROOT/site/vercel.json" > "$WEB/vercel.json"

# Sparkle update feed.
cat > "$WEB/appcast.xml" <<APPCAST
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
$(cat "$NOTES")
      ]]></description>
      <enclosure url="$DMG_URL" type="application/octet-stream" $SPARKLE_SIGNATURE />
    </item>
  </channel>
</rss>
APPCAST

echo
echo "Built $DMG"
echo "  version: $VERSION ($BUILD_NUMBER)"
echo "  status:  $STATUS"
echo "  sha256:  $(shasum -a 256 "$DMG" | awk '{print $1}')"

if (( ! PUBLISH )); then
  echo "  web/ written but not committed (--no-publish). Nothing was published."
  exit 0
fi

# --- Publish ---------------------------------------------------------------
# The GitHub Release (and its tag) first, so the DMG exists before the site links to it.
gh release create "$TAG" "$DMG" --repo "$REPO" --title "Loupe $VERSION" --notes-file "$NOTES" >/dev/null
echo "  GitHub:  https://github.com/$REPO/releases/tag/$TAG"
git fetch -q --tags origin

git add -A web
git commit -q -m "Release $VERSION"
git push -q origin main
echo "  site:    pushed web/; Vercel deploys $SITE_URL (updates: $SITE_URL/appcast.xml)"
