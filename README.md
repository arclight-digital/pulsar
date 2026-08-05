<img src="assets/brand/pulsar-mark.svg" width="140" alt="Pulsar">

# Pulsar

Fedora Silverblue with the sharp edges filed off, shipped as a bootc image.
Built directly on the official Fedora base. GitHub builds
and signs it; the machine that runs it never compiles anything.

**Built for:** Intel Core Ultra 9 275HX (Arrow Lake-HX, 8 P-cores + 16 E-cores,
no SMT), NVIDIA RTX 5080 Max-Q (Blackwell GB203) alongside the Arrow Lake iGPU,
2560×1600 eDP, 62 GB RAM. The nvidia variant assumes that GPU. The vanilla
image assumes nothing and runs anywhere.

```bash
sudo bootc switch ghcr.io/arclight-digital/pulsar:latest          # no GPU driver
sudo bootc switch ghcr.io/arclight-digital/pulsar-nvidia:latest   # + nvidia-open
```

## What's in it

Branding, Host Grotesk + JetBrains Mono, a plymouth theme, and the papercuts
already fixed. `scx_bpfland` takes over scheduling, because that core layout is
exactly where stock EEVDF places threads badly. Unfiltered Flathub, shipped as
an image-native remote so it survives a rebase. Split-lock mitigation off and
`vm.max_map_count` raised, because several games need both. `ntsync` is loaded
and given to the seat user, so Proton can use it where the build supports it.

`greenboot` checks each boot and rolls back automatically after three failures.
The required check is that the desktop actually came up — the one failure you
cannot type your way out of. Scheduler and network are warn-only, because a
scheduler that fails to attach still leaves a usable machine, and a laptop that
boots with no network is not a broken deployment.

System-level capability only: `gamescope`, `gamemode`, `mangohud`,
`steam-devices`, `distrobox`, `libvirt`, `android-tools`, `gnome-tweaks`,
`greenboot`.

For development: `bpftrace`, `bcc-tools`, `sysstat` and `perf`, which have to
be on the host because a container cannot attach probes to the host kernel.
`mise` and `direnv` handle toolchains, so compilers and SDKs are pinned per
project instead of layered into the image. A default dev box is described in
`/usr/share/pulsar/distrobox.ini`:

```
distrobox assemble create --file /usr/share/pulsar/distrobox.ini
```

`podman-auto-update.timer` is enabled for user sessions, and a commented
quadlet template lives at `/usr/share/pulsar/templates/example.container` —
containers as systemd units, rootless, in a file you can version.

