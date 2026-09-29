# Releases

Pulsar has two kinds of change, and two changelogs for them.

**Releases** are Pulsar's own: new features and fixes to what Pulsar adds on
top of Silverblue. They are numbered `MAJOR.MINOR.PATCH` and written up here.
Settings' About page and the boot menu call a release by its first two
numbers ("Pulsar 1.0"); `pulsar manifest` and `pulsar doctor` show all three.

**Nightly builds** carry everything else: each night's image picks up the
Fedora and Silverblue updates published that day, and gets a build number like
`44.20260929.0`. Those are listed package by package in the
[nightly changelog](/docs/changelog), generated from the images themselves.
You get both the same way, from the same update: releases ship inside a
nightly.

## 1.0.0

The first numbered release: Pulsar's own look, and glass.

### Themes

- 16 themes, each recoloring the whole desktop in one step: GNOME Shell, GTK
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
