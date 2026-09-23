# Design tokens

Final values for HANDOFF §7.1, used by the app and the widget through `WidgetCore`
(`Packages/WidgetCore/Sources/WidgetCore/Design/Palette.swift`, `Theme.swift`, `Typography.swift`).
Every text/background pair below is asserted by `DesignTokenContrastTests` (WidgetCore,
`swift test`), which computes WCAG 2.x contrast ratios from the hex values; the ratios here come from
the same formula.

## Colours

| Token | Light | Dark | Use |
|---|---|---|---|
| background | `#F4F1EA` | `#161513` | every screen, widget container |
| ink | `#1B1A17` | `#EDE8DE` | text, chart line, rules on section tops |
| muted | `#6B665C` | `#A39C8E` | secondary text, labels, axes, unselected tabs |
| rule | `#D9D3C7` | `#2E2B26` | hairlines (decorative, never text) |
| rangeBand | `#E8E2D5` | `#24211C` | 70–180 band fill (decorative, never text) |
| veryLow (< 54, LOW) | `#7A2418` | `#E0786A` | range bin, hero numeral, "LOW" marker, critical banner bar |
| low (54–69) | `#B3412E` | `#E89080` | range bin, hero numeral; also the **alert** token (banner titles, stale labels, errors) |
| high (181–250) | **`#B07B26`** | `#E0B060` | range bin, hero numeral, warning banner bar |
| veryHigh (> 250, HIGH) | **`#754D0F`** | `#D49A40` | range bin, hero numeral, "HIGH" marker |

Accent (user-selectable in Settings → Appearance; `AccentChoice`). Dark values are the "lightened
equivalents, same hues" §7.1 asks for: HLS lightness raised, hue and saturation unchanged. The ink
accent follows the ink token in dark mode.

| Accent | Light | Dark |
|---|---|---|
| forest (default) | `#2F6B4F` | `#4BAA7E` |
| rust | `#9A4A26` | `#D57B53` |
| navy | `#2D4E7A` | `#6A92C8` |
| ink | `#1B1A17` | `#EDE8DE` |

### Changes from the §7.1 table

- **light `high` `#C58A2B` → `#B07B26`.** The table value is 2.64:1 on the background, below the
  3:1 minimum for large text and graphics; the hero numeral (132 pt) and the range-bar segment use
  it. `#B07B26` is the same hue, 3.26:1.
- **light `veryHigh` `#8A5A12` → `#754D0F`.** Darkened so high and very high stay as distinct from
  each other as in the table (≈ 2.0:1 between them; they sit side by side in the range bar).
- Dark values from §7.1 all pass unchanged; the dark accents are new (the table left them open).
- Tune on device (§7.1 "proposed; tune on device"): any change must keep `DesignTokenContrastTests` green.

## Contrast (WCAG AA)

Body text needs 4.5:1; text ≥ 24 pt (18.66 pt bold) and graphical marks need 3:1. "Need" is the
threshold the test applies to that pair. Opacity-reduced content is deliberate and exempt: stale
widget numbers are drawn at 40 % so an old number never looks current (the "STALE · 12 min ago"
label next to them is full contrast), the two earlier days in the 3 D overlay are 60 % context lines,
and disabled buttons are 35 %.

