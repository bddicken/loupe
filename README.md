<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Loupe icon">
</p>

<h1 align="center">Loupe</h1>

<p align="center">A fast, native screenshot tool for macOS: capture, mark up, and polish screenshots in seconds.</p>

## Features

- **Capture** an area, a single window (click it), or the full screen. You can adjust the selection before
  capturing, re-capture the previous area, or use a self-timer for menus.
- **Mark up** with arrows, lines, shapes, text, highlighter, numbered steps, blur and pixelate.
- **Polish** with gradient or image backgrounds, padding, rounded corners and shadows. Crop, rotate, and
  adjust exposure, contrast, saturation and hue.
- **Share**: a quick-access thumbnail after every capture (copy, save, edit, drag), capture history, and
  screenshots pinned above other windows.

| Shortcut | Action |
| --- | --- |
| <kbd>⌥⇧4</kbd> | Capture area (or click a window) |
| <kbd>⌥⇧5</kbd> | Capture area, adjust, then capture |
| <kbd>⌥⇧3</kbd> | Capture fullscreen |
| <kbd>⌥⇧6</kbd> | Capture previous area |
| <kbd>⌥⇧7</kbd> | Capture with self-timer |

All shortcuts can be changed in Settings. Requires macOS 14 Sonoma or later (Apple Silicon or Intel).

## Install

Download from **[loupe.pics](https://loupe.pics)** and drag Loupe into Applications. See [INSTALL.md](INSTALL.md) for first-launch
and Screen Recording permission steps.

## Build from source

Needs only the Xcode Command Line Tools.

```bash
scripts/build-app.sh          # builds build/Loupe.app (universal)
open build/Loupe.app
```

`Loupe --edit image.png` opens an image straight in the editor.

## Release

```bash
scripts/release.sh 0.2.0     # build dist/Loupe-0.2.0.dmg and dist/site/
scripts/deploy-site.sh       # deploy dist/site/ to https://loupe.pics (Vercel)
```

Builds `dist/Loupe-0.2.0.dmg` and `dist/site/`, a ready-to-upload landing page with the DMG. If a
Developer ID certificate and a `loupe-notary` notarytool profile are available, the DMG is also signed,
notarized and stapled. See the comments in [scripts/release.sh](scripts/release.sh).
`swift scripts/make-icon.swift Resources/AppIcon.icns` regenerates the icon, and
`swift scripts/make-og-image.swift` regenerates the social preview image (`site/og-image.png`).

## Project layout

| Path | Contents |
| --- | --- |
| `Sources/Loupe/App` | App delegate, menu bar item, settings |
| `Sources/Loupe/Capture` | ScreenCaptureKit capture, selection overlay, self-timer |
| `Sources/Loupe/Editor` | Editor, Core Image pipeline, annotations, backgrounds |
| `Sources/Loupe/QuickAccess`, `History`, `Pin` | Post-capture thumbnail, history, pinned screenshots |
| `Sources/Loupe/Support` | Hot keys, shortcuts, preferences, export |
| `site/` | Landing page template |

## License

[MIT](LICENSE)
