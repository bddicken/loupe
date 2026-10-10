#!/bin/zsh
# Builds Loupe.app into ./build.
#
# Usage: scripts/build-app.sh [debug|release]   (default: release)
#
# Signing: macOS ties the Screen Recording permission to the app's code
# signature. Ad-hoc signatures change on every build, which makes macOS ask
# for permission again after each rebuild. To avoid that, the script signs
# with a stable identity: $LOUPE_SIGN_IDENTITY if set, otherwise the first
# valid codesigning identity in the keychain, otherwise ad-hoc.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="${0:A:h:h}"
cd "$ROOT"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/Loupe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Loupe" "$APP/Contents/MacOS/Loupe"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

IDENTITY="${LOUPE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/^ +[0-9]+\)/ {print $2; exit}')"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
fi

codesign --force --sign "$IDENTITY" --identifier dev.loupe.Loupe "$APP"
echo "Built $APP (signed with: $IDENTITY)"
