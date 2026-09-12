---
name: Pulsar
description: The nightly is the pitch. Ink ground, a live wallpaper shader, and a package diff set in Host Grotesk and JetBrains Mono on ARC UI.
colors:
  ink: "#0b0e1a"
  deep: "#241f3d"
  cyan: "#3ecbff"
  peri: "#8fa8ff"
  violet: "#4b3fd4"
  star: "#e9edf7"
  surface-dark: "#0f1222"
  card-dark: "#141830"
  elevated-dark: "#1a1e38"
  surface-light: "#f1f3fa"
  card-light: "#ffffff"
  text-secondary-dark: "rgba(233, 237, 247, 0.76)"
  text-muted-dark: "rgba(233, 237, 247, 0.66)"
  text-ghost-dark: "rgba(233, 237, 247, 0.6)"
  text-secondary-light: "rgba(36, 31, 61, 0.8)"
  text-muted-light: "rgba(36, 31, 61, 0.7)"
  text-ghost-light: "rgba(36, 31, 61, 0.68)"
  border-subtle-dark: "rgba(143, 168, 255, 0.12)"
  border-default-dark: "rgba(143, 168, 255, 0.18)"
  border-bright-dark: "rgba(143, 168, 255, 0.3)"
  border-subtle-light: "rgba(75, 63, 212, 0.12)"
  border-default-light: "rgba(75, 63, 212, 0.2)"
  border-bright-light: "rgba(75, 63, 212, 0.34)"
  chip: "rgba(11, 14, 26, 0.78)"
  on-chip: "rgba(233, 237, 247, 0.7)"
  chip-line: "rgba(143, 168, 255, 0.14)"
typography:
  display:
    fontFamily: "Host Grotesk, system-ui, sans-serif"
    fontSize: "clamp(2.6rem, 7vw, 5.5rem)"
    fontWeight: 700
    lineHeight: 0.98
    letterSpacing: "-0.03em"
  headline:
    fontFamily: "Host Grotesk, system-ui, sans-serif"
    fontSize: "clamp(28px, 3vw, 36px)"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.01em"
  title:
    fontFamily: "Host Grotesk, system-ui, sans-serif"
    fontSize: "clamp(18px, 1.5vw, 20px)"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.01em"
  lede:
    fontFamily: "Host Grotesk, system-ui, sans-serif"
    fontSize: "clamp(18px, 1.5vw, 20px)"
    fontWeight: 400
    lineHeight: 1.7
  body:
    fontFamily: "Host Grotesk, system-ui, sans-serif"
    fontSize: "17px"
    fontWeight: 400
    lineHeight: 1.7
  hint:
    fontFamily: "Host Grotesk, system-ui, sans-serif"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.7
  label:
    fontFamily: "Host Grotesk, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 700
    letterSpacing: "2px"
  label-inline:
    fontFamily: "Host Grotesk, system-ui, sans-serif"
    fontSize: "10px"
    fontWeight: 700
    letterSpacing: "2px"
  wordmark:
    fontFamily: "Host Grotesk, system-ui, sans-serif"
    fontSize: "16px"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "0.3em"
  mono:
    fontFamily: "JetBrains Mono, ui-monospace, monospace"
    fontSize: "16px"
    fontWeight: 400
  mono-caption:
    fontFamily: "JetBrains Mono, ui-monospace, monospace"
    fontSize: "12px"
    fontWeight: 400
    letterSpacing: "0.02em"
rounded:
  xs: "2px"
  sm: "4px"
  md: "10px"
  lg: "14px"
  xl: "20px"
  full: "9999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "16px"
  lg: "24px"
  xl: "40px"
  2xl: "64px"
  3xl: "96px"
  4xl: "128px"
components:
  build-chip:
    backgroundColor: "{colors.chip}"
    textColor: "{colors.star}"
    typography: "{typography.mono-caption}"
    rounded: "{rounded.full}"
    padding: "4px 16px 4px 8px"
  look-picker:
    backgroundColor: "{colors.chip}"
    textColor: "{colors.on-chip}"
    typography: "{typography.label}"
    rounded: "{rounded.full}"
    padding: "4px"
  look-picker-pressed:
    backgroundColor: "{colors.cyan}"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.full}"
    padding: "8px 16px"
  fold-summary:
    backgroundColor: "{colors.card-dark}"
    textColor: "{colors.text-secondary-dark}"
    typography: "{typography.hint}"
    rounded: "{rounded.full}"
    padding: "8px 16px"
  diff-row:
    typography: "{typography.mono}"
    padding: "8px 0"
  download-row:
    typography: "{typography.mono}"
    padding: "16px 0"
