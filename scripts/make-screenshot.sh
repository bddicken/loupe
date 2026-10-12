#!/bin/zsh
# Renders site/editor.png and site/editor.webp (the landing page screenshot) from the real editor UI.
# Usage: scripts/make-screenshot.sh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"

OUT="$ROOT/.build/make-screenshot"
mkdir -p "$OUT"
# Everything except the app shell (App/), which pulls in Sparkle and @main.
SOURCES=(${(f)"$(find Sources/Loupe -name '*.swift' -not -path '*/App/*')"})
swiftc -parse-as-library -O -o "$OUT/make-screenshot" scripts/screenshot/main.swift "${SOURCES[@]}" \
  -framework ScreenCaptureKit -framework Carbon
"$OUT/make-screenshot" "$ROOT/site/editor.png"

# Keep the page light: 1800px is plenty for a 1040pt-wide slot at 2x. The page
# serves the WebP (needs `brew install webp`) and falls back to the PNG.
sips -Z 1800 "$ROOT/site/editor.png" >/dev/null
cwebp -quiet -q 82 -m 6 "$ROOT/site/editor.png" -o "$ROOT/site/editor.webp"
