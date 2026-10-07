# App icon

`generate_app_icon.swift` draws the app icon from code (PROGRESS.md D52): the Now screen's green
trend arrow with "mg/dL" under it, in the light theme. The icon shows **no glucose number**
(safety rule S1), only the arrow and the unit.

```sh
swift tools/icon/generate_app_icon.swift            # (re)write the icon set and the previews
swift tools/icon/generate_app_icon.swift --check    # verify the committed icons match, exit 1 if not
```

macOS only (CoreGraphics, CoreText, ImageIO); no packages, no network. Runs from any directory.

## Design sources

| Element | Source | In the icon |
|---|---|---|
| Arrow | `TrendArrowShape` (`Packages/WidgetCore/Sources/WidgetCore/Views/TrendArrowView.swift`): 24 × 24 grid, shaft (2, 12) → (22, 12), open chevron (15, 5) → (22, 12) → (15, 19), round caps and joins | Same geometry, pointing right. The Now hero draws it at size 32 with a 2 pt line (1.5 grid units); the icon uses 2.75 units so it stays legible at 60 × 60 px. |
| "mg/dL" | `GlucoseText.unit`, set like the hero caption: `Typography.label` = IBM Plex Mono Regular (`Resources/Fonts/IBMPlexMono-Regular.ttf`), colour ink | Same font, registered from the bundled file with `CTFontManagerRegisterFontsForURL`, centred under the arrow. |
| Colours | `docs/design-tokens.md` | Light: background `#F4F1EA`, accent.forest `#2F6B4F`, ink `#1B1A17`. Dark: `#161513`, `#4BAA7E`, `#EDE8DE`. |

## Output

| File | What |
|---|---|
| `App/Assets.xcassets/AppIcon.appiconset/AppIcon.png` | 1024 × 1024, sRGB, opaque (no alpha channel, as the App Store requires), square corners (iOS applies its own mask). The single universal 1024 icon; Xcode derives every smaller size. |
| `…/AppIcon-Dark.png` | iOS 18+ dark appearance: the dark tokens, opaque. |
| `…/AppIcon-Tinted.png` | iOS 18+ tinted appearance: a white (grayscale) glyph on transparent, which the system tints (Apple HIG). |
| `docs/screenshots/app-icon-candidates/` | Every candidate at 1024, 180, 120 and 60 px (smaller sizes shrunk from the 1024 image and corner-masked like the home screen), the chosen design's dark and tinted variants, and `overview.png` with everything side by side on a light and a dark wallpaper. |

iOS 17 ignores the dark and tinted entries and uses `AppIcon.png`.

## Candidates

The three compositions are the `designs` table in the script; `chosenName` picks the one that becomes
the icon. To try another, change the parameters, re-run, and look at the 60 px previews first:
that is where a design fails.

- **A** (chosen by Michael) — the hero's own stack: arrow and "mg/dL" share a left edge, the text a little wider than
  the arrow (as on the Now screen), 2-unit line.
- **B** — centred, 2.75-unit line, Plex Mono Regular a little narrower than the arrow.
  The arrow clearly dominates, the line holds up at 60 px, and the text is the hero's exact font.
- **C** — centred, heavy 3.5-unit line with larger Plex Mono Medium; the boldest at 60 px, but
  heavier than anything on the Now screen.

## Licences

The script is GPL-3.0-or-later like the rest of the repository. IBM Plex Mono is under the SIL Open
Font License 1.1 (credited in `NOTICE.md`; licence text in `Resources/Fonts/licenses/`); the OFL
places no restriction on images rendered with the font.

## Determinism

Fixed geometry, the bundled font, no randomness, no timestamps in the PNGs: re-running produces
identical bytes, and `--check` compares them with the committed icons. Generated on macOS 26.2; a
different macOS release may rasterise or compress slightly differently, in which case `--check`
reports a mismatch and the fix is to re-run the generator and review the new images.
