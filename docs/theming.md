# Theming

`pulsar theme set <name>` recolors the whole desktop in one step;
`pulsar theme revert` restores stock GNOME. The Pulsar theme is on by
default.

## What ships

| Piece | Where |
|---|---|
| engine (python, stdlib only) | `/usr/libexec/pulsar/pulsar-theme`, from `scripts/pulsar-theme`; `pulsar theme ...` execs it |
| Themes app (libadwaita) | `/usr/libexec/pulsar/pulsar-theme-picker`, "Themes" in the app grid |
| 24 themes (listed below) | `/usr/share/pulsar/themes/<slug>/theme.toml` + `backgrounds/*.jxl` |
| per-target templates | `/usr/share/pulsar/theme/templates/` |
| Shell extension (+ glass and light) | `/usr/share/gnome-shell/extensions/pulsar-theme@arclight.digital`, settings schema `org.gnome.shell.extensions.pulsar-theme` |
| image default | `zz1-pulsar-theme.gschema.override`: `enabled-extensions` only |
| first-login units | `pulsar-theme-init.service`, `pulsar-theme-notice.service` (user, `--global`) |
| GTK3 recoloring | `adw-gtk3-theme` |
| agent skill for making themes | `/usr/share/pulsar/skills/pulsar-theme/SKILL.md`, linked by `pulsar agent add` |

The 24 themes, in the order `pulsar theme list` and Themes show them. Dark
and light (16): Pulsar, Pulsar Holo, Ayu, Catppuccin, Everforest, Flexoki,
Gruvbox, Kanagawa, Nord, One, Oxocarbon, Redshift, Regolith, Rosé Pine,
Solarized, Tokyo Night. Dark only (7): Amber, Dracula, Eclipse,
Magnetosphere, Phosphor, Poimandres, Synthwave '84. Light only (1): Alucard
(Dracula and Alucard are separate one-variant themes, as upstream ships
them).

- One-variant themes set Dark or Light Style when chosen and don't change
  when it flips.
- Phosphor and Amber (CRT terminals) pull every ANSI color toward the
  phosphor while keeping its meaning.
- The classic themes (the 18 ported from published palettes) are generated
  by `scripts/build-themes.py`, from the base16/base24 schemes in
  `assets/themes/imports/` or from the upstream palette where there is no
  faithful base16 port. That file records each scheme, corrected slots
  (Tokyo Night's base16 "red" is pale blue-white), and the contrast fit:
  text hues move in OKLab lightness only until they clear WCAG AA, keeping
  hue and chroma.
- Pulsar, Pulsar Holo, Eclipse, Magnetosphere, Redshift and Regolith are
  written by hand; Pulsar and Pulsar Holo from DESIGN.md.
- `pulsar theme audit` re-checks all of it; the Containerfile refuses to
  build if any theme fails.

## What one switch writes

All in the user's own config, each file replaced with rename(2), in one
transaction:

- **accent**: the libadwaita accent nearest the theme accent's hue (live
  everywhere, Flatpaks included, via the settings portal); `slate` only for
  a gray accent, and `gnome_accent` in theme.toml overrides it. A Dark Style
  flip re-sets it when the other variant's differs. `color-scheme` is
  written only by a one-variant theme or `--variant`.
- **`~/.config/gtk-4.0/gtk.css`**: libadwaita color variables in a marked
  block appended to the user's file, both variants under
  `@media (prefers-color-scheme)`.
- **`~/.config/gtk-3.0/gtk.css`** + `gtk-theme=adw-gtk3[-dark]` for the
  current scheme (GTK3 has no media queries). On a Dark Style flip the
  extension runs `pulsar-theme follow-scheme` to redo it (open apps on their
  next window).
- **Ptyxis**: a palette on every profile, following Dark Style.
- **GtkSourceView**: a scheme pair; Text Editor recolors its window from it.
- **btop**: a theme for the current scheme, redone by `follow-scheme`.
- **wallpaper**: the pair.
- **Shell**: two stylesheets in `~/.local/state/pulsar-theme/shell/`, layered
  over the stock Shell theme by the extension and swapped on Dark Style.
- **terminal coding agents**, where set up: Claude Code (`~/.claude.json`
  `theme`), Gemini CLI (`~/.gemini/settings.json` `ui.theme`) and opencode
  (`~/.config/opencode/tui.json` `theme`) draw with the terminal's 16 colors.
  Light themes give Claude Code and Gemini their own light theme instead
  (their ANSI light modes use color 7, nearly the background). Redone on a
  Dark Style flip; revert takes back only that key. `--without agents`
  skips them.
