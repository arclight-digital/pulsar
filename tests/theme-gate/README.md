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

`bin/systemd-run` exists because the container has no user manager and
Ptyxis wraps every shell in `systemd-run --user --scope`.
