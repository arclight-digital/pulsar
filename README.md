<p align="center">
  <img src="assets/brand/pulsar-mark.svg" width="140" alt="">
</p>

<h1 align="center">Pulsar</h1>

<p align="center">
  <strong>Your lighthouse in the sky.</strong><br>
  An immutable Fedora for gaming and development, built and signed entirely in CI.
</p>

<p align="center">
  <a href="https://pulsar.arclight.digital">pulsar.arclight.digital</a>
</p>

Fedora Silverblue with the sharp edges filed off, shipped as a bootc image on
the official Fedora base. CI builds, signs, and attests every image nightly;
the machine that runs one never compiles anything, the system is the same
every boot, and the last good version is always one reboot away.

```bash
sudo bootc switch ghcr.io/arclight-digital/pulsar:latest          # runs anywhere
sudo bootc switch ghcr.io/arclight-digital/pulsar-nvidia:latest   # + signed nvidia-open
```

**Built for** an Intel Core Ultra 9 275HX (Arrow Lake-HX: 8 P-cores + 16
E-cores, no SMT), an RTX 5080 Max-Q (Blackwell GB203) beside the Arrow Lake
iGPU, a 2560×1600 panel, 62 GB RAM. The nvidia variant assumes that GPU. The
vanilla image assumes nothing.

```text
> pulsar manifest
scaling     gamescale · 1× on demand
boot        greenboot · auto-rollback
display     gamescope · gamemode · mangohud
wine        ntsync
containers  distrobox · toolbox
virt        libvirt · qemu-kvm
tooling     android-tools · gnome-tweaks
dev         mise · direnv · bpftrace · perf
driver      nvidia-open, built + signed in CI
apps        unfiltered Flathub, image-native
base        Fedora Silverblue 44
```

## What's in it

Branding, Host Grotesk + JetBrains Mono + Nimbus Sans bound all the way down
to fontconfig's generics, a plymouth theme, and the papercuts already fixed.
Unfiltered Flathub, shipped as an image-native remote so it survives a
rebase. Split-lock mitigation off and `vm.max_map_count` raised,
because several games need both. `ntsync` loaded and handed to the seat user,
so Proton can use it where the build supports it. System-level capability
only: `gamescope`, `gamemode`, `mangohud`, `steam-devices`, `distrobox`,
`libvirt`, `android-tools`, `gnome-tweaks`, `greenboot`.

Anything you merely *run* is a Flatpak. This image is the OS.

### Boots that check themselves

`greenboot` checks each boot and rolls back automatically after three
failures. The required check is that the desktop actually came up — the one
failure you cannot type your way out of. It waits for a graphical session on
a seat, never for `graphical.target`: the health check runs *inside* the
transaction that target is waiting on, so waiting for it can only ever time
out. Scheduler and network are warn-only, because a scheduler that fails to
attach still leaves a usable machine, and a laptop that boots with no network
is not a broken deployment.

### A scheduler that is honest about itself

`scx_bpfland` takes over scheduling, because 8P+16E with no SMT is exactly
where stock EEVDF places threads badly — and it is gated on the kernel the
image ships. Fedora's 7.1.5 and 7.1.6 publish 38 scx kfuncs with the implicit
`struct bpf_prog_aux *` still in their BTF prototypes, so every BPF scheduler
fails to load, `bpfland` and `lavd` alike.
`ConditionPathExists=/sys/kernel/sched_ext` cannot see this: the feature is
present, it just cannot be used. So the build asks
(`scripts/check-scx-btf.sh`) and drops `/usr/lib/pulsar/scx-supported` only
when the answer is yes; `scx.service` conditions on that marker and is
skipped rather than failed three times per boot. When Fedora ships a fixed
kernel the marker reappears and the scheduler comes back with no change here.
`pulsar doctor` reports it as `ok` with the reason, not as a warning you
cannot act on.

## The `pulsar` command

