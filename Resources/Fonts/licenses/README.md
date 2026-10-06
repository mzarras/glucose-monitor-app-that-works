# Bundled fonts

All fonts are licensed under the SIL Open Font License 1.1. The license text ships next to the
fonts in the app and widget bundles (`Newsreader-OFL.txt`, `IBMPlex-OFL.txt`; file names are unique
because `Resources/Fonts` is copied flat into each bundle root, PROGRESS.md D13).

Only the weights the design uses (HANDOFF §7.2) are bundled. The files are byte-for-byte copies of
the upstream release files; SHA-256 below.

| File | PostScript name | Version | Source |
|---|---|---|---|
| `Newsreader72pt-Light.ttf` | `Newsreader72pt-Light` | 1.003 | [productiontype/Newsreader @ 1ece6a8](https://github.com/productiontype/Newsreader/tree/1ece6a8bfe5db1a2b90c76cc1fe5d3b2eed5dcf3/fonts/static/ttf) |
| `Newsreader16pt-Regular.ttf` | `Newsreader16pt-Regular` | 1.003 | same |
| `Newsreader16pt-Italic.ttf` | `Newsreader16pt-Italic` | 1.003 | same |
| `IBMPlexSans-Regular.ttf` | `IBMPlexSans` | 3.005 | [IBM/plex release `@ibm/plex-sans@1.1.0`](https://github.com/IBM/plex/releases/tag/%40ibm%2Fplex-sans%401.1.0), `ibm-plex-sans.zip` → `fonts/complete/ttf/` |
| `IBMPlexSans-Medium.ttf` | `IBMPlexSans-Medm` | 3.005 | same |
| `IBMPlexSans-SemiBold.ttf` | `IBMPlexSans-SmBld` | 3.005 | same |
| `IBMPlexMono-Regular.ttf` | `IBMPlexMono` | 2.005 | [IBM/plex release `@ibm/plex-mono@2.5.0`](https://github.com/IBM/plex/releases/tag/%40ibm%2Fplex-mono%402.5.0), `ibm-plex-mono.zip` → `fonts/complete/ttf/` |
| `IBMPlexMono-Medium.ttf` | `IBMPlexMono-Medm` | 2.005 | same |

Newsreader: `1ece6a8` is the upstream commit Google Fonts pins in
[`google/fonts/ofl/newsreader/upstream_info.md`](https://github.com/google/fonts/blob/main/ofl/newsreader/upstream_info.md);
Google Fonts itself ships only the variable font. The static files used here are identical at the
current upstream `master` (`cfcb4f7`). The 72 pt optical size is used for the display numerals
(≥ 100 pt), the 16 pt optical size for titles and figures (20–36 pt) and the italic wordmark.

License texts:
- `Newsreader-OFL.txt` — `OFL.txt` from productiontype/Newsreader @ 1ece6a8
  ("Copyright 2020 The Newsreader Project Authors").
- `IBMPlex-OFL.txt` — `LICENSE.txt` from the IBM Plex Sans release zip; identical to the one in the
  IBM Plex Mono zip ("Copyright © 2017 IBM Corp. with Reserved Font Name "Plex"").

SHA-256:

```
eef58b76835409ff2ac532750f140b26d2bebd8eff4ffbd5c7d7e05526089f48  Newsreader72pt-Light.ttf
0636887c9f72f77ce188f0b31029be58e65adae5a47e6d2887ad5020c2c75036  Newsreader16pt-Regular.ttf
292646cbb948153511e308fa80def59959746d70114bd0936ba0a7f67a33181d  Newsreader16pt-Italic.ttf
975dcda37d80f038dcd143c22e33ca2d97a0cc5a929aace1c749153b0fe1afa5  IBMPlexSans-Regular.ttf
331c8639d7598b2cde62a911a71db195e30cb655cd6bdf2e324a7e984955f907  IBMPlexSans-Medium.ttf
a20caf8286023a6a7a85e40b1d2a4ae9fc3e3b1f9eda8f4c542dd4986af67bb1  IBMPlexSans-SemiBold.ttf
7c6fbddca4b700be918f5f6183d9bd4464fa427fe435f0b480d77fe2bb8c5a43  IBMPlexMono-Regular.ttf
98fbd727aae340b236955879dabed4d991aac9e8e90b3b2a67ce4a59221cc97c  IBMPlexMono-Medium.ttf
```
