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

# Release builds are universal (Apple Silicon + Intel); macOS 14–26 all still run on Intel Macs.
ARCH_FLAGS=()
if [[ "$CONFIG" == "release" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"

APP="$ROOT/build/Loupe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Loupe" "$APP/Contents/MacOS/Loupe"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${LOUPE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/^ +[0-9]+\)/ {print $2; exit}')"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
fi

codesign --force --sign "$IDENTITY" --identifier dev.loupe.Loupe "$APP"
echo "Built $APP (signed with: $IDENTITY)"
