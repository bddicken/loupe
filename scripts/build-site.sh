#!/bin/zsh
# Writes the loupe.pics site into web/ from site/ for a release: every page
# (with the shared top bar and footer, version and download link filled in), a
# changelog built from release-notes/, sitemap.xml, images and vercel.json.
# web/appcast.xml, written by scripts/release.sh, is left alone.
#
# Usage: scripts/build-site.sh <version> [--notarized]     e.g. scripts/build-site.sh 1.0.5
#
# scripts/release.sh runs this. Run it by hand to change the site between
# releases (pass the current version), then commit web/; Vercel deploys on push.
# Preview with `python3 -m http.server --directory web`.
#
# Pages are site/**/*.html, served without the .html (vercel.json has
# cleanUrls). Files starting with _ are includes: {{TOPBAR}} and {{FOOTER}}.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" || "$VERSION" == --* ]]; then
  echo "usage: scripts/build-site.sh <version> [--notarized]" >&2
  exit 1
fi
NOTARIZED=0
[[ "${2:-}" == "--notarized" ]] && NOTARIZED=1
ROOT="${0:A:h:h}"
cd "$ROOT"
SITE="$ROOT/site"
WEB="$ROOT/web"
SITE_URL="${LOUPE_SITE_URL:-https://loupe.pics}"
REPO="${LOUPE_GITHUB_REPO:-bddicken/loupe}"
DMG_URL="https://github.com/$REPO/releases/download/v$VERSION/Loupe-$VERSION.dmg"
TODAY="$(date +%F)"
autoload -Uz is-at-least

# A fresh web/, keeping the update feed.
mkdir -p "$WEB"
find "$WEB" -mindepth 1 ! -name appcast.xml -delete
sips -Z 512 "$ROOT/Resources/AppIcon.png" --out "$WEB/icon.png" >/dev/null
cp "$SITE/og-image.png" "$SITE/editor.png" "$SITE/editor.webp" "$SITE/robots.txt" "$SITE/style.css" "$WEB/"

# Changelog: one entry per release-notes/<version>.html up to this version,
# newest first, dated by its v<version> tag (or today for the one being released).
CHANGELOG=""
for notes in "$ROOT"/release-notes/*.html(nOn); do
  v="${notes:t:r}"
  is-at-least "$v" "$VERSION" || continue
  date="$(git for-each-ref --format='%(creatordate:short)' "refs/tags/v$v")"
  [[ -z "$date" && "$v" == "$VERSION" ]] && date="$TODAY"
  time=""
  [[ -n "$date" ]] && time="<time datetime=\"$date\">$(LC_ALL=C date -j -f %F "$date" '+%B %-d, %Y')</time>"
  # The notes start with <h2>Loupe x.y.z</h2>; link it and put the date under it.
  body="$(TIME="$time" V="$v" perl -0pe 's{<h2>(.*?)</h2>}{<h2><a href="#v$ENV{V}">$1</a></h2>\n$ENV{TIME}}' "$notes")"
  CHANGELOG+="    <section class=\"release\" id=\"v$v\">
$body
    </section>
"
done

# Pages.
export PAGE_URL="$DMG_URL" PAGE_VERSION="$VERSION" PAGE_CHANGELOG="$CHANGELOG"
export PAGE_TOPBAR="$(<"$SITE/_topbar.html")" PAGE_FOOTER="$(<"$SITE/_footer.html")"
if (( NOTARIZED )); then
  export PAGE_GK_OPEN="" PAGE_GK_INTRO="Loupe is notarized by Apple, so you shouldn’t see this. If you do:"
else
  export PAGE_GK_OPEN=" open" PAGE_GK_INTRO="This build isn’t notarized by Apple yet, so macOS asks you to confirm it the first time:"
fi
PAGES=()
for page in "$SITE"/**/*.html(.); do
  rel="${page#$SITE/}"
  [[ "${rel:t}" == _* ]] && continue
  PAGES+=("$rel")
  mkdir -p "$WEB/${rel:h}"
  # Includes first, so the placeholders inside them are filled in too.
  perl -0pe '
    s/\{\{TOPBAR\}\}/$ENV{PAGE_TOPBAR}/g; s/\{\{FOOTER\}\}/$ENV{PAGE_FOOTER}/g; s/\{\{CHANGELOG\}\}/$ENV{PAGE_CHANGELOG}/g;
    s/\{\{DOWNLOAD_URL\}\}/$ENV{PAGE_URL}/g; s/\{\{VERSION\}\}/$ENV{PAGE_VERSION}/g;
    s/\{\{GATEKEEPER_OPEN\}\}/$ENV{PAGE_GK_OPEN}/g; s/\{\{GATEKEEPER_INTRO\}\}/$ENV{PAGE_GK_INTRO}/g;
  ' "$page" > "$WEB/$rel"
  if grep -q '{{' "$WEB/$rel"; then
    echo "build-site: unfilled placeholder in $rel: $(grep -o '{{[A-Z_]*}}' "$WEB/$rel" | sort -u | tr '\n' ' ')" >&2
    exit 1
  fi
done

# Sitemap, home page first. A page's lastmod is when its own source last changed,
# so search engines can trust it; the home page and changelog also change with
# each release (version, download link, notes). Shared includes don't count.
RELEASE_DATE="$(git for-each-ref --format='%(creatordate:short)' "refs/tags/v$VERSION")"
lastmod() {
  local d
  if [[ -n "$(git status --porcelain -- "$1")" ]]; then d="$TODAY"; else d="$(git log -1 --format=%cs -- "$1")"; fi
  d="${d:-$TODAY}"
  if [[ "${2:-}" == release ]]; then
    local r="${RELEASE_DATE:-$TODAY}"
    [[ "$r" > "$d" ]] && d="$r"
  fi
  echo "$d"
}
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">'
  for rel in index.html "${(@)PAGES:#index.html}"; do
    case "$rel" in
      index.html)
        echo "  <url>
    <loc>$SITE_URL/</loc>
    <lastmod>$(lastmod "site/$rel" release)</lastmod>
    <image:image><image:loc>$SITE_URL/editor.png</image:loc></image:image>
  </url>" ;;
      changelog.html) echo "  <url><loc>$SITE_URL/${rel%.html}</loc><lastmod>$(lastmod "site/$rel" release)</lastmod></url>" ;;
      *) echo "  <url><loc>$SITE_URL/${rel%.html}</loc><lastmod>$(lastmod "site/$rel")</lastmod></url>" ;;
    esac
  done
  echo '</urlset>'
} > "$WEB/sitemap.xml"

# Vercel config: a stable /download link to this release.
DOWNLOAD_PATH="$DMG_URL" perl -pe 's/\{\{DOWNLOAD_PATH\}\}/$ENV{DOWNLOAD_PATH}/g' "$SITE/vercel.json" > "$WEB/vercel.json"

echo "Wrote web/ for Loupe $VERSION: ${PAGES[*]}"
