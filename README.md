# Loupe

A native macOS screenshot tool (a CleanShot X–style replacement). Menu bar app.

**Compatibility:** macOS 14 Sonoma, 15 Sequoia and 26 Tahoe. Release builds are universal
(Apple Silicon + Intel). The deployment target is 14.0, so the compiler rejects any API newer than
that unless it's behind an `#available` check.

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

For "Launch at login", copy the app to `/Applications` first (`cp -R build/Loupe.app /Applications/`)
so the login item doesn't point at the build folder.

## Features

| Shortcut | Action |
| --- | --- |
| ⌥⇧4 | Capture area — drag and release to capture |
| ⌥⇧5 | Capture area (adjust) — drag, then move/resize with handles, press Return or double-click to capture |
| ⌥⇧3 | Capture the display under the mouse |
| ⌥⇧6 | Capture the previous area again (fresh pixels) |
| ⌥⇧7 | Self-timer: pick an area or window, then capture after a countdown |
| — | Fullscreen with timer (assign a shortcut in Settings) |

Shortcuts are customizable in Settings (click a shortcut, press a new combo; Delete removes it).

- Click a window instead of dragging to capture just that window (transparent corners, works even if it's partly covered). In adjust mode, a click turns the window into an adjustable selection.
- The screen is frozen while you select. A magnifier shows the pixels under the cursor; the size label shows pixel dimensions. ⇧ = square, arrows nudge, Esc / right-click cancels.
- After capture a thumbnail appears bottom-left: Copy, Save, Edit, Show in Finder, drag it into other apps, or double-click to edit.
- Markup: arrow, line, rectangle, ellipse, pen, highlighter, text, numbered counters, blur, pixelate. Select (V) to move, double-click text to edit, ⌫ deletes, arrows nudge, ⇧ constrains. Single-key tool shortcuts (A, L, R, O, P, H, T, N, B, X; C = crop).
- Editor: crop (with aspect presets), rotate, flip, exposure, brightness, contrast, saturation, vibrance, hue, warmth; undo/redo; Copy (⌘C), Save (⌘S), Save As (⇧⌘S).
- Background: gradient presets, solid color, custom image (e.g. a macOS wallpaper) or transparent, with padding, corner radius, shadow blur/opacity/offset and canvas aspect (Auto, 1:1, 4:3, 16:9). The last-used look is remembered.
- Capture History (menu bar → Capture History…): recent captures; double-click to edit, right-click to copy, pin, reveal or remove.
- Pin to screen (from the thumbnail, editor or history): always-on-top floating image; drag to move, scroll/pinch to resize, right-click for opacity, Esc closes.
- Settings: launch at login, self-timer length, custom shortcuts, save folder, PNG/JPEG, auto-save, copy to clipboard, thumbnail, sound.

## Icon

`swift scripts/make-icon.swift Resources/AppIcon.icns` regenerates the app icon (a fold-out loupe).
The menu bar glyph is drawn in code (`StatusBarIcon.swift`). On macOS 26, if the menu bar icon is
missing, check System Settings → Menu Bar, and remember that icons can hide behind the notch.
`Loupe --debug-status-item` prints where the icon was placed.

## Layout

- `Sources/Loupe/App` — app delegate, status menu, shortcuts, main menu, settings
- `Sources/Loupe/Capture` — ScreenCaptureKit snapshots, selection overlay
- `Sources/Loupe/QuickAccess` — post-capture thumbnails
- `Sources/Loupe/Editor` — editor model (Core Image pipeline), views, crop overlay, annotations, backdrop
- `Sources/Loupe/History`, `Sources/Loupe/Pin` — capture history and pinned screenshots
- `Sources/Loupe/Support` — hot keys, preferences, image export

Note: SwiftUI's `@State` is a macro whose plugin ships only with Xcode, so views use `State(...)`
directly to build with just the Command Line Tools.
