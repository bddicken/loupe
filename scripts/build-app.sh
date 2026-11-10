#!/bin/zsh
# Builds Loupe.app into ./build.
#
# Usage: scripts/build-app.sh [debug|release]   (default: release)
#
# Signing: macOS ties the Screen Recording permission to the app's code
# signature. Ad-hoc signatures change on every build, which makes macOS ask
# for permission again after each rebuild. To avoid that, the script signs
# with a stable identity: $LOUPE_SIGN_IDENTITY if set, otherwise a
# "Developer ID Application" identity, otherwise "Loupe Code Signing" (see
# scripts/create-signing-cert.sh), otherwise the first valid codesigning
# identity in the keychain, otherwise ad-hoc. Developer ID builds get the
# hardened runtime and a secure timestamp, which notarization requires.
#
# $LOUPE_VERSION (e.g. 1.2.0) stamps CFBundleShortVersionString; the build
# number is the git commit count.
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
# A Loupe still running from build/Loupe.app breaks once its bundle is replaced: macOS
# can't check the code signature of an executable that's gone from disk, so Sparkle
# can't launch its installer ("An error occurred while launching the installer").
# Quit it before replacing the bundle and reopen it once the new one is built.
RUNNING_PIDS=(${(f)"$(ps -axo pid=,comm= | awk -v exe="$APP/Contents/MacOS/Loupe" '{pid=$1; sub(/^ *[0-9]+ /, "")} $0 == exe {print pid}')"})
if (( ${#RUNNING_PIDS} )); then
  echo "Quitting the Loupe running from $APP (it reopens after the build)…"
  kill -TERM "${RUNNING_PIDS[@]}" 2>/dev/null || true
  for _ in {1..50}; do
    kill -0 "${RUNNING_PIDS[@]}" 2>/dev/null || break
    sleep 0.2
  done
  kill -0 "${RUNNING_PIDS[@]}" 2>/dev/null && { echo "build-app: Loupe (pid ${RUNNING_PIDS[*]}) didn't quit; quit it and try again" >&2; exit 1; }
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Loupe" "$APP/Contents/MacOS/Loupe"
# Sparkle (auto-updates). Loupe isn't sandboxed, so Sparkle's optional XPC services aren't needed.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

PLIST="$APP/Contents/Info.plist"
if [[ -n "${LOUPE_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $LOUPE_VERSION" "$PLIST"
fi
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"

IDENTITY="${LOUPE_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ && !found {print $2; found=1}')"
fi
if [[ -z "$IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Loupe Code Signing"'; then
  IDENTITY="Loupe Code Signing"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/^ +[0-9]+\)/ && !found {print $2; found=1}')"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
fi

SIGN_FLAGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" == *"Developer ID Application"* ]]; then
  SIGN_FLAGS+=(--options runtime --timestamp)
fi
# Sign inside-out: Sparkle's helpers, then the framework, then the app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE"
# The entitlements let the hardened runtime use the microphone (for screen recordings).
codesign "${SIGN_FLAGS[@]}" --identifier dev.loupe.Loupe --entitlements "$ROOT/Resources/Loupe.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (signed with: $IDENTITY)"
if (( ${#RUNNING_PIDS} )); then
  open "$APP"
  echo "Reopened Loupe."
fi
