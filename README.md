# Pulsar

A personal Fedora Silverblue 44 derivative, built as a bootc image.

Base: `quay.io/fedora-ostree-desktops/silverblue:44` — pure Fedora, no
Universal Blue inheritance.

Target hardware: Intel Core Ultra 9 275HX (Arrow Lake-HX, 8P + 16E, no SMT),
NVIDIA RTX 5080 Max-Q (Blackwell GB203) + Arrow Lake iGPU, 2560×1600 eDP,
62 GB RAM.

## Layout

```
Containerfile          -> ghcr.io/arclight-digital/pulsar          vanilla
Containerfile.nvidia   -> ghcr.io/arclight-digital/pulsar-nvidia   FROM vanilla, signs
.github/workflows/
  build.yml            builds, signs, pushes and attests BOTH images
assets/           source of truth — edit these
  icons/          pulsar-mark{,-mono}.svg, -1024.png, tile cuts, favicons
  fonts/          Host_Grotesk/, JetBrains_Mono/ (Google Fonts drops)
system_files/          overlay for vanilla; branding here is GENERATED
system_files.nvidia/   overlay for the nvidia variant only
scripts/
  sync-branding.sh   assets/ -> system_files/   (run when art changes)
  build.sh           local TEST builds only; CI ships the real ones
```

## Two variants

`Containerfile` declares **no build secrets** — nothing in the vanilla image
needs the signing key. `Containerfile.nvidia` uses it, and both images are
published publicly. That is safe: the key is a build secret that never lands
in a layer, and the module it produces is `nvidia-open`, which is MIT/GPLv2
dual-licensed. The proprietary part is the userspace, redistributed here the
same way RPM Fusion redistributes it — with its license text intact under
`/usr/share/licenses`.

Vanilla exists as its own artifact for two reasons beyond hygiene: it is what
you enroll the MOK from before the driver is in play (see Installing), and it
is the fallback to rebase onto if an nvidia build ever goes bad.

**If you are not me and you want to run this:** build it yourself with your
own signing key. Enrolling `MOK.der` from this repo means your machine
permanently trusts kernel modules signed by my key, which is a trust
relationship you almost certainly do not want with a stranger's laptop.

Local test builds run as root — not because vanilla needs privileges, but
because the nvidia variant derives `FROM` the vanilla image and rootless and
rootful podman keep separate container storage.

The nvidia variant regenerates the initramfs a second time. `nvidia-pulsar.conf`
sets modprobe options that live in the initramfs, and vanilla's `dracut` run
happens before that file exists.

Do not hand-edit branding under `system_files/usr/share/{icons,pixmaps,fonts}`
or the plymouth watermark — `sync-branding.sh` overwrites all of it. Change
`assets/` and re-run:

```bash
./scripts/sync-branding.sh
```

Everything else under `system_files/` is hand-written and safe to edit.

## Branding, as wired

| Slot | Source | Generated |
|---|---|---|
| GNOME About | `icons/pulsar-mark.svg` | `hicolor/scalable/apps/pulsar-logo-icon.svg` |
| Icon theme | `icons/pulsar-mark-1024.png` | `hicolor/{512,256,128,64,48}/apps/*.png` |
| GDM login | `icons/pulsar-mark-mono-1024.png` | `pixmaps/fedora-gdm-logo.png` @192px |
| Boot splash | `icons/pulsar-mark-mono-1024.png` | `plymouth/themes/pulsar/watermark.png` @320px |

`fedora-gdm-logo.png` keeps the Fedora filename deliberately — GDM's config
points at that literal path, so overwriting is one file where renaming would
mean shipping a GDM config override too.

GDM and plymouth use the **mono** cut because both land on dark backgrounds
with no theme awareness and no contrast guarantee. Verified white-on-transparent.

`assets/icons/pulsar-tile*` is the rounded-square cut and is **unused** — that
form is an app-icon convention and reads as a floating rectangle on GDM's and
plymouth's dark surfaces. Keep it for an ISO or launcher icon later.

The plymouth watermark is a fixed 320px because plymouth does not scale it.
Sized for 2560×1600; bump it in `sync-branding.sh` if the display changes.

## Fonts

**Host Grotesk** (UI) and **JetBrains Mono** (monospace), static cuts only,
28 faces total. Both licensed OFL; `OFL.txt` ships alongside each family
because the image is redistribution.