[`gamescale`](https://github.com/arclight-digital/gamescale) ships at a pinned
tag: the script at `/usr/bin/gamescale`, its top-bar indicator installed
system-wide and enabled by default, and a reconcile unit that restores your
scale if a game dies without cleaning up.

For **native** launchers and terminal use that is everything, and a machine
that never installs anything still recovers its scale after a crash.

For **Flatpak** launchers it is not enough, and the reason is categorical
rather than a papercut. Flatpak reserves `/usr` for the runtime and refuses to
share the host's:

```
$ flatpak run --command=sh --filesystem=/usr/bin/gamescale:ro com.valvesoftware.Steam
F: Not sharing "/usr/bin/gamescale" with sandbox: Path "/usr" is reserved by Flatpak
```

The `/usr` a Flatpak sees is the runtime's, so no grant can ever expose
`/usr/bin/gamescale` to Steam. Upstream defaults to `~/.local/bin` because a
home path is the only kind that maps in. To grant a launcher, run the
installer:

```
curl -fsSL https://raw.githubusercontent.com/arclight-digital/gamescale/main/install.sh | sh -s -- --platform steam
```

**Doing that shadows the image copy, and that is the intended outcome.** User
paths win every collision: your shell finds `~/.local/bin` before `/usr/bin`,
GNOME prefers a user extension over a system one with the same uuid, and
systemd prefers a user unit over `/usr/lib/systemd/user`. So after running the
installer you are using its copy of all three, and the image's copies sit
inert underneath — one of each runs, never both.

The image pins a tag; your `~/.local` copy is whatever you last installed. They
can therefore differ. Both being releases of the same tool this is normally
harmless, but if you are chasing odd behaviour, `gamescale --version` tells you
which one you are actually running.
Anything you merely *run* is a Flatpak. This image is the OS.

The nvidia variant builds `nvidia-open` against the image's exact kernel and
signs it. Blackwell has no closed-driver option, which is fine — the open
module is the better one now anyway.

## Two variants, one key

`Containerfile` declares no build secrets, so it is safe to build anywhere.
`Containerfile.nvidia` uses the Secure Boot signing key, which lives in the
repo secrets `AKMODS_PRIV` / `AKMODS_CERT` and never reaches an image layer.

`system_files/etc/pki/pulsar/MOK.der` is the public half. It ships in **both**
images so the key can be enrolled before the driver is in play. The nvidia
build fails if the module's signer doesn't match that cert — a stale cert
becomes a red CI run instead of a black screen at boot.

**Running this yourself?** Fork it and use your own key. Enrolling my cert
means your machine permanently trusts modules I sign, which is not a
relationship you want with a stranger's laptop. The vanilla image needs no
keys at all.

## Install

```bash
sudo bootc switch ghcr.io/arclight-digital/pulsar:latest
sudo systemctl reboot
```

Enroll the key. `mokutil` asks for a password you'll retype at the firmware
screen on the next boot — used once, then never again:

```bash
sudo mokutil --import /etc/pki/pulsar/MOK.der
sudo systemctl reboot
```

The next boot stops in **MokManager**, a blue firmware screen:
`Enroll MOK` → `View key 0` → `Continue` → `Yes` → password → reboot.

Then take the driver:

```bash
mokutil --test-key /etc/pki/pulsar/MOK.der   # ...is already enrolled
sudo bootc switch ghcr.io/arclight-digital/pulsar-nvidia:latest
sudo systemctl reboot
```

Check it: `modinfo -F signer nvidia` and `nvidia-smi`.

Miss the MokManager prompt and nothing breaks — the enrollment just doesn't
happen. Run `mokutil --import` again.

## Updates

Stock Silverblue behaviour, on purpose. GNOME Software notices and tells you;
it installs when you choose to restart. bootc's `fetch-apply-updates.timer` is
left disabled deliberately — it reboots on its own.

CI rebuilds nightly, so kernels, security updates, and driver bumps arrive as
a normal update notification. Impatient: `sudo bootc upgrade`.

## Working on it

```
Containerfile          -> ghcr.io/arclight-digital/pulsar
Containerfile.nvidia   -> ghcr.io/arclight-digital/pulsar-nvidia
.github/workflows/build.yml   builds, signs, pushes, attests both
assets/                source of truth for art — edit these
system_files/          overlay for vanilla (branding here is GENERATED)
system_files.nvidia/   overlay for nvidia only
scripts/sync-branding.sh   assets/ -> system_files/
scripts/build.sh           local TEST builds; CI ships the real ones
```

Push to `main` and CI does the rest. `build.sh` is only for checking a
Containerfile edit before it gets there, and it needs root — the nvidia
variant derives `FROM` the vanilla image, and rootless and rootful podman
keep separate storage.

Every published image carries a provenance attestation:

```bash
gh attestation verify oci://ghcr.io/arclight-digital/pulsar-nvidia:44 \
  --owner arclight-digital
```

### Branding

Don't hand-edit `system_files/usr/share/{icons,pixmaps,fonts}` or the plymouth
watermark — `sync-branding.sh` overwrites all of it from `assets/`.

| Slot | Source | Generated |
|---|---|---|
| Icon theme | `brand/pulsar-mark{,-1024}` | `hicolor/*/apps/pulsar-logo-icon.*` |
| GDM login | `pulsar-mark-mono-1024.png` | `pixmaps/fedora-gdm-logo.png` @192px |
| Boot splash | `pulsar-lockup-horizontal.png` | `plymouth/themes/pulsar/watermark.png` |
| About panel (dark) | `pulsar-lockup-horizontal.png` | `pixmaps/fedora_whitelogo_med.png` @279×80 |
| About panel (light) | `pulsar-lockup-horizontal-color-dark.png` | `pixmaps/fedora_logo_med.png` @279×80 |

GDM gets the **mono** cut (grey ground, no contrast guarantee); plymouth
gets the color mark -- its ground is the same near-black as the wallpapers.

Three of these keep Fedora's filenames on purpose. GDM's config and
gnome-control-center both point at those literal paths, so overwriting one
file beats shipping a config override or patching a binary. In particular the
About panel does **not** use `LOGO=` from os-release — that's a square icon,
and the panel wants a horizontal lockup, chosen by theme. The lockups are
authored art in assets/brand; light surfaces use the authored *-color-dark
cuts, because the white-wordmark originals vanish on a pale background.

The plymouth watermark is a fixed 320px because plymouth won't scale it; sized
for 2560×1600.

### Fonts

Host Grotesk (UI) and JetBrains Mono (mono), **static cuts only**. The
variable and static files report the same family name, so shipping both makes
fontconfig arbitrate between a static Bold and the variable font's Bold named
instance, and scan order decides the winner. Pick one form.

Family names must match `zz0-pulsar.gschema.override`. `sync-branding.sh`
prints what it scanned so drift is obvious.

## Notes

- **Never `dnf install akmods-keys`.** That RPM contains the private key and
  would ship it to everyone who pulls the image.
- **Never add `akmod-nvidia`.** Blackwell is nvidia-open only; the closed
  akmod also collides with `-open` and silently downgrades it.
- The `dracut` regen stays the last real step — the initramfs carries both the
  plymouth theme and the nvidia modprobe options.
- The nvidia build pulls its akmod from `updates-testing`. Stable's `-open`
  doesn't compile against kernel 7.1 yet; drop the `--enablerepo` once 610
  lands in stable.
- Governor stays `powersave`. On `intel_pstate` with HWP that's correct, not
  slow — use `tuned` profiles to shift behaviour.
- `sync-branding.sh` doesn't trim the art. The marks carry a gaussian glow
  whose alpha extends past the geometry, and trimming clips it.

## License

MIT — see [LICENSE](LICENSE). Fonts are OFL; the NVIDIA userspace driver is
proprietary and redistributed as RPM Fusion packages it.