- **Flatpak override**: a read-only grant on `~/.config/gtk-4.0` and
  `~/.config/gtk-3.0` so Flatpak apps read the same gtk.css.
  `--without flatpak` turns it off until `--with flatpak`; revert removes
  exactly the two entries.

Fonts and icons are never touched.

- `follow-scheme` never overwrites a choice: a btop, agent or GTK theme the
  user changed after theming stops following. A full `set` overwrites. First
  login keeps an agent theme the user already picked.
- Dotfiles symlinked within the home folder (stow, chezmoi) are written
  through, on set and revert. Links outside home (Nix store, shared files)
  are skipped with a note. Files keep their permissions.

## Revert

The first time the engine touches a file or key, the original goes into
`~/.local/state/pulsar-theme/baseline/`. Then:

- engine-only files (palettes, schemes, the btop theme, the Shell sheets)
  are restored byte for byte, or removed if new;
- shared files keep every user line, including later edits; only the
  engine's part goes (the `gtk.css` block, the two `btop.conf` keys, the
  Text Editor key, the two Flatpak entries);
- dconf keys return to their original value, unless the user changed them
  since;
- Ptyxis profiles stay; only their palette key is reset.

Keys that showed the image default get GNOME's upstream defaults (from the
schema XML, not Fedora's or Pulsar's overrides). The extension is removed
from `enabled-extensions`; other extensions stay. `revert --to image` resets
to the image defaults. `tests/theme-gate` checks the round trip.

## First login

- `zz1-pulsar-theme.gschema.override` only enables the extension. Theme
  colors aren't image defaults (they'd reach accounts init leaves alone);
  init writes them into a fresh account's dconf before the Shell starts.
- `pulsar-theme-init.service` runs `pulsar-theme init` once per account,
  before the Shell. A fresh account gets the full theme, plus Themes on
  Super+T if unused. An account with its own look (gtk.css, accent,
  wallpaper, GTK or Shell theme, terminal palette, editor scheme or btop
  theme) is left alone.
- `init` writes `~/.local/state/pulsar-theme/init.json` (the unit's
  condition), so it runs once. A killed run leaves `init.pending`, and the
  next login finishes it without mistaking engine values for the user's.
  `revert` writes it too, so a reverted account is never re-themed.
- `pulsar-theme-notice.service` shows the one notification after the Shell
  starts, then deletes the queued notice.
- Existing accounts get this once, on the first login after the update. GDM's
  greeter accounts are skipped: init, the notice and the welcome check
  `pulsar-theme login-account`.

## Open apps

GTK reads gtk.css at startup. After a switch the engine lists open GTK apps
and offers Restart / Later / Don't ask again (a dialog in Themes, a
terminal prompt, or a one-line note). Restart activates each app's
`app.quit` (Ctrl+Q), so unsaved work gets its save dialog; nothing is killed,
and only apps that exited are relaunched. Don't ask again sets
`restart-prompt = off` in `~/.config/pulsar/theme.conf`
(`pulsar theme config restart-prompt on` undoes it).

## Wallpapers

Pulsar has eight shader looks, one file each in `assets/shaders/looks/`
(`looks.json` gives their order, which is `u_look`). Every classic theme
ships two of them rendered in its palette from `assets/shaders/theme.frag`,
dark and light, for `bg-next`; the site's hero can show any of the eight in
any theme. Each look has its own light:

- nebula: a domain-warped field; ion-trail filaments on its isolines, a faint
  lit circuit lattice. It was called silk until 2026-09-29: a render table
  that still says `look = "silk"` renders it, and the old wallpaper paths
  (`pulsar-silk-*.png`, `backgrounds/silk-*.jxl`) stay as links;
- leak: soft beams with prismatic edges; god-rays, drifting motes, an
  anamorphic streak;
- satin: a satin sheet piled up, lit with an anisotropic sheen along the
  threads;
- holo: iridescent foil; thin-film fringes, a diffraction sheen, one faint
  scan band;
- relief: a topographic map lit by one traveling light, the index lines
  glowing faintly;
- tide: caustic light on a pool floor, each filament splitting a little into
  color;
- orbit: a ringed planet's limb catching a low sun, ring particles glinting;
- beacon: a pulsar's two beams sweeping through dust.

A look a theme has no render table for takes its colors and light
direction from the theme's primary table. Light variants draw the looks in
low contrast, as white highlights and slight darkening on the light ground.
Highlights roll off
through a soft knee below the theme's highlight color; no scanline raster
(it moirés when GNOME scales). `glow`, `signal`, `web` and `grain` tune each
render; the phosphor themes run stronger. The brand wallpapers and the
site's live hero sky compile `assets/shaders/pulsar.frag` (GLSL ES 1.0).