```text
pulsar doctor        health snapshot, exit 1 if a check fails
pulsar manifest      what is in this image, and what it is running on
pulsar status        deployments: booted, staged, rollback, pins
pulsar changelog     packages that moved in the latest published build
pulsar sbom          this system's packages as SPDX 2.3
pulsar attest        print (and run) the provenance check for this image
pulsar update        fetch and stage an update      (root)
pulsar rollback      boot the previous deployment   (root)
pulsar pin | unpin   protect the booted deployment  (root)
pulsar setup <recipe>   devbox | quadlet | gamescale
```

`doctor` exists for one reason. `systemctl is-active scx.service` reported
active for minutes at a stretch while no scheduler was attached and the
machine ran stock EEVDF — unit state is not system state. So `doctor` reads
`/sys/kernel/sched_ext/state` and the other places where the truth actually
lives, and `--json` makes it scriptable. Only a `fail` sets a nonzero exit;
a scheduler that did not attach merely warns, because the machine is entirely
usable without one.

Reads go through `rpm-ostree`, which works unprivileged; only the commands
that change the system ask for root. `bootc status` needs root even to read,
and a health check you need sudo for is one you will not run.

`pulsar sbom` is generated, never baked — a file inside the image cannot
describe the image containing it, so it reads the live rpm database, through
the same script CI uses.

## For development

`bpftrace`, `bcc-tools`, `sysstat` and `perf` are on the host because a
container cannot attach probes to the host kernel. `mise` and `direnv` handle
toolchains, so compilers and SDKs are pinned per project instead of layered
into the image. A default dev box is one command away:

```bash
pulsar setup devbox    # distrobox assemble from /usr/share/pulsar/distrobox.ini
```

`podman-auto-update.timer` is enabled for user sessions, and a commented
quadlet template lives at `/usr/share/pulsar/templates/example.container` —
containers as systemd units, rootless, in a file you can version
(`pulsar setup quadlet`).

## gamescale

