#!/bin/zsh
# Checks the editor's mouse behaviour (selecting, moving, resizing and drawing with
# each tool, the cursor, the toolbar while zoomed in) by driving the real editor UI
# with synthetic clicks. Its window is never visible and it doesn't touch the pointer.
# Usage: scripts/test-editor.sh [-v]     (-v lists every check)
# scripts/release.sh runs it before building.
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"

OUT="$ROOT/.build/test-editor"
mkdir -p "$OUT"
# Everything except the app shell (App/), which pulls in Sparkle and @main.
SOURCES=(${(f)"$(find Sources/Loupe -name '*.swift' -not -path '*/App/*')"})
swiftc -parse-as-library -Onone -suppress-warnings -o "$OUT/test-editor" scripts/test-editor/main.swift "${SOURCES[@]}" \
  -framework ScreenCaptureKit -framework Carbon
"$OUT/test-editor" "$@"
