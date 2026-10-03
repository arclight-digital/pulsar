# Pulsar logo, v2

## Rationale
- **Kept:** the core-and-satellite idea, the palette and Host Grotesk.
- **Refined:**
  - The trail now swells into the satellite, so satellite and trail read as one moving body. It sweeps 225°, with the satellite at 45°, and tapers to a soft point, with no hairline and no stray dot.
  - The trail is heavier and the core and satellite are larger, which sits closer to Adwaita's icon weight.
- **Colour:** the beam's colour changes along its sweep.
  - On dark it runs violet → peri → cyan, with a white core.
  - On light it runs soft cyan → peri → violet, with a deep-violet core.
- **Glow:** about half the previous glow; the mark is lit from inside, not fogged.
- **One silhouette at every size:** the small mark and the favicon keep the exact outline of the large mark. Only thickness changes: the trail is heavier and the dots slightly bigger as the size drops, and the glow is dropped at 16 px.
- **Tile:** a deep navy glow with a subtle galaxy band of faint haze and fine stars behind the mark. Below 56 px the favicons and small tile keep the navy without stars, which would just be noise.
- **Wordmark:** PULSAR in Host Grotesk at weight 650, tracked 0.24em. The letters are converted to outlines, so no font is needed.

## Spacing
- The unit **x** is the core's diameter.
- **Horizontal:** the core centre sits on the middle of the capital letters, and the gap from the satellite to the P is 1x.
- **Stacked:** the wordmark is centred under the core, about 1.4x below the trail.
- **Clear space:** keep at least 1x around the logo when you place it.
- **File crop:** transparent files are cropped to the artwork plus a 3% margin.

## Which file where
- **Favicon:** `svg/favicon.svg`, plus `png/favicon-16/32/48.png`.
- **App/system icon:** `in-os/pulsar-logo-icon.svg`, or `png/pulsar-tile-1024.png`.
- **Site top bar (28 px):** `svg/pulsar-animated.svg`. For the footer (44 px) use `svg/pulsar-mark-small.svg`.
- **Hero:** `svg/pulsar-animated-large.svg`, or any `svg/pulsar-lockup-*.svg`.
- **Login screen (GDM):**
  - `in-os/pulsar-gdm-logo.png`: 320×88, plus a 640×176 2x version.
  - `pulsar-gdm-logo.svg`: the vector source.
- **Boot splash (Plymouth):**
  - `in-os/watermark.png`: 400×110, plus an 800×220 2x version.
  - `watermark.svg`: the vector source.
  - Designed for black.
- **Size note:** both in-OS PNGs are cropped tight to the lockup. That is a change from the old 77 px and 96 px heights, so check that the theme config doesn't hard-code them.
- **Variant suffixes:**
  - none: colour on dark.
  - `-light`: colour on light.
  - `-mono`: ink (#0b0e1a).
  - `-mono-white`: star (#e9edf7).
  - `-small`: the heavier drawing for 20–56 px.

## Motion
- **Pulse:** one slow pulse, 4.8 s ease-in-out. The halo and bloom breathe between 95% and 106% scale; the core swells by 3.5%. Nothing rotates on its own.
- **Flywheel:** to spin the mark on click, rotate `#pl-spin` (its origin is the core). Use one ease-out turn, then stop.
- **Reduced motion:** under `prefers-reduced-motion: reduce` the pulse is off inside the SVG. The site's spin handler must check the same setting.

## Fonts
Host Grotesk and JetBrains Mono are included in `fonts/` under the OFL.

## App icons (`apps/`)

`pulsar-themes.svg` and `pulsar-themes-symbolic.svg` are the Themes app's
icon (the theme picker), as supplied. The image ships them under the app's
ID, `digital.arclight.Pulsar.ThemePicker` (scalable and symbolic, in
`system_files/usr/share/icons/hicolor/`), with the design tool's embedded
content-credentials metadata stripped; the copies here keep it. The engine's
notifications use the symbolic one. `pulsar-welcome.svg` and
`pulsar-welcome-symbolic.svg` are the welcome app's, shipped the same way as
`digital.arclight.Pulsar.Welcome`. `pulsar-settings.svg` is Pulsar Settings'
(`digital.arclight.Pulsar.Settings`, scalable only: it sends no
notifications, so it has no symbolic one yet).