Run a game at 1× monitor scale so XWayland hands it the panel's real mode,
then put the desktop back when it exits — including when it doesn't exit
cleanly. [`gamescale`](https://github.com/arclight-digital/gamescale) ships
at a pinned, hash-verified tag: the script at `/usr/bin/gamescale`, its
top-bar indicator enabled system-wide, and a reconcile unit that restores
your scale if a game dies without cleaning up.

For **native** launchers and terminal use that is everything, and a machine
that never installs anything still recovers its scale after a crash.

For **Flatpak** launchers it is not enough, and the reason is categorical
rather than a papercut. Flatpak reserves `/usr` for the runtime and refuses
to share the host's:

```console
$ flatpak run --command=sh --filesystem=/usr/bin/gamescale:ro com.valvesoftware.Steam
F: Not sharing "/usr/bin/gamescale" with sandbox: Path "/usr" is reserved by Flatpak
```

The `/usr` a Flatpak sees is the runtime's, so no grant can ever expose
`/usr/bin/gamescale` to Steam. A copy under `$HOME` is the only kind that
maps in, which means granting a launcher always means running the installer:

```bash
pulsar setup gamescale --platform steam
```

That runs the installer copy staged in the image — offline, pinned, matching
the image exactly. (Upstream's `curl | sh` from the gamescale README works
too; it just fetches whatever is current rather than what the image pinned.)

**The install shadows the image copy, and that is the intended outcome.**
User paths win every collision: your shell finds `~/.local/bin` before
`/usr/bin`, GNOME prefers a user extension over a system one with the same
uuid, and systemd prefers a user unit over `/usr/lib/systemd/user`. One of
each runs, never both — and if you are chasing odd behaviour,
`gamescale --version` tells you which copy you are actually running.

## Two variants, one key

The nvidia variant builds `nvidia-open` against the image's exact kernel and
signs it. Blackwell has no closed-driver option, which is fine — the open
module is the better one now anyway.

`Containerfile` declares no build secrets, so it is safe to build anywhere.
`Containerfile.nvidia` uses the Secure Boot signing key, which lives in the
repo secrets `AKMODS_PRIV` / `AKMODS_CERT` and never reaches an image layer.

`system_files/etc/pki/pulsar/MOK.der` is the public half. It ships in
**both** images so the key can be enrolled before the driver is in play. The
nvidia build fails if the module's signer doesn't match that cert — a stale
cert becomes a red CI run instead of a black screen at boot.

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
it installs when you choose to restart. bootc's `fetch-apply-updates.timer`
is left disabled deliberately — it reboots on its own.

CI rebuilds nightly, so kernels, security updates, and driver bumps arrive as
a normal update notification. Impatient: `sudo pulsar update`.

Use `pulsar update` rather than `bootc upgrade` directly if you have layered
anything with `rpm-ostree install`. bootc's model is the container image alone
— it does not know about your layer and will not carry it forward. `pulsar
update` checks the booted deployment first and hands off to `rpm-ostree
upgrade` when there is something to preserve; `pulsar doctor` tells you which
side of that line you are on.

## Every image has a paper trail

Every published image carries SLSA provenance. Don't take this README's word
for anything:

```bash
gh attestation verify oci://ghcr.io/arclight-digital/pulsar-nvidia:latest \
  --owner arclight-digital
```

That tool is not in the image, and does not need to be — checking provenance
is something you do *to* an image, from whatever machine you already trust.
`pulsar attest` prints the same line, filled in for the image you booted, and
runs it if you happen to have the client.

An SPDX SBOM ships attached to each image
(`oras discover ghcr.io/arclight-digital/pulsar:latest`), and every nightly
is diffed against the one before it, package by package, from those SBOMs —
rendered at [pulsar.arclight.digital](https://pulsar.arclight.digital),
served raw as [changelog.json](https://pulsar.arclight.digital/changelog.json),
and readable on the machine as `pulsar changelog`. Nothing in it is written
by hand.

## Working on it

```text
Containerfile          -> ghcr.io/arclight-digital/pulsar
Containerfile.nvidia   -> ghcr.io/arclight-digital/pulsar-nvidia
.github/workflows/build.yml   builds, signs, pushes, attests both (nightly)
.github/workflows/iso.yml     weekly installer ISOs, checksummed + signed
assets/                source of truth for art — edit these
system_files/          overlay for vanilla (branding here is GENERATED)
system_files.nvidia/   overlay for nvidia only
scripts/sync-branding.sh   assets/ -> system_files/
scripts/build.sh           local TEST builds; CI ships the real ones
site/                  the one-pager (Astro); Cloudflare builds it on push
site/src/data/         written by the nightly — never edit by hand
```

Push to `main` and CI does the rest. `build.sh` is only for checking a
Containerfile edit before it gets there, and it needs root — the nvidia
variant derives `FROM` the vanilla image, and rootless and rootful podman
keep separate storage.

## Field notes

- **Never `dnf install akmods-keys`.** That RPM contains the private key and
  would ship it to everyone who pulls the image.
- **Never add `akmod-nvidia`.** Blackwell is nvidia-open only; the closed
  akmod also collides with `-open` and silently downgrades it.
- The `dracut` regen stays the last real step — the initramfs carries both
  the plymouth theme and the nvidia modprobe options.
- The nvidia build pulls its akmod from `updates-testing`. Stable's `-open`
  doesn't compile against kernel 7.1 yet; drop the `--enablerepo` once 610
  lands in stable.
- Governor stays `powersave`. On `intel_pstate` with HWP that's correct, not
  slow — use `tuned` profiles to shift behaviour.

## License

MIT — see [LICENSE](LICENSE). The fonts are OFL and travel with their
license; the NVIDIA userspace driver is proprietary, redistributed as the
RPM Fusion packages that carry it.