Static-only is deliberate. The variable and static files report the *same*
family name, so shipping both makes fontconfig arbitrate between a static
Bold and the variable font's Bold named instance, and which wins depends on
scan order. Pick one form. If you switch to variable, delete the statics.

Family names must match `system_files/usr/share/glib-2.0/schemas/zz0-pulsar.gschema.override`:

```
Host Grotesk
JetBrains Mono
```

`sync-branding.sh` prints the scanned family names at the end so a drift
between the fonts and the gschema is visible immediately.

## How it is built

Both images are built, signed, and pushed by `.github/workflows/build.yml`:
vanilla first, then nvidia layered on it, both to
`ghcr.io/arclight-digital/pulsar{,-nvidia}` with build-provenance
attestations. The machine running Pulsar builds nothing.

The Secure Boot signing key lives in the repo secrets `AKMODS_PRIV` and
`AKMODS_CERT` (base64 DER). That is a deliberate trade: the OS image already
comes from CI, so a compromise there owns the machine with or without the
signing key. The workflow writes the key only to tmpfs and shreds it in an
`always()` step.

`system_files/etc/pki/pulsar/MOK.der` is the PUBLIC half of that key, and it
must match `AKMODS_CERT`. Phase 5 of `Containerfile.nvidia` fails the build if
the module's signer does not match the shipped cert — a stale cert becomes a
red CI run instead of a black screen.

Verify a published image yourself:

```bash
gh attestation verify oci://ghcr.io/arclight-digital/pulsar-nvidia:44 \
  --owner arclight-digital
```

## Installing

Same shape as Fedora Silverblue with rpmfusion nvidia: get on the image,
enroll the key, then turn on the driver. **Enroll from the vanilla image
first.** Both variants ship the cert precisely so the key can be trusted
before anything depends on it — rebasing straight onto nvidia with Secure
Boot on and the key not yet enrolled means the module is refused at load.

On a machine already running Fedora Silverblue:

```bash
sudo bootc switch ghcr.io/arclight-digital/pulsar:latest
sudo systemctl reboot
```

(For bare metal instead, `bootc install to-disk` from the same image.)

Then enroll the key. `mokutil` asks for a one-time password that you will
retype at the firmware screen on the next boot — it is not your login
password, and it is used exactly once:

```bash
sudo mokutil --import /etc/pki/pulsar/MOK.der
sudo systemctl reboot
```

The next boot stops in **MokManager**, a blue firmware-level screen. It is
not the bootloader and it will not appear again:

    Enroll MOK  ->  View key 0  ->  Continue  ->  Yes  ->  (password)  ->  Reboot

Confirm it took, then take the driver:

```bash
mokutil --sb-state                          # SecureBoot enabled
mokutil --test-key /etc/pki/pulsar/MOK.der  # ...is already enrolled
sudo bootc switch ghcr.io/arclight-digital/pulsar-nvidia:latest
sudo systemctl reboot
```

Verify the driver actually loaded and is the signed, open one:

```bash
modinfo -F signer nvidia     # the CN of the enrolled cert
nvidia-smi                   # the GPU
```

If MokManager is skipped or the password is mistyped, nothing breaks — the
enrollment simply does not happen. Re-run `mokutil --import` and reboot.

## Updates

Stock Silverblue behaviour, deliberately: GNOME Software checks and tells you
an update is available, and it installs when you choose to restart. Nothing
in this image changes update policy, and bootc's `fetch-apply-updates.timer`
is left disabled on purpose — it runs `bootc upgrade --apply`, which reboots
on its own.

CI rebuilds nightly, so new kernels, security updates, and driver bumps show
up as a normal update notification.

To pull one immediately instead of waiting:

```bash
sudo bootc upgrade      # stages it; reboot when you want it
```

## Notes

- **Do not add `akmod-nvidia`.** Blackwell is nvidia-open only. Your current
  host has both installed; the closed one is dead weight.
- **Do not `dnf install akmods-keys` in the Containerfile.** That RPM contains
  the private key and would ship to anyone who pulls the image.
- The `dracut` regen must stay the last real step — the initramfs carries both
  the plymouth theme and the nvidia modprobe options.
- Governor stays `powersave`. On `intel_pstate` with HWP that is the correct
  setting, not a slow one; use `tuned` profiles to shift behaviour instead.
- `sync-branding.sh` does not trim the art. The marks carry a gaussian glow
  whose alpha extends past the geometry, and trimming clips it.
