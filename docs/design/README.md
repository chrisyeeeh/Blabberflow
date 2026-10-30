# Blabberflow — design handoff for Claude Code

Drop this folder into the root of the Xcode project (e.g. `docs/design/`) and point Claude Code at it:

> Read docs/design/README.md, SPEC.md and the screenshots, then scaffold the macOS app for milestone v0.1.

## What's here

| Path | What it is |
| --- | --- |
| `SPEC.md` | Product + technical spec (behaviour, states, architecture, frameworks, milestones) |
| `screenshots/*.png` | @2x renders of every screen — the visual source of truth |
| `mockups/*.dc.html` | HTML/CSS source of the mockups — exact sizes, radii, colours, copy |

The HTML is a reference, not code to port. Build everything in native SwiftUI/AppKit with system materials, SF Pro and SF Symbols.

## Build rules for Claude Code

- macOS 26+, Apple Silicon, Swift 6, SwiftUI first; AppKit only where SwiftUI can't (NSPanel, CGEventTap, AXUIElement).
- Menu bar app: `LSUIElement = YES`, `MenuBarExtra` + `Settings` scene. No Dock icon, no main window.
- Distribution is a notarized Developer ID DMG only — **no App Sandbox**. Hardened Runtime on.
- Use system colours and materials (`.glassEffect`, `.regularMaterial`, `Color.accentColor`), never hard-coded hex except the semantic accents below.
- Support Light, Dark, Increase Contrast and Reduce Transparency/Motion.

## Design tokens (from the mockups → SwiftUI)

| Token | Mockup value | SwiftUI |
| --- | --- | --- |
| Pill height | 40 pt, fully rounded | `.frame(height: 40)` in `.glassEffect(.regular, in: .capsule)` |
| Pill idle sliver | 40 × 7 pt | `Capsule().frame(width: 40, height: 7)` |
| Pill position | Centred, 12 pt above the Dock | `NSPanel` at `.statusBar`, `.nonactivatingPanel`, `.canJoinAllSpaces` |
| Pill morph | Dynamic Island–style | `.spring(response: 0.35, dampingFraction: 0.8)` + `matchedGeometryEffect` |
| Waveform | 9 bars, 3 pt wide, 3 pt gap, 6–22 pt tall | Driven by input RMS at 30 fps |
| Listening dot | 22 pt circle, red, mic glyph | `Color.red`, `mic.fill` |
| Rewrite accent | 22 pt circle, purple, sparkle | `Color.purple`, `sparkle` |
| Success | Green check | `checkmark.circle.fill`, `Color.green` |
| Warning | Clipboard glyph, yellow | `doc.on.clipboard`, `Color.yellow` |
| Style chip | 12 pt secondary text after a hairline divider | `.font(.caption)`, `.foregroundStyle(.secondary)` |
| Menu bar icon | 5-bar waveform | `waveform` SF Symbol, filled variant while listening |
| Settings window | 960 × 640, sidebar 220 pt | `NavigationSplitView` + `Form { }.formStyle(.grouped)` |
| Onboarding | 720 × 560, 4 steps, 72 pt app icon | Single window, page dots at bottom left, Back/Continue bottom right |

## Screens

1. `Main.png` — in context: dictating into Mail, pill above the Dock
2. `Pill.png` — all 7 pill states
3. `MenuBar.png` — menu bar extra
4. `SettingsStyles.png` — tone per app category + preview + app overrides
5. `SettingsHistory.png` — local history, heard vs typed
6. `Onboarding.png` — Accessibility permission step
