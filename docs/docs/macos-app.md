# Kintsuki.app (macOS)

A SwiftUI / Metal frontend for `libkintsuki`. Targets the macOS 26 Liquid
Glass icon set; built from `app/` via XcodeGen + xcodebuild.

## Keyboard shortcuts

| Shortcut          | Action                                    |
|-------------------|-------------------------------------------|
| ⌘O                | Open ROM…                                 |
| ⌘R                | Soft reset                                |
| ⌘⇧R               | Reload ROM from disk (cold boot)          |
| ⌘⌥R               | Hot-reload — capture state, swap ROM, restore |
| ⌘P                | Pause / Resume                            |
| ⌘.                | Step one frame                            |
| ⌘← / ⌘⇧←          | Rewind 1 frame / 1 second                 |
| ⌘I                | Show / hide inspector                     |
| ⌘S                | Save state                                |
| ⌘⇧S               | Manage save states…                       |

ESC (no modifiers) toggles pause without going through the menu.

## Halt overlay

When the CPU executes STP, the run loop short-circuits and an overlay
appears over the framebuffer:

- `CPU STP @ BB:AAAA`
- Resolved backtrace (`#N BB:AAAA in name+0xNN  (file.s:line)`) when a
  `.adbg` is loaded next to the ROM.
- Inline **Reset** (⌘R) and **Reload from Disk** (⌘⇧R) buttons.
- **Copy** button drops the report on `NSPasteboard` for paste-into-
  bug-tracker.
- All text is selectable (cmd-C copies the highlighted region).

The app reads `<rom>.adbg` automatically on `loadROM` if it exists.

## Rewind UI

Hold ⌘← to scrub backwards (one frame per key-repeat); ⌘⇧← steps one
second. While held, forward emulation pauses so consecutive scrubs
don't oscillate. Status pill shows `↶ N.Ns` retained.

## Inspector

⌘I toggles a sidebar with CPU registers, PPU snapshot (BG modes, tilemap
bases, HDMA channels), framebuffer dimensions, and breakpoints. Add
breakpoints by kind (Exec / Read / Write) + address range.

## Build

```bash
cd app
xcodegen
xcodebuild -project Kintsuki.xcodeproj -scheme Kintsuki -configuration Release build
```

`xcodegen` regenerates the project from `project.yml`. The build script
phase under `Kintsuki` builds `libkintsuki.dylib` via cmake/ninja, copies
it into `Vendor/`, runs `install_name_tool -id @rpath/libkintsuki.dylib`,
re-signs, and embeds the dylib + ares System pak into the app bundle.

`Release` is set up for `instruments`: hardened runtime is off (the
locally-built ad-hoc dylib trips Team-ID validation otherwise),
`DEBUG_INFORMATION_FORMAT=dwarf-with-dsym`, and a post-build `dsymutil`
step generates `libkintsuki.dylib.dSYM` so call trees symbolicate.
