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

Fedora Silverblue as a bootc image, rebuilt every night by an ephemeral build
host that signs and attests what it ships. The machine that runs it never
compiles anything; the last good version is always one reboot away.

```bash
sudo bootc switch ghcr.io/arclight-digital/pulsar:latest          # runs anywhere
sudo bootc switch ghcr.io/arclight-digital/pulsar-nvidia:latest   # + signed nvidia-open
```

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

Built for one laptop: a Core Ultra 9 275HX (8P+16E, no SMT), an RTX 5080
Max-Q beside the iGPU, a 2560×1600 panel. The nvidia variant assumes that
GPU; the vanilla image assumes nothing.

## What's in it

Branding down to fontconfig's generics, a plymouth theme, unfiltered Flathub
as an image-native remote, split-lock mitigation off and `vm.max_map_count`
raised for the games that need both, `ntsync` handed to the seat user for
Proton. System-level capability only — `gamescope`, `gamemode`, `mangohud`,
`steam-devices`, `distrobox`, `libvirt`, `greenboot`. Anything you merely
*run* is a Flatpak. This image is the OS.

**Every boot is checked.** `greenboot` waits for a graphical session on a
seat and rolls back after three failures — the one failure you cannot type
your way out of. Scheduler and network only warn; a machine without either
is still a machine.

**The scheduler is honest about itself.** `scx_bpfland` takes over because
8P+16E with no SMT is exactly where stock EEVDF places threads badly. Fedora's
7.1.5 and 7.1.6 kernels publish scx kfuncs with a stale BTF prototype, so
every BPF scheduler fails to load; the build checks
(`scripts/check-scx-btf.sh`), drops `/usr/lib/pulsar/scx-supported` only when
it can work, and `scx.service` is skipped rather than failed on kernels
where it can't. A fixed kernel brings it back with no change here.

**Development happens in containers**, except what a container cannot do:
`bpftrace`, `bcc-tools`, `sysstat` and `perf` are on the host because probes
attach to the host kernel. `mise` and `direnv` pin toolchains per project.
`pulsar setup devbox` assembles a default distrobox; `pulsar setup quadlet`
gives you a commented template for containers as rootless systemd units.

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

`doctor` reads `/sys/kernel/sched_ext/state` and the other places the truth
lives, because `systemctl is-active` once said the scheduler was running
while nothing was attached. Reads work unprivileged; only writes ask for
root. `sbom` reads the live rpm database — a file inside an image cannot
describe the image containing it.

## gamescale

