# Installing Loupe

Loupe needs macOS 14 Sonoma or later and runs on both Apple Silicon and Intel Macs.

1. Download `Loupe-<version>.dmg`, open it, and drag **Loupe** into **Applications**.
2. Open Loupe from Applications. Its icon (a small loupe) appears in the menu bar.
3. The first time you take a screenshot, macOS asks for **Screen Recording** permission. Turn Loupe on in
   System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Loupe.

## "Apple could not verify Loupe…"

Builds that aren't notarized by Apple show this the first time you open them. To allow Loupe once:

- **macOS 15 and 26:** open Loupe, dismiss the warning, then go to System Settings → Privacy & Security,
  scroll down to the message about Loupe, and click **Open Anyway**.
- **macOS 14:** right-click Loupe in Applications, choose **Open**, then click **Open**.

Or, from Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Loupe.app
```

## Updating

Quit Loupe, then replace it in Applications with the new version. If screenshots stop working after an update,
turn Loupe off and on again in the Screen Recording settings.

## Default shortcuts

| Shortcut | Action |
| --- | --- |
| ⌥⇧4 | Capture area (drag, or click a window) |
| ⌥⇧5 | Capture area, then adjust before capturing |
| ⌥⇧3 | Capture fullscreen |
| ⌥⇧6 | Capture previous area |
| ⌥⇧7 | Capture with self-timer |

All of these can be changed in Loupe → Settings.
