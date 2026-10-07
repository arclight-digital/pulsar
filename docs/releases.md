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

## 26.10.1

Pulsar's own installer, Pulsar Settings, and glass everywhere.

### Installer

- The ISO starts straight into Pulsar's own installer, which replaces
  Anaconda.
- Every disk is listed with its size, what is on it and its device name,
  so two drives of the same model can't be mistaken for each other. The
  USB stick the installer runs from is never offered, and no other disk is
  touched.
- Install beside Windows in 36 GB of free space, or erase the disk. Before
  an erase, the installer lists every partition that will be deleted and
  asks you to confirm. Nothing is written until you press Erase and Install
  on the last page.
- Beside Windows, Windows' partitions and boot files are left as they are,
  and Windows is added to the startup menu. A disk with BitLocker on is
  refused until it is turned off in Windows.
- Disk encryption is on by default, and you can turn it off. The
  passphrase prompt at startup uses the keyboard layout the passphrase
  was typed in.
- A failed install removes the partitions it made and says what state the
  disk is in. The window can't be closed while the install is writing to
  the disk.

### Pulsar Settings

- A new app for what GNOME Settings has no room for. Appearance has the
  theme and every glass and lighting switch. Updates shows the release and
  image, checks for an update, downloads it and restarts into it, rolls
  back to the previous image, and keeps the current one from being cleaned
  up.
- The gear in Themes opens it, and so does the last page of the welcome.

### Glass and light

- Menus, OSDs, notification banners, dialogs and the dash are clearer:
  what is behind them keeps its shapes, softly blurred.
- The overview stands on the blurred wallpaper. Its search box and the
  dash's labels are lit glass.
- In apps, menus, popovers, floating dialogs and Files' file area are
  glass too.
- Alt+Tab's thumbnails, window previews in the overview and "not
  responding" dialogs get glass.
- File choosers and other windows that Flatpak apps open through the
  system are blurred like every other window. Before, they were
  see-through with the app behind them sharp.
- In the notification list under the clock, a collapsed group shows the
  notifications behind the newest as slivers, each a step darker, as stock
  GNOME does. Before, they showed through the one in front, text and all.
- Floating glass casts a soft shadow in the theme's own deep color.
- Glass turns off in Power Saver (a switch, on by default) and, if you
  want, while a game is running. A fullscreen game stops every blur
  beneath it and over it, and fullscreen apps are solid.

### Themes

- Four new themes: Eclipse, a pearl corona with a rose rim; Regolith,
  lunar dust and an amber gauge; Magnetosphere, green aurora over polar
  night; and Redshift, receding light in a plum dusk. Eclipse and
  Magnetosphere are dark only.
- A theme's blue or purple accent reaches GNOME as blue or purple, not
  gray.
- A theme with only one mode keeps it when Dark Style is flipped.

### Gaming

- Flatpak Steam runs `gg`, `ggm` and `gamescale` from the image, with no
  setup. If you set them up on an older image, quit Steam and run
  `pulsar setup gamescale` once to move to the image's copies. While Steam
  is open it keeps the old copies, so launches keep working until Steam
  restarts.
- On NVIDIA, the Steam client's window draws at the display's refresh
  rate instead of pausing for up to a tenth of a second. Games keep their
  own vsync setting.
- When Steam's window stops redrawing after a resume on NVIDIA, Pulsar
  restarts the stuck process.

### Crashes

- A crash notification has an "Ignore this" button, and
  `pulsar crashes ignore` lists and edits what is ignored. A Proton game
  that crashes as it quits no longer interrupts you.

### Under the hood

- Image signatures are logged in Rekor. `pulsar verify` checks the running
  image's signature and its log entry.
- The sched_ext scheduler loads on machines installed by Pulsar's
  installer, which never had the kernel config file it needed.
- AGENTS.md, the briefing coding agents read, is rewritten: shorter, and
  checked against the system.
- A rare misread is fixed: the first boot's install of the default apps
  could report an installed app as missing and keep retrying, and
  `pulsar checkpoint restore` could miss an update staged since the
  checkpoint and leave it to boot next.

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
