# Reelbird colours and brand assets

The mark is a robin whose red breast is a record light. Coral is the only accent colour, and it always means "recording", "live" or "the one thing to press".

## Palette

| Token | Hex | Use |
|---|---|---|
| `ink` | `#1A1512` | Dark surfaces of the brand (icon tile, social card, viewer page in dark mode), the bird on light backgrounds, body text on paper |
| `inkRaised` | `#2A2320` | Raised surfaces on ink: cards, the control bar, hover |
| `paper` | `#FFF4E8` | Light surfaces of the brand, the bird on dark backgrounds, text on ink |
| `coral` | `#FF5A36` | The accent: record button, recording state, live badge, primary action, the dot on the "i" |
| `coralDeep` | `#E5432B` | Pressed coral, the dark end of coral gradients |
| `coralLight` | `#FF8256` | The light end of coral gradients only (icon highlight) |
| `coralText` | `#C93A1E` | Coral used as text or links on paper or white (4.7:1 on paper) |
| `mutedOnInk` | `#A69C93` | Secondary text on ink (6.7:1) |
| `mutedOnPaper` | `#6E645C` | Secondary text on paper (5.3:1) |

Contrast (WCAG 2): coral on ink 5.8:1; ink on coral 5.8:1; ink on paper 16.7:1. White text on coral is only 3.1:1, so labels on a coral button are ink, or white at 17 pt semibold and up.

## 70 / 30 / 10

- **70% neutral.** In the app this is the system: window backgrounds, sidebars and materials in light and dark mode. On brand surfaces (icon, social card, viewer page, README art) it is `ink` or `paper`.
- **30% supporting neutral.** `inkRaised`, the muted text colours, hairlines, and the bird itself (ink or paper).
- **10% coral.** At most one coral element per view should ask for attention. If two things are coral, one of them is wrong. Never use coral for decoration, borders or large fills.

No gradients on UI surfaces. The only gradients are the subtle lighting inside the app icon.

## In the app

- Set the app accent colour to `coral` (`NSColor(srgbRed: 1.0, green: 0.353, blue: 0.212, alpha: 1)`), so controls pick it up.
- Use system fonts (SF Pro, SF Mono for timecodes) and SF Symbols. The wordmark is a logo, not a typeface; don't set UI text to imitate it.
- The record button is a coral circle. While recording it becomes a rounded square in coral, never another colour.

## Assets

| File | What it is | Where to use it |
|---|---|---|
| `logo.svg` / `logo-dark.svg` | Bird + wordmark | README, website, About window. `-dark` is for dark backgrounds |
| `mark.svg` / `mark-dark.svg` | Bird alone | Favicon, viewer page header, small placements |
| `wordmark.svg` / `wordmark-dark.svg` | "reelbird" alone | When the bird is already on screen |
| `icon.svg` → `AppIcon.icns`, `icon-1024.png` | App icon | Bundled by `scripts/build-app.sh` |
| `menubar.svg`, `menubar.png`, `menubar@2x.png` | Menu bar glyph, idle | Status item. Template image: black + alpha, set `isTemplate = true` |
| `menubar-recording.svg` + PNGs | Menu bar glyph while recording (dot filled, gap ring) | Status item while recording. Template, or tint coral |
| `mascot-idle(-dark).svg` | Standing robin | Onboarding welcome, About |
| `mascot-recording(-dark).svg` | Robin with a live ring round the dot | Permission screens, "Recording…" states, countdown |
| `mascot-celebrating(-dark).svg` | Wing up, singing | Export finished, link copied, first recording done |
| `mascot-sleeping(-dark).svg` | Eyes shut, record light off | Empty library ("No recordings yet") |
| `social-preview.png` | 1280×640 card, from `src/social.html` | GitHub social preview, default link unfurl |
| `readme/banner-light.png`, `readme/banner-dark.png` | 1600×800 README banner, from `src/banner.html` | Top of README in a `<picture>` |
| `og/og-default.png`, `src/og.html` | 1200×630 Open Graph image and its per-page template | Website `og:image` |
| `web/favicon.svg`, `web/favicon-32.png`, `web/icon-512.png`, `web/apple-touch-icon.png` | Flat icon tile for browsers | Website `<head>`, web manifest |
| `anim/recording(-dark).svg` | Robin with a breathing record ring (CSS in the SVG) | Website "recording" moments; works in `<img>` |
| `anim/celebrating(-dark).svg` | Robin hops, flaps and sings | Website success states |
| `illustrations/*.webp` | Shaded robin scenes, 800 px square, transparent: `perch`, `camera`, `link`, `headphones`, `sleeping`, `celebrating` | Website sections, README, OG images |
| `screenshots/*-light.webp`, `*-dark.webp` | Framed app screens at 2x on paper or ink | Website, README |
| `screenshots/editor-*-window.webp` | The editor window and its shadow on a transparent background | Compositions (banner, social card, site hero) |
| `media/hero.webm`, `media/hero.mp4`, `media/hero-poster.webp` | 8 s looping auto-zoom clip, 1080p | Website hero video |
| `media/demo.gif` | The same clip, 960 px | README |

Illustrations have a cream bird that reads on paper and on ink. Where thin dark details (legs, beak, confetti) would vanish on ink, a `-dark` file has them lightened; use it on dark backgrounds and the plain file elsewhere.

Animated SVGs follow `prefers-reduced-motion` and stop when it is set. The record ring is the only pulse in the brand, and it only ever means "recording".

Mascot files without a suffix have an ink bird for light backgrounds; `-dark` files have a paper bird for dark backgrounds. Use the mascot at most once per screen, at 96 to 160 pt, and never as decoration next to text that already explains the state.

The SVGs use only paths, circles, gradients and `feGaussianBlur`, so `NSImage(data:)` renders them on every macOS version Reelbird supports. The app embeds them as Swift string literals (no SwiftPM resources).

## Icon construction

- 1024 × 1024 canvas; the tile is Apple's continuous-corner rounded rectangle, 824 × 824 at (100, 100), corner radius 185.4. The path came from SwiftUI's `RoundedRectangle(cornerRadius: 185.4, style: .continuous)`.
- Nothing is drawn outside the tile: macOS 26 puts icons with pixels outside the shape inside a grey tile. Shadows are inside the tile and clipped to it.
- Layers, back to front: ink tile with a vertical gradient (`#221D1A` → `#0E0B0A`), a faint coral glow, the bird's soft shadow, the paper bird (`#FFF9F0` → `#F3E0C8`), the record dot (radial `#FF8256` → `#FF5A36` → `#E5432B`), the eye with a catchlight, and a light rim along the tile edge.
- The SVGs come from `brand/tools/generate-svgs.py` (one robin path, the stroke-built wordmark, the icon layers, the favicon and the animations). Change geometry or colours there, then run `scripts/make-icon.sh` to regenerate every PNG and the `.icns`.

## Banner, social card and OG image

These are HTML pages in `brand/src/`, set in the website's fonts (Fraunces for headlines, Instrument Sans for small text) and rendered with headless Chrome:

```sh
brand/tools/render-html.sh brand/src/banner.html brand/readme/banner-dark.png 1600 800 dark
brand/tools/render-html.sh brand/src/banner.html brand/readme/banner-light.png 1600 800 light
brand/tools/render-html.sh brand/src/social.html brand/social-preview.png 1280 640
brand/tools/render-html.sh brand/src/og.html out.png 1200 630 "title=Share%20links%20from%20a%20bucket%20you%20own&section=Docs&art=link"
```

`og.html` takes `title`, an optional `section` line and an `art` name from `illustrations/`. Compress PNG output with `pngquant` before committing.