---

# Design System: Pulsar

## Overview

**Creative North Star: "The Lighthouse Ledger"**

Pulsar's site is a nightly build log wearing the OS's own wallpaper. The world is ARC UI's (Arclight's Lit component library, v4.2.2), handed Pulsar's palette through ARC's two-color contract and its two typefaces through ARC's font roles; everything else, from the glow vocabulary to the spacing scale to the type contexts, is inherited from ARC and not restated here. What is Pulsar's own is the ink ground, the shader sky, the terminal chip family that stays dark in both themes, and the diff typography that makes a version transition readable at a glance.

The mood is dry and inspectable. The hero is not a tagline but a package name at display size; proof is shown as terminals and code blocks rendering real commands and real outputs; the ledger is a ruled list of monospace rows, not cards. Emphasis is light rather than weight: the moving part of a version number glows in the accent, the one row that is the answer lifts to primary and then to accent, and everything shared or secondary is thinned toward ghost. Depth is tonal and luminous (ARC's `--glow-*`), never a drop shadow.

Confirmed rejections, carried from the direction contract and the ARC rulebook that binds this site: no wordmark-tagline-two-buttons hero; no images other than the shader and its still; no coloured left borders for state; no literal colours, sizes or typeface names in stylesheets; no motion without a state change to explain it.

**Key Characteristics:**
- Ink-blue-black ground with cyan and periwinkle accents on dark; violet as the single accent on light, chosen for contrast, not taste.
- One display face at two weights (Host Grotesk 400/700) and one mono (JetBrains Mono 400); labels are Host Grotesk Bold tracked, not ARC's default Tomorrow.
- The wallpaper shader is the only image; its CI-rendered still is the CSS ground and the no-WebGL fallback.
- Terminals, code blocks, the top bar on inner pages, and the footer are pinned dark in both themes (`theme-fixed-dark`).
- Glow over outline: hover and emphasis are `--glow-xs` / `--glow-sm` / `--glow-hover` text-shadows and box-shadows on accent colour, never thicker borders.
- Hairline-ruled lists (`1px solid var(--border-subtle)`) are the house container; cards are rare and pill-shaped when they appear.

## Colors

Six named brand colours, mapped per theme onto ARC's accent, surface, text and border slots; ARC derives every glow, focus ring, tint and status from the two accents.

### Primary
- **Cyan** (`--cyan`, `{colors.cyan}`): `--accent-primary` on the dark theme. The moving part of a version (`.v-to`), the major-bump package name, the live build dot and its glow, the pressed look-picker pill, links, selection, caret, focus outline. ~8:1 on ink.
- **Violet** (`--violet`, `{colors.violet}`): both `--accent-primary` and `--accent-secondary` on the light theme, where cyan would fall to ~2.4:1. Every accent role above follows it automatically through the contract.

### Secondary
- **Periwinkle** (`--peri`, `{colors.peri}`): `--accent-secondary` on dark. It is also the hue of every dark-theme border (`rgba(143,168,255, .12/.18/.30)`) and of the chip hairline, so rules on ink read as faintly lit rather than grey. Appears solid only in the footer spectrum line (`cyan → peri → violet`).

### Neutral
- **Ink** (`--ink`, `{colors.ink}`): `--bg-deep` on dark; the page body, the hero ground beneath the shader still, the footer. `theme-color` for dark.
- **Surface / Card / Elevated (dark)** (`{colors.surface-dark}` / `{colors.card-dark}` / `{colors.elevated-dark}`): ink lifting toward deep. Card is the fold summary's fill; surface and elevated are consumed by ARC components (top bar, code block chrome).
- **Star** (`--star`, `{colors.star}`): `--text-primary` on dark, `--bg-deep` on light, the hero's text colour in dark regardless of theme wiring. `theme-color` for light.
- **Deep** (`--deep`, `{colors.deep}`): `--text-primary` on light and the hero's text over the light silk still.
- **Text ramp**: primary, then star (or deep) at 0.76 / 0.66 / 0.60 alpha on dark and 0.80 / 0.70 / 0.68 on light for `--text-secondary`, `--text-muted`, `--text-ghost`. All steps clear 4.5:1 on their ground.
- **Chip family** (`--chip`, `--on-chip`, `--chip-line`): the translucent ink chip, its muted star text and periwinkle hairline. Used by the build chip and the look picker, which sit on the shader and must read on both themes without following either.
- **Status**: only `--color-warning` is used, on the `downgraded` tag in the ledger. Success and error are inherited from ARC and unused.

### Named Rules
**The Two-Color Rule.** Brand enters ARC through `--accent-primary` / `--accent-secondary` and their `-rgb` twins, restated per theme in `tokens.css`, which loads after ARC's `base.css` and wins on cascade order. Nothing spells a channel triplet outside that file.

**The Lift-Then-Hue Rule.** Hierarchy is built by lifting to `--text-primary` and then to the accent, never by stepping down the grey ramp: the gamescale answer row goes muted → primary → accent with `--glow-xs`; the version transition goes ghost (shared parts) → secondary (from) → accent (to).

**The Contrast-Not-Taste Rule.** The accent changes per theme (cyan on ink, violet on star) because of contrast alone. A new accent role must clear 4.5:1 on both grounds or it uses the contract's slot, not a hand-picked colour.

## Typography

**Display Font:** Host Grotesk 700 (with `system-ui, sans-serif`)
**Body Font:** Host Grotesk 400 (same fallback)
**Label/Mono Font:** JetBrains Mono 400 (with `ui-monospace, monospace`); labels are Host Grotesk 700, uppercase, tracked

**Character:** One grotesk at two weights does all the words; everything a machine wrote (package names, versions, digests, commands, captions under terminals) is mono. Display headlines sit tight and heavy with negative tracking; labels are small, bold and widely tracked; the wordmark is the label treatment stretched to 0.3em.

### Hierarchy
- **Display** (700, `clamp(2.6rem, 7vw, 5.5rem)`, 0.98, -0.03em): the hero's lead line only, a package name or "Nothing moved." / "First build." Balanced wrap, `overflow-wrap: anywhere` for long names.
- **Headline** (700, `--text-2xl`, `--heading-lh` 1.2, -0.01em): every `h2` chapter title and `arc-page-header` heading. `margin-bottom: --space-md`.
- **Title** (700, `--text-lg`, 1.2): `h3` band headings in the ledger. Install's `h3` instead wears the label context.
- **Lede** (400, `--text-lg`, `--text-secondary`, max 62ch): the paragraph under a chapter heading.
- **Body** (400, `--text-md` 17px, 1.7): prose; `text-wrap: pretty` on `p`, `li`, `figcaption`.
- **Hint** (400, `--text-sm`, `--text-muted`, max 62ch): the note under a terminal, a row list, or a section.
- **Label** (700, `--label-size` 12px, `--label-spacing` 2px, uppercase): footer column titles, the brandline, the Install path headings, the look-picker buttons.
- **Label-inline** (700, `--label-inline-size` 10px, 2px, uppercase): the "+N packages" and "downgraded" tags in a diff row, the standard/nvidia column of a download row, table column heads.
- **Wordmark** (700, `--text-sm` in the bar / `--text-lg` in the footer, `--glyph-lh` 1, 0.3em): PULSAR, uppercase, negative right margin to swallow the trailing tracking.
- **Mono** (400, `--text-sm`, tabular numerals): diff rows, file names, the manifest and terminals, the timeline stage names.
- **Mono caption** (400, `--text-xs`, 0.02em, `--text-muted`): the line above or below a terminal ("don't take the page's word for it", "the image's own manifest — rendered, not written"), the digest pair in the hero.

### Named Rules
**The Machine-Wrote-It Rule.** Anything a build, a shell or a package manager produced is set in `--font-mono`: names, versions, digests, filenames, commands, timeline stage names. Prose about it is Host Grotesk.

**The Type-Context Rule.** Text picks an ARC context (`--label-*`, `--label-inline-*`, `--heading-lh`, `--glyph-lh`, `--body-*`) or a `--text-*` step; no literal `font-size`, `font-weight`, `letter-spacing` or family name in a stylesheet. The one clamp outside the scale is the hero display size.

**The Whole-Version Rule.** A version transition prints both versions in full; shared head and tail are dimmed to ghost, the moving part of the target is lifted to accent. Never factor out the shared parts.

## Layout

One centred column. Inner pages use `<arc-container size="lg">` under a `.page` wrapper padded `--space-4xl` at the top to clear the fixed bar; the home hero's own `.inner` is `min(100% - 2 * --space-lg, 72rem)` and bottom-aligned in a `100svh` grid. The bar is `<arc-top-bar fixed contained="xl">`, transparent on the immersive home page until scrolled, pinned dark on inner pages.

Sections are `.chapter`: `padding-block: --space-3xl --space-2xl` (more air above a heading than below it), and adjacent chapters are separated by a `1px solid var(--border-subtle)` hairline. Inside a chapter, two-column asymmetric grids carry prose beside a terminal: `minmax(0, 5fr) minmax(0, 7fr)` (pipeline, ISO), `7fr 5fr` (install), or `1fr 1fr` (provenance prose), with a `--space-2xl` gutter, collapsing to one column with `--space-xl` (or `--space-md`) at `max-width: 56rem`. The hero drops to `--space-4xl` top padding and a 48px mark at `max-width: 40rem`; the bar's build badge hides at `48rem`.

Vertical rhythm is ARC's default-density scale: 4 / 8 / 16 / 24 / 40 / 64 / 96 / 128. Row lists use `--space-sm` (diff rows) or `--space-md` (download rows) block padding. Prose measures are 62ch for ledes and hints and 44rem for the colophon.

## Elevation & Depth

Luminous, not lifted. There are no drop shadows anywhere in site/; depth comes from ARC's glow tokens on accent colour and from the tonal surface ramp (ink → surface → card → elevated). Rest state is flat; glow appears on hover, on the live dot, and on the one accent-lifted element in a group.

### Shadow Vocabulary
- **Text lift** (`text-shadow: var(--glow-xs)`, `0 0 6px rgba(accent, .42)`): the target version, the major-bump package name, the gamescale answer, footer and file links on hover.
- **Chip hover** (`box-shadow: var(--glow-xs)` with `border-color: var(--cyan)`): the build chip.
- **Live dot** (`box-shadow: var(--glow-sm)`, `0 0 8px rgba(accent, .42)`): the pulsing build dot and the pressed look-picker pill.
- **Fold hover** (`box-shadow: var(--glow-hover)`, `0 0 12px rgba(accent, .22)` with `border-color: var(--border-bright)`): the rebuilds `<details>` summary.
- **Focus** (`outline: 2px solid var(--accent-primary); outline-offset: 2px; box-shadow: var(--focus-glow)`): every `:focus-visible`.

### Named Rules
**The Glow-Over-Outline Rule.** Emphasis and hover are expressed with `--glow-*` on the accent, never with a thicker or darker border. A border may change colour on hover (subtle → bright, chip-line → cyan) only alongside a glow.

**The Dark-Frame Rule.** Terminals, code blocks, the inner-page bar and the footer are `theme-fixed-dark` in both themes: a terminal is a terminal, not a card. Commands and transcripts are `arc-code-block` in its `default` variant: a filename header, the code, the copy button, no window chrome and no status bar. `arc-terminal` and the `window` variant are not used, because they are application windows and these are commands. Do not restyle a block's parts.

## Shapes

Two silhouettes. Content is rectilinear and ruled: lists are separated by `1px solid var(--border-subtle)` hairlines on the top of each row and the bottom of the list, with no side borders and no background. Controls that sit on top of things are pills (`--radius-full`): the build chip, the look picker and its buttons, the fold summary, ARC's nav pills and badge. ARC's `--radius-md` (10px) is inherited by its own components (code block, terminal, buttons) and is not overridden. The footer opens on a 2px spectrum line (`linear-gradient(90deg, cyan, peri, violet)`), the palette read left to right.

## Components

About twenty ARC elements are registered (skip-link, top-bar, navigation-menu, nav-item, theme-toggle, icon-button, badge, button, link, footer, section, container, page-header, code-block, terminal, copy-button, stepper/step, description-list/item, divider, alert, kbd, time-ago, scroll-to-top, timeline/item), pre-rendered to declarative shadow DOM and hydrated by Lit. Their look is ARC's under Pulsar's tokens; the house patterns below are the site's own light-DOM components.

### Buttons
- **Shape:** ARC's (`--radius-md`).
- **Primary:** `<arc-button variant="primary" size="lg">` for Install in the hero; accent fill under the contract.
- **Secondary:** `<arc-button variant="secondary" size="lg">` for "The full diff". Renders outline-first as ARC ships it (open cosmetic item, see Don'ts).
- **Tertiary:** a plain `<a>` in inherited colour at 0.85 opacity ("Browse the source →"), and `.more` links under a chapter (accent, underline on hover only).
- **Icon:** `<arc-icon-button variant="ghost" size="md">` for the GitHub link beside `<arc-theme-toggle icon-only>`.

### Chips
- **Build chip** (`.build-chip`): pill, `--chip` fill, `--chip-line` hairline, star text in mono at 0.02em, an 8px cyan dot with `--glow-sm` pulsing 2.4s on `--ease-out`. Hover: cyan border and `--glow-xs`. `[data-stale]` (set by the beacon when the registry disagrees): dot goes `--text-ghost`, glow and pulse stop.
- **Look picker** (`.picker`): pill tray of `--chip` with `backdrop-filter: blur(12px)`, four label-context buttons; pressed = ink on cyan with `--glow-sm`. Hidden until a WebGL context exists; home page only.
- **Bar badge**: `<arc-badge variant="primary" size="sm">` carrying the build version in mono with tabular numerals.

### Cards / Containers
- **Ruled list** (the house container): no fill, hairline rows. Diff rows (`.drow`), presence rows (`.prow`), download rows (`.row`), the gamescale table. Names in primary mono, values in secondary or ghost, tags in label-inline muted.
- **Fold** (`<details class="fold">`): pill summary on `--bg-card` with `--border-subtle`, hover to `--border-bright` and `--glow-hover`; opens `--space-md` above its rows.
- **Terminal / code block**: `<arc-terminal class="theme-fixed-dark" prompt="$"|"❯">` for transcripts with real output, `<arc-code-block class="theme-fixed-dark" variant="window" language="bash" filename="…">` for a copyable command. A mono caption sits above (with `<arc-copy-button>`) or below as `figcaption.hint`.
- **Timeline**: `<arc-timeline heading-level="3">` in mono for the five pipeline stages.

### Navigation
- **Top bar**: `<arc-top-bar fixed contained="xl" nav-align="left" mobile-menu="nav">`; lockup = 28px animated mark + PULSAR wordmark at 0.3em; `<arc-navigation-menu>` of `<arc-nav-item active>` pills with light-DOM anchors so the bar works without JS. Immersive (transparent until scrolled) on `/`, `theme-fixed-dark` elsewhere. Actions: theme toggle and GitHub icon button, `--space-xs` apart.
- **Footer**: `<arc-footer contained="xl" no-border>` on a `theme-fixed-dark` wrapper under the 2px spectrum line; 44px mark, wordmark at `--text-lg`, brandline in label context; three label-titled columns of primary-coloured links that go accent with `--glow-xs` on hover; muted colophon at `--text-sm`.
- **Skip link** and **scroll-to-top** (threshold 900) are ARC's.

### Diff Row (signature)
One transition per row: mono name (accent with `--glow-xs` if the bump is major, accent on hover of an openable group), an optional `+N packages` label-inline tag with a `caret-down` icon that rotates 180° in 0.25s, an optional warning-coloured `downgraded` tag, and the `Version` device right-aligned at `--text-sm`. Groups are `<details>`, members listed in mono `--text-xs` secondary, indented `--space-md`. The visual transition is `aria-hidden`; a spoken sentence sits in `.sr-only`.

### Sky (signature)
Two absolutely-positioned canvases behind the hero: `#sky` runs `assets/shaders/pulsar.frag` in WebGL1 (DPR capped at 2, one full-screen triangle), `#skyfade` snapshots the outgoing look for a crossfade. The CSS ground is the CI-rendered silk still (dark or light by theme). Four looks (silk, leak, satin, holo) × two themes; theme comes from `data-theme` via a MutationObserver, look from `localStorage "pulsar-look"`. Reduced motion renders still frames that redraw only on a control.

### Motion
One easing for everything authored: `--ease-out` `cubic-bezier(0.16, 1, 0.3, 1)`. Durations are 0.2s (colour, border, shadow), 0.25s (caret), 0.3s (picker), 2.4s (pulse). Every animation stops under `prefers-reduced-motion`; `scroll-behavior: smooth` reverts to auto. The mark's flywheel spin (`spin.ts`) is an unadvertised easter egg with no cursor, focus ring or accessibility exposure, and does not run under reduced motion.

## Do's and Don'ts

### Do:
- **Do** set every colour, size, radius and face as a `var(--*)` from ARC or `tokens.css`; a literal is a colour no theme can reach.
- **Do** put anything a machine wrote in `--font-mono` with `font-variant-numeric: tabular-nums` where figures align.
- **Do** build emphasis by lifting muted → primary → accent with `text-shadow: var(--glow-xs)`, and hover by glow (`--glow-xs` / `--glow-hover`) with at most a border colour shift.
- **Do** contain lists with `1px solid var(--border-subtle)` hairlines (row top, list bottom) and no fill; reserve `--radius-full` pills for controls that sit on top of content.
- **Do** add `class="theme-fixed-dark"` to every `arc-terminal` and `arc-code-block`, and pair it with a mono caption at `--text-xs`.
- **Do** open a chapter with `h2` → `.lede` (62ch) → content → `.hint` or `.more`, inside `<section class="chapter">`; the hairline between chapters comes from `.chapter + .chapter`.
- **Do** declare light-theme overrides twice, under `[data-theme='light']` and `@media (prefers-color-scheme: light) [data-theme='auto']`, mirroring ARC's structure.
- **Do** guard motion with `prefers-reduced-motion` and use `--ease-out` for every transition.

### Don't:
- **Don't** mark state with a coloured left border, an active-edge bar or a side stripe on an alert. ARC's hardest ban; no exceptions.
- **Don't** introduce a second image. The shader (and its still) is the only picture; the mark and gamescale icon are authored SVG, not imagery.
- **Don't** write a typeface name or a literal `font-size` / `font-weight` / `letter-spacing` into a stylesheet; use the roles and contexts.
- **Don't** use drop shadows (`--shadow-*`) for depth; the system is glow and tonal steps.
- **Don't** let a terminal or code block follow the light theme, and don't hide or restyle its window chrome.
- **Don't** step hierarchy down the grey ramp (secondary → muted → ghost are within 17 RGB points of each other); lift instead.
- **Don't** factor the shared parts out of a version transition or truncate a package name; dim and wrap.
- **Don't** hard-code an accent for a region's contrast; if cyan fails on a ground, that ground takes the theme's accent slot (violet on light) or the chip family.
- **Don't** treat the one open cosmetic item as house style: nav pills and the secondary button render outline-first where ARC prefers glow. That is ARC's default rendering awaiting a decision, not a rule to inherit. (The ledger caret icon was verified in `.preview/arcui/r3-changelog-ledger.png` on 2026-09-12.)


## Revision note (2026-09-12, later the same day)

The diff-first hero was built, seen, and rejected by the user. The shipped hero
is the identity hero: 180px animated mark (flick it: `.mark.is-spinning`
runs the four-turn `flywheel` keyframes, `spin.ts` sets `--spin-from`),
PULSAR wordmark with ARC's bloom twin behind it (`.word-shadow`, breathing on
`--glow-a`, 0.4 on the light theme), tagline, one sentence, the live build chip,
the two `bootc switch` code blocks, then Install / What changed last night.
The night's diff is the first chapter under the hero. Chapters sit on
`--space-2xl` above / `--space-xl` below with ARC's `--glow-line-gradient`
hairline between them; every h2 carries a 48px `arc-divider
variant="line-gradient"` rule beneath it; the home page closes on an
`arc-cta-banner`; ledger tags are `arc-badge size="sm"`. Code blocks and
terminals are `min-width: 0; max-width: 100%` so an unwrapped line scrolls
inside them instead of widening a phone.