Run a game at 1× so XWayland hands it the panel's real mode, then put the
desktop back when it exits, cleanly or not.
[`gamescale`](https://github.com/arclight-digital/gamescale) ships at a
pinned, hash-verified tag with its top-bar indicator and a reconcile unit.
Native launchers need nothing more. Flatpak launchers do, because Flatpak
reserves `/usr` and no grant can expose a host binary to Steam:

```bash
pulsar setup gamescale --platform steam   # the installer copy staged in the image
```

The user copy shadows the image copy on purpose — user paths win every
collision — and `gamescale --version` tells you which one is running.

## Install

```bash
sudo bootc switch ghcr.io/arclight-digital/pulsar:latest
sudo systemctl reboot
```

The nvidia module is signed with Pulsar's key, so Secure Boot stays on once
your firmware trusts that key. Enrol it — `mokutil` asks for a password you
retype once at the firmware screen:

```bash
sudo mokutil --import /etc/pki/pulsar/MOK.der
sudo systemctl reboot
```

The next boot stops in **MokManager**: `Enroll MOK` → `View key 0` →
`Continue` → `Yes` → password → reboot. Miss it and nothing breaks; import
again. Then take the driver:

```bash
sudo bootc switch ghcr.io/arclight-digital/pulsar-nvidia:latest
sudo systemctl reboot
modinfo -F signer nvidia && nvidia-smi
```

A BIOS update can wipe the MOK list. On the nvidia image, GNOME Software's
own Secure Boot prompt re-enrols the right key, because
`pulsar-akmods-cert.service` keeps `/etc/pki/akmods/certs/public_key.der`
equal to `MOK.der` on every boot.

**Updates** are stock Silverblue: GNOME Software notices, you restart when
you choose. Kernels, security fixes and driver bumps arrive nightly that way;
`sudo pulsar update` if you are impatient. It hands off to `rpm-ostree` when
you have layered packages, which plain `bootc upgrade` would drop.

## Two variants, one key

`Containerfile` has no secrets and builds anywhere. `Containerfile.nvidia`
needs the Secure Boot signing key, which it never holds: the key lives on a
signing host, the build sends each module's bytes with a bearer token and
attaches the signature that comes back ([docs/SIGNING.md](docs/SIGNING.md)).
The public half, `MOK.der`, ships in both images, and the nvidia build fails
if the module's signer does not match it — a stale cert is a failed build,
not a black screen.

**Running this yourself?** Fork it and use your own key. Enrolling mine means
your machine permanently trusts modules I sign. The vanilla image needs no
keys at all.

## Every image has a paper trail

```bash
gh attestation verify oci://ghcr.io/arclight-digital/pulsar-nvidia:latest --owner arclight-digital
```

Every image carries SLSA provenance and an SPDX SBOM
(`oras discover ghcr.io/arclight-digital/pulsar:latest`). Each nightly is
diffed against the one before it from those SBOMs — rendered at
[pulsar.arclight.digital/changelog](https://pulsar.arclight.digital/changelog),
served raw as [changelog.json](https://pulsar.arclight.digital/changelog.json),
and on the machine as `pulsar changelog`. Nothing in it is written by hand.

## Working on it

```text
Containerfile          -> ghcr.io/arclight-digital/pulsar
Containerfile.nvidia   -> ghcr.io/arclight-digital/pulsar-nvidia
scripts/nightly.sh     version, build, push, publish — the build host, 8pm Mountain
scripts/weekly.sh      installer ISOs, Saturday night — signed with keys/cosign.pub
iso-config.toml        what the installer asks before it partitions
assets/                source of truth for art; system_files/ branding is GENERATED
system_files.nvidia/   overlay for nvidia only
scripts/build.sh       local TEST builds; the build host ships the real ones
site/                  the site (Astro on ARC UI); Cloudflare builds it on push
site/src/data/         written by the nightly — never edit by hand
```

Push to `main` and the next nightly ships it; nothing builds off a push. A
build started by hand is tagged `<version>-dev`, moves no tags, touches no
baseline, and publishes no site — a debugging image, and a machine booted on
one says so in its boot menu.

The site is six pages on [ARC UI](https://arcui.dev), Arclight's own web
components, pre-rendered into declarative shadow DOM after the build. Its
content is this README, the CLI's `--help`, and the two files the nightly
commits; the hero runs the OS wallpaper shader live. `npm run dev` skips the
pre-render and flashes; `npm run build` is what ships.

## Field notes

- **Never `dnf install akmods-keys`** — that RPM contains a private key.
- **Never add `akmod-nvidia`** — Blackwell is nvidia-open only, and the
  closed akmod silently downgrades it.
- The `dracut` regen stays the last real step: the initramfs carries the
  plymouth theme and the nvidia modprobe options.
- The nvidia akmod comes from `updates-testing` until 610 lands in stable.
- One patch of ours rides on the nvidia module: open-gpu-kernel-modules
  PR #1286, for the DIFR deadlock that freezes the desktop after resume.
  `Containerfile.nvidia` phase 2b says when to drop it.
- Governor stays `powersave`; on `intel_pstate` with HWP that is correct.

## License

MIT — see [LICENSE](LICENSE). The fonts are OFL and travel with their
license; the NVIDIA userspace driver is proprietary, redistributed as the
RPM Fusion packages that carry it.