`scripts/build.sh` renders PNGs on the builder; the Containerfile converts
them to JPEG XL at q99 (~1.2 MB each; lower qualities lose the film grain
that also dithers dark gradients). Both shaders end with a ±1-step
triangular dither. A `--no-wallpapers` build ships none, and every theme
falls back to the brand pair.

`docs/theming/wallpapers-before.jpg` and `wallpapers-after.jpg` are contact
sheets (regenerate with `scripts/render-theme-wallpapers.py --sheet`).

## Glass and light

The Shell extension's effects, each a setting in the Extensions app and on
the Appearance page of Pulsar Settings (the gear in Themes opens it;
`org.gnome.shell.extensions.pulsar-theme`), where Reset restores the
defaults. They add material and light only; GNOME's layout, radii, type and
timing are unchanged. All are on by default except `glass-off-gaming`.

| Key | What it does |
|---|---|
| `glass` | Menus, the top bar, OSDs and notification banners go translucent over a live blur of what's beneath, with a soft drop shadow. The dash gets the light and shadow without blur. |
| `glass-tint` | A slider from clear (0) to fully tinted (1), default 0.5: how far the color of what's behind pulls the glass's color, from twice the default pull at 0 to none at 1 (the theme's color alone). Every blur takes it at once. |
| `window-glass` | Every GTK 4 window's ground is the palette's background at 80% (alpha in `gtk.css`), over a blur the extension draws inside each GTK window; Ptyxis's profile opacity goes to 0.8, so the terminal matches (unless you set your own `opacity`). Header bars, sidebars and views paint nothing over that ground, so a window is one level. Beside a sidebar (Files, Settings) the content pane is solid; in Text Editor the document is glass and the header and tab bars are solid. Popovers' ground is 50%, floating dialogs 80% in the popover color; in-window sheets and toasts are opaque, and fullscreen windows are solid. Cards go a step lighter with a hairline edge. The GTK half applies to apps opened after a change; the terminal changes live. Windows open when it's switched off keep their blur until closed. Needs `glass`. |
| `lighting` | The button that opened a menu glows; a shader lights the rim facing it, with spill, an inner glint, scatter and grain. OSDs are lit from the bottom, banners from the top. Low battery warms the edge (orange); critical battery or a critical banner turns it red. Phosphor and Amber (`shell_glow` in theme.toml) also glow the clock and headings. |
| `power-on` | A surface's rim traces out from the light as it appears (instant with animations off). Needs `lighting`. |
| `glow` | Accent-filled things glow softly: a checked quick toggle (a split one as one pill), today in the calendar, the default button, switches, checked boxes, the active workspace, slider fills. Reach and strength scale with each element's size (wider and stronger on big pills, tight and faint on bars); weaker on light schemes. In apps opened after a change: suggested buttons, switches, checks and radios (GTK4 and GTK3), plus scale fills and progress bars (GTK4 only). Nothing inside list cells, nothing disabled. |
| `focus-brackets` | Four corner brackets follow the keyboard-focused control, beside the stock focus ring (not for pointer hover). |
| `glass-off-gaming` | Off by default. While a game is running (GameMode has a client), the Shell's glass and light are off, as if switched off. Windows opened with glass keep it. |
| `glass-off-power-saver` | On by default. While the power mode is Power Saver, the Shell's glass and light are off, as if switched off. Windows opened with glass keep it. |

- High contrast turns every effect off. On the lock screen, `glass` puts a
  blurred ground over the wallpaper; the other effects are off there.
- `window-glass` and `glow` have engine halves (`window_glass()`,
  `glow_on()`): flipping them makes the extension run
  `pulsar-theme window-glass`, which rewrites the GTK and terminal halves.
- The Shell sheet's `.pulsar-glass`, `.pulsar-lit` and `.pulsar-glow` blocks
  (glow from `gnome-shell-glow.css`, appended to each scheme's sheet) key off
  classes the extension puts on the UI group.
- The blur: a half-size copy of the pixels beneath a surface, patched with
  what each frame redraws, run through a dual-filter (Kawase) pyramid and
  drawn through a full-resolution mask with rounded corners. It sits beside
  each menu, not inside it, because GNOME paints menus through an offscreen
  buffer (see `glass.js`). Glass window surfaces sit at opacity 254 so
  Mutter still paints what's beneath their opaque parts.
- The theme gate's account has every effect off (they move the pixels it
  measures).

## When GNOME changes

The Shell stylesheet and the extension's `glass.js` are built on GNOME Shell
internals. `tests/theme-gate/gate.sh` checks every selector against the new Shell's
stock stylesheet and every theme in a real headless Shell (see its README).
The Containerfile refuses to build when the extension doesn't declare the
image's Shell major; `shell-version` is bumped only after the gate passes.
