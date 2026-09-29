# Releases

- **Releases** (`YY.M.N`, written up here) are changes to what Pulsar adds
  on top of Silverblue: the year, the month, and that month's release
  number, so `26.9.1` is September 2026's first. The About page, the boot
  menu, `pulsar manifest` and `pulsar doctor` all show it.
- **Nightly builds** (`44.20260929.0`) carry each day's Fedora and Silverblue
  updates, listed in the [nightly changelog](/docs/changelog), generated from
  the images.

Releases ship inside a nightly; both arrive through the same update. The two
move independently: a month with no new Pulsar features keeps its release
while the builds go on, so the About page may read
`Pulsar 26.9.1 (44.20261103.0)` in November.

## 26.9.1

The first numbered release: Pulsar's own look, and glass.

### Themes

- 20 themes, each recoloring the whole desktop in one step: GNOME Shell, GTK
  4 and GTK 3 apps, the terminal, Text Editor, btop, coding agents and the
  wallpaper. Two-mode themes follow Dark Style on their own.
- The theme picker (Super+T) shows every theme as a card in its own colors;
  `pulsar theme set <name>` does the same from a terminal, and
  `pulsar theme revert` puts stock GNOME back.
- Flatpak apps are themed by default, and GTK 3 apps follow Dark Style.
- btop gets the theme's own colors in light themes too, instead of labels
  drawn in pale gray.

### Glass and light

- Menus, the top bar, OSDs, notification banners and app windows go
  translucent over a live blur of whatever is really beneath them, redrawn
  every frame, so it keeps up with a window dragged across it.
- Light: the button that opened a menu glows, the menu's rim is lit from it,
  and the edge warms when the battery runs low.
- App windows get a little glass too, with their cards kept solid and lifted
  so they stay readable.
- Every effect is its own switch, in the picker's Effects panel and the
  Pulsar Theme page of the Extensions app, with a tint slider and a Reset.
  High contrast turns them all off.

### Under the hood

- The sched_ext scheduler (scx_bpfland) runs again on Fedora's 7.2 kernels.
  Two things had kept it off: a build check that misread the kernel, and a
  missing link to the kernel config that every BPF scheduler needs.
  `pulsar doctor` now names that second cause if it ever comes back.
- `pulsar manifest` and `pulsar doctor` show the release beside the nightly
  build.
