# Theme gate

The one part of the theme engine that a GNOME upgrade can break is the Shell
stylesheet: `pulsar-theme@arclight.digital` layers a colour-only sheet over
the stock Shell theme, and the selectors it targets are Shell internals. The
extension API (`St.Theme.load_stylesheet`) is stable; `.quick-toggle:checked`
is not. Everything else the engine writes is a documented interface
(libadwaita colour variables, Ptyxis palettes, GtkSourceView schemes, btop
themes, gsettings keys).

`gate.sh` answers "does every theme still render as specified on this
image's GNOME?" with an exit code:

```
tests/theme-gate/gate.sh                                   # :latest
tests/theme-gate/gate.sh localhost/pulsar:44               # a local build
```

It builds `Containerfile` FROM the given image (adding the apps it
screenshots), runs a headless gnome-shell on private buses with a scratch
account, and runs `scenario.py gate`. Screenshots and `gate-report.json` land
in `.preview/theme-gate/`. It needs rootless podman and about ten minutes.

## When it runs

- **Every nightly, warn-only** (not wired yet): the result is published as an
  artefact beside the build log and never blocks publishing. Drift shows up
  as a red report the same night, not as a user's bug report.
- **Hard gate on a GNOME major change**: the nightly that first carries a
  new Shell major refuses to publish until this passes. The Containerfile
  already refuses to build when the extension's `shell-version` does not
  declare the image's Shell; bump it only after this gate passes on the new
  Shell.

## The other scenarios

`run.sh` runs any of them against an already-built gate container:

- `firstlogin`: a fresh account gets the Pulsar theme and the picker
  shortcut from `pulsar-theme init`, `pulsar theme revert` gives stock GNOME,
  and an account with its own `gtk.css` and accent is left alone.
- `restart`: the graceful restart. Clean apps restart in the new palette;
  an app holding unsaved text keeps its own "Save changes?" dialog up and is
  not relaunched. `fixtures/notes.py` is that app.
- `picker`: screenshots the picker and its restart dialog.
- `leaks`: stock showing through, found by what does not move. Every
  visible Shell widget on nine surfaces (the desktop menu, the date menu,
  quick settings and a submenu, the app grid and an icon's menu, the run
  dialog, an OSD, a banner) is read in every state it can take -- hover,
  focus, active, checked, selected, insensitive -- under Gruvbox light and
  Nord dark: background, border, and the text color its labels and icons
  actually inherit. A color identical under two unrelated themes did not
  come from the theme. It also forces every quick toggle checked and fails
  unless each resolves to the theme's accent, so a leak fix can never cost
  an accent-filled state. `leaks-report.json` lands in `GATE_OUT`.

## Stock-grey leaks without a Shell

`stock_states.py` is the static half, and `tests/theme.bats` runs it on
every build that has GNOME Shell's gresource (a toolbox reads the host's).
Stock paints its controls in fixed greys chosen for its own grey menus;
every stock selector that paints one and that the theme's Shell sheet does
not restate shows as a grey slab on a themed surface -- a control the sheet
never names, or a state of one it does, since `.button:active:hover` beats
the sheet's `.button:active` whatever the load order.

    stock_states.py check    # every such selector the sheet leaves to stock
    stock_states.py emit     # the restatements, for the block in gnome-shell.css

The block opens the sheet so every hand-written rule wins a tie with it.
Families in the script map each selector onto the sheet's own washes; a
selector no family claims is an error, and anything left stock on purpose
(Looking Glass, the login and lock screens, the screenshot UI, the
on-screen keyboard) is listed in `ALLOW` with its reason. It sees
backgrounds only; text that stock fixes to one scheme is the `leaks`
scan's job.

`bin/systemd-run` exists because the container has no user manager and
Ptyxis wraps every shell in `systemd-run --user --scope`.
