---
name: pulsar-theme
description: Make, tune or share a desktop theme on Pulsar, which recolors GNOME, GTK apps, the terminal, the editor, the top bar and the wallpaper in one step. Use when the user asks for a new theme, a theme "like" something (a scheme, a photo, a brand, a mood), a tweak to a color, or to fix a theme's contrast.
---

# Pulsar themes

A Pulsar theme is one folder with a `theme.toml` in it. `pulsar theme set
<slug>` applies it to the whole desktop at once, and `pulsar theme revert`
takes it all back. Your themes go in `~/.local/share/pulsar/themes/<slug>/`;
the ones that ship are in `/usr/share/pulsar/themes/` and are good examples
(`nord/theme.toml` is a complete one). Never edit those: copy one into the
user's folder under a new slug.

Everything here runs as the user. None of it needs `sudo`.

## 1. Start from the closest thing

- **A named color scheme** (Nord, Tokyo Night, a base16 or base24 scheme):
  import it rather than retype it.

  ```
  pulsar theme import base16 <file-or-url> --name <slug>
  ```

  It warns when a slot is not the color its name says (a "red" that is not
  red). Fix those with `--set red=#e06c75`, and pick the accent with
  `--accent blue` or `--accent '#88c0d0'`. The import writes a wallpaper
  generated from the palette.
- **Anything else** (a photo, a brand, "warm, low contrast, amber"): write
  `theme.toml` by hand, below.

## 2. The file

```toml
name = "Ember"                 # shown in the picker
author = "you"
prefer = "dark"                # the variant to use when both exist

[dark]                         # and/or [light]; one is enough
background = "#1b1d2b"         # required
foreground = "#d8dae8"         # required
accent = "#ff9e64"             # buttons, links, the top bar highlight
```

Only `background` and `foreground` are required; everything else is derived
from them and can be set to override the derivation:

- UI: `accent`, `selection`, `muted`, `background_sunken`,
  `background_deep`, `background_raised`, `foreground_dim`,
  `foreground_bright`, and the surfaces `window`, `view`, `headerbar`,
  `sidebar`, `card`, `popover`.
- Terminal and syntax: `red`, `orange`, `yellow`, `green`, `cyan`, `blue`,
  `magenta`, `brown`, and `bright_red`, `bright_yellow`, `bright_green`,
  `bright_cyan`, `bright_blue`, `bright_magenta`.

Keep each ANSI color the hue its name says: a red that reads as orange makes
every error look like a warning. With both `[dark]` and `[light]`, the theme
follows the user's Dark Style switch; with one, choosing it sets Dark Style.

**Wallpaper** (optional): list image files relative to the theme folder.
Without it the theme keeps Pulsar's own wallpaper.

```toml
[wallpaper]
dark = ["backgrounds/ember-dark.png"]
light = ["backgrounds/ember-light.png"]
```

## 3. Check it before anyone sees it

```
pulsar theme audit <slug>
```

It checks every pair that is read as text against WCAG. Fix every FAIL
before applying: move the failing color's lightness (not its hue) away from
its background until it passes, then audit again. `pulsar theme list`
shows the swatches, which is a quick sanity check that the file parsed.

To look at what it would write without changing anything:

```
pulsar theme render <slug> /tmp/<slug>-preview   # every file, nothing touched
pulsar theme set <slug> --dry-run
```

## 4. Apply it only when the user says so

Applying changes their whole desktop. Say what you are about to do, and note
what they are on now so they can go back:

```
pulsar theme current          # what is applied now
pulsar theme set <slug>       # apply; open GTK apps may be offered a restart
```

Going back: `pulsar theme set <previous-slug>`, or `pulsar theme revert` for
stock GNOME. Pass `--no-restart` to `set` when you are running it for the
user from a terminal and they have not asked for apps to restart.

## 5. Sharing it

The folder is the whole theme. Zip `~/.local/share/pulsar/themes/<slug>/`;
whoever receives it unzips it into the same place on their machine and runs
`pulsar theme set <slug>`, or picks it in Themes in the app grid.

## Do not

- Edit `/usr/share/pulsar/themes` or anything else under `/usr` (read-only).
- Hand-edit `~/.config/gtk-4.0/gtk.css`, Ptyxis palettes or dconf keys to
  "theme" something. The engine owns its block and reverts it exactly; hand
  edits outside it make revert keep them.
- Apply a theme that fails `audit`.