| Mode | Foreground | On | Ratio | Need | Where |
|---|---|---|---|---|---|
| light | ink `#1B1A17` | background `#F4F1EA` | 15.43:1 | 4.5 | all body text |
| light | muted `#6B665C` | background `#F4F1EA` | 5.06:1 | 4.5 | secondary text, labels, axes |
| light | low (alert) `#B3412E` | background `#F4F1EA` | 5.01:1 | 4.5 | banner titles, stale labels, field errors |
| light | veryLow `#7A2418` | background `#F4F1EA` | 8.89:1 | 4.5 | "LOW" chart markers (8–10 pt) |
| light | veryHigh `#754D0F` | background `#F4F1EA` | 6.59:1 | 4.5 | "HIGH" chart markers (8–10 pt) |
| light | accent.forest `#2F6B4F` | background `#F4F1EA` | 5.58:1 | 4.5 | "+4 pts vs prior 14d", links, arrows |
| light | accent.rust `#9A4A26` | background `#F4F1EA` | 5.51:1 | 4.5 | "+4 pts vs prior 14d", links, arrows |
| light | accent.navy `#2D4E7A` | background `#F4F1EA` | 7.50:1 | 4.5 | "+4 pts vs prior 14d", links, arrows |
| light | accent.ink `#1B1A17` | background `#F4F1EA` | 15.43:1 | 4.5 | "+4 pts vs prior 14d", links, arrows |
| light | background `#F4F1EA` | accent.forest `#2F6B4F` | 5.58:1 | 4.5 | primary button text |
| light | background `#F4F1EA` | accent.rust `#9A4A26` | 5.51:1 | 4.5 | primary button text |
| light | background `#F4F1EA` | accent.navy `#2D4E7A` | 7.50:1 | 4.5 | primary button text |
| light | background `#F4F1EA` | accent.ink `#1B1A17` | 15.43:1 | 4.5 | primary button text |
| light | high `#B07B26` | background `#F4F1EA` | 3.26:1 | 3 | hero numeral 181–250 (≥ 24 pt), range-bar segment |
| light | low `#B3412E` | background `#F4F1EA` | 5.01:1 | 3 | hero numeral 54–69, range-bar segment |
| light | veryLow `#7A2418` | background `#F4F1EA` | 8.89:1 | 3 | hero numeral < 54 / LOW, segment |
| light | veryHigh `#754D0F` | background `#F4F1EA` | 6.59:1 | 3 | hero numeral > 250 / HIGH, segment |
| light | ink `#1B1A17` | rangeBand `#E8E2D5` | 13.48:1 | 3 | chart line over the target band |
| light | accent.forest `#2F6B4F` | rangeBand `#E8E2D5` | 4.88:1 | 3 | current-reading dot over the band |
| light | accent.rust `#9A4A26` | rangeBand `#E8E2D5` | 4.81:1 | 3 | current-reading dot over the band |
| light | accent.navy `#2D4E7A` | rangeBand `#E8E2D5` | 6.55:1 | 3 | current-reading dot over the band |
| light | accent.ink `#1B1A17` | rangeBand `#E8E2D5` | 13.48:1 | 3 | current-reading dot over the band |
| dark | ink `#EDE8DE` | background `#161513` | 14.94:1 | 4.5 | all body text |
| dark | muted `#A39C8E` | background `#161513` | 6.69:1 | 4.5 | secondary text, labels, axes |
| dark | low (alert) `#E89080` | background `#161513` | 7.59:1 | 4.5 | banner titles, stale labels, field errors |
| dark | veryLow `#E0786A` | background `#161513` | 6.14:1 | 4.5 | "LOW" chart markers (8–10 pt) |
| dark | veryHigh `#D49A40` | background `#161513` | 7.38:1 | 4.5 | "HIGH" chart markers (8–10 pt) |
| dark | accent.forest `#4BAA7E` | background `#161513` | 6.39:1 | 4.5 | "+4 pts vs prior 14d", links, arrows |
| dark | accent.rust `#D57B53` | background `#161513` | 5.90:1 | 4.5 | "+4 pts vs prior 14d", links, arrows |
| dark | accent.navy `#6A92C8` | background `#161513` | 5.70:1 | 4.5 | "+4 pts vs prior 14d", links, arrows |
| dark | accent.ink `#EDE8DE` | background `#161513` | 14.94:1 | 4.5 | "+4 pts vs prior 14d", links, arrows |
| dark | background `#161513` | accent.forest `#4BAA7E` | 6.39:1 | 4.5 | primary button text |
| dark | background `#161513` | accent.rust `#D57B53` | 5.90:1 | 4.5 | primary button text |
| dark | background `#161513` | accent.navy `#6A92C8` | 5.70:1 | 4.5 | primary button text |
| dark | background `#161513` | accent.ink `#EDE8DE` | 14.94:1 | 4.5 | primary button text |
| dark | high `#E0B060` | background `#161513` | 9.17:1 | 3 | hero numeral 181–250 (≥ 24 pt), range-bar segment |
| dark | low `#E89080` | background `#161513` | 7.59:1 | 3 | hero numeral 54–69, range-bar segment |
| dark | veryLow `#E0786A` | background `#161513` | 6.14:1 | 3 | hero numeral < 54 / LOW, segment |
| dark | veryHigh `#D49A40` | background `#161513` | 7.38:1 | 3 | hero numeral > 250 / HIGH, segment |
| dark | ink `#EDE8DE` | rangeBand `#24211C` | 13.14:1 | 3 | chart line over the target band |
| dark | accent.forest `#4BAA7E` | rangeBand `#24211C` | 5.61:1 | 3 | current-reading dot over the band |
| dark | accent.rust `#D57B53` | rangeBand `#24211C` | 5.18:1 | 3 | current-reading dot over the band |
| dark | accent.navy `#6A92C8` | rangeBand `#24211C` | 5.01:1 | 3 | current-reading dot over the band |
| dark | accent.ink `#EDE8DE` | rangeBand `#24211C` | 13.14:1 | 3 | current-reading dot over the band |

## Type (§7.2)

| Role | Font (PostScript name) | Size | Dynamic Type |
|---|---|---|---|
| Current reading | Newsreader 72 pt Light (`Newsreader72pt-Light`) | 132 pt (104 pt for LOW/HIGH) | fixed; `minimumScaleFactor(0.4)`, one line, never truncates |
| Trends hero | Newsreader 72 pt Light | 104 pt, "%" 48 pt | fixed; scales down to fit |
| Titles, figures | Newsreader 16 pt Regular (`Newsreader16pt-Regular`) | 20–36 pt | scales relative to `.title` (screen titles); fixed in fixed layouts (Today so far, widgets) |
| Wordmark "glucose" | Newsreader 16 pt Italic (`Newsreader16pt-Italic`) | 22 pt | relative to `.title2` |
| UI text | IBM Plex Sans 400/500/600 (`IBMPlexSans`, `-Medm`, `-SmBld`) | 12–15 pt | relative to `.body` |
| Labels, timestamps, axes | IBM Plex Mono 400/500 (`IBMPlexMono`, `-Medm`) | 10–12 pt, uppercase labels tracked +0.08 em | relative to `.caption`; chart axes and widgets fixed |

Sources, versions and licences: `Resources/Fonts/licenses/README.md`. The 72 pt optical size of
Newsreader is used for ≥ 100 pt numerals, the 16 pt optical size for everything else.

## Layout

- Side margins 20 pt, section spacing 18 pt (mockup values).
- Every tap target ≥ 44 × 44 pt (tab bar items 50 pt tall).
- Appearance: follows the system by default; Settings → Appearance forces Light or Dark
  (`preferredColorScheme`). Widgets always follow the system.
