# Loupe

A native macOS screenshot tool (a CleanShot X–style replacement). Menu bar app, macOS 14+.

## Build & run

```bash
scripts/build-app.sh
open build/Loupe.app
```

The first capture asks for **Screen Recording** permission (System Settings → Privacy & Security →
Screen & System Audio Recording). After granting it, quit and relaunch Loupe.

The build script signs with a stable identity (`$LOUPE_SIGN_IDENTITY`, else the first codesigning
identity in your keychain) so the permission survives rebuilds. With ad-hoc signing macOS asks again
after every build.

`Loupe.app/Contents/MacOS/Loupe --edit image.png` opens an image directly in the editor.

## Features

| Shortcut | Action |
| --- | --- |
| ⌥⇧4 | Capture area — drag and release to capture |
| ⌥⇧5 | Capture area (adjust) — drag, then move/resize with handles, press Return or double-click to capture |
| ⌥⇧3 | Capture the display under the mouse |

- The screen is frozen while you select. A magnifier shows the pixels under the cursor; the size label shows pixel dimensions. ⇧ = square, arrows nudge, Esc / right-click cancels.
- After capture a thumbnail appears bottom-left: Copy, Save, Edit, Show in Finder, drag it into other apps, or double-click to edit.
- Editor: crop (with aspect presets), rotate, flip, exposure, brightness, contrast, saturation, vibrance, hue, warmth; undo/redo; Copy (⌘C), Save (⌘S), Save As (⇧⌘S).
- Background: gradient presets, solid color, custom image (e.g. a macOS wallpaper) or transparent, with padding, corner radius, shadow blur/opacity/offset and canvas aspect (Auto, 1:1, 4:3, 16:9). The last-used look is remembered.
- Settings: save folder, PNG/JPEG, auto-save, copy to clipboard, thumbnail, sound.

## Layout

- `Sources/Loupe/App` — app delegate, status menu, shortcuts, main menu, settings
- `Sources/Loupe/Capture` — ScreenCaptureKit snapshots, selection overlay
- `Sources/Loupe/QuickAccess` — post-capture thumbnails
- `Sources/Loupe/Editor` — editor model (Core Image pipeline), views, crop overlay
- `Sources/Loupe/Support` — hot keys, preferences, image export

Note: SwiftUI's `@State` is a macro whose plugin ships only with Xcode, so views use `State(...)`
directly to build with just the Command Line Tools.
