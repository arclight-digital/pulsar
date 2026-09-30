<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="assets/brand/svg/pulsar-lockup-horizontal-light.svg">
    <img src="assets/brand/svg/pulsar-lockup-horizontal.svg" width="320" alt="Pulsar">
  </picture>
</h1>

<p align="center">
  Your lighthouse in the sky.<br>
  <sub>Linux that’s beautiful out of the box and rolls back when something breaks.</sub>
</p>

<p align="center">
  <a href="https://getpulsar.dev">getpulsar.dev</a>
</p>

Pulsar is a desktop operating system built as a bootc image on Fedora
Silverblue. A new image is built every night, and your machine switches to
it the next time you restart. If a new image fails to boot, the machine goes
back to the previous one.

On top of Silverblue, Pulsar adds a theme engine that recolors the whole
desktop, glass effects for GNOME Shell, a signed NVIDIA driver, and defaults
for gaming and development. It carries its own branding and ships Flathub
unfiltered.

## Install

For a fresh install, download the installer ISO from
[getpulsar.dev](https://getpulsar.dev/#install). If you already run
Silverblue or Kinoite, you can switch in place:

```bash
sudo bootc switch ghcr.io/arclight-digital/pulsar:latest          # any hardware
sudo bootc switch ghcr.io/arclight-digital/pulsar-nvidia:latest   # adds the signed nvidia-open driver
sudo systemctl reboot
```

### NVIDIA and Secure Boot

The NVIDIA kernel module is signed with Pulsar's key, so you can keep Secure
Boot on once your firmware trusts that key. Import it with `mokutil`, which
asks you to set a one-time password:

```bash
sudo mokutil --import /etc/pki/pulsar/MOK.der
sudo systemctl reboot
```

On the next boot, MokManager asks you to confirm. Choose `Enroll MOK`, then
`View key 0`, `Continue` and `Yes`, and enter the password. If you miss the
prompt, run the import again. Once you're back in, check that the driver
loaded:

```bash
modinfo -F signer nvidia && nvidia-smi
```

A BIOS update can clear the enrolled keys. On the NVIDIA image, GNOME
Software offers to enroll the key again, and `pulsar-akmods-cert.service`
makes sure it offers Pulsar's key.

## Updates and rollback

Pulsar downloads each night's image in the background while the machine is
plugged in and on an unmetered connection. A notification tells you when the
update is ready, and it takes effect when you next restart.

| To | Run |
|---|---|
| Stage the newest image now | the notification's Update button, or `sudo pulsar update` |
| Go back to the previous image | `sudo pulsar rollback`, or pick it in the boot menu |
| Stop background downloads | `sudo systemctl disable --now pulsar-update-auto.timer` |

`sudo pulsar update` uses `rpm-ostree` when you have layered packages, so
they carry over to the new image.

`greenboot` checks each boot for a working graphical session. After three
failed boots in a row, it rolls back automatically.

Rolling back replaces the OS image only. Your home folder, `/var`, Flatpak
apps and containers stay as they are.

## Themes

`pulsar theme set <name>` applies one of 20 themes to GNOME Shell, GTK 4 and
GTK 3 apps, the terminal, Text Editor, btop and the wallpaper at once. You
can also pick one in the Themes app (Super+T). New accounts start on the
Pulsar theme, and `pulsar theme revert` goes back to stock GNOME.

The Shell extension draws blurred glass behind menus, notifications, OSDs
and the top bar, and a soft light along their edges. Both can be switched off
in the extension's settings. See
[docs/theming.md](docs/theming.md) for what each part of the theme engine
writes.

## Gaming

Steam, Heroic, Bottles and other launchers are installed as Flatpaks on first
boot. The image itself includes `gamescope`, `gamemode`, `mangohud`,
`steam-devices`, and `ntsync` for Proton. It also turns off split-lock
mitigation and raises `vm.max_map_count`, since some games need both, and
tunes hugepage defragmentation and memory compaction so they don't stall
a running game.

### gamemode on laptops with two GPUs

By default, gamemode compares integrated GPU power with CPU power and drops
the CPU governor to `powersave` when the ratio goes above 0.3. That makes
sense when the integrated GPU is running the game. On a laptop where it only
drives the screen and a discrete GPU does the rendering, the check misfires.
`/etc/gamemode.ini` turns it off and enables the `nice -10` setting the
package already includes. `pulsar-gamemode-group.service` adds your account
to the gamemode group on first boot; the change applies from your next
login, and `pulsar doctor` shows whether it has.

### Loading screens

GNOME offers to force-quit a window that stops responding for 5 seconds,
which can happen during a long level load or shader compile. Pulsar raises
the limit to 20 seconds, and switches the check off entirely while gamemode
is active.

### gamescale

When fractional scaling is on, games running through XWayland render at the
wrong resolution and look blurry.
[gamescale](https://github.com/arclight-digital/gamescale) sets the display
to 100% while a game runs and puts your scaling back when it quits, even if
it crashes. The image ships a pinned, hash-verified release with an
indicator in the top bar. Games from native
launchers work with it as installed. For Flatpak launchers such as Steam,
install a copy into your home folder:

```bash
pulsar setup gamescale --platform steam
```

`gamescale --version` shows which copy is running.

### Scheduler

Pulsar runs the `scx_bpfland` scheduler, which handles CPUs with many
efficiency cores and no SMT better than the kernel's default. Some Fedora
kernels can't load BPF schedulers because of a bug in their type
information. The build tests for this with `scripts/check-scx-btf.sh`, and
on an affected kernel `scx.service` is skipped and the default scheduler
runs.

## Development

Install development tools in a toolbox or distrobox. `pulsar setup devbox`
creates a distrobox with common tools already in it, and
`pulsar setup quadlet` gives you a template for running a container as a
systemd service under your account. `mise` and `direnv` handle per-project
toolchains.

A few tools that need direct access to the kernel are installed on the host:
`bpftrace`, `bcc-tools`, `sysstat` and `perf`.

On the NVIDIA image, containers can use the GPU through a CDI spec that
Pulsar regenerates for the current driver at every boot:

```bash
podman run --rm --device nvidia.com/gpu=all registry.fedoraproject.org/fedora nvidia-smi
```

The container image needs to bring its own CUDA runtime. Avoid writing your
own spec to `/etc/cdi`, because it will go stale after the next driver
update; `pulsar doctor` warns if it finds one.

## Coding agents

You can install a coding agent with `pulsar agent add claude`, or `codex`,
`gemini`, `opencode` or `aider`. Each one gets its own toolbox and can be
started from any terminal.

| Command | What it does |
|---|---|
| `pulsar agent guide` | prints the guide the image ships for agents about how this system works |
| `pulsar mcp` | serves health checks, system status and crash reports to MCP clients, without root |
| `pulsar agent sandbox on` | runs agents in a container that only sees the current project; their pushes go through a gate that blocks force-pushes and deletes |
| `sudo pulsar agent guard on` | requires a password for layering packages and system-wide Flatpak installs |
| `sudo pulsar checkpoint` | snapshots `/etc` and your settings so you can compare or restore them later |
| `pulsar agent model on` | runs a local model on the GPU for opencode and aider (llama.cpp in rootless podman, on 127.0.0.1 with a key) |

[docs/AGENTS-SAFETY.md](docs/AGENTS-SAFETY.md) explains what an agent can
and can't change on this system.

## The `pulsar` command

```text
pulsar doctor [check]   health checks, exit 1 if one fails
pulsar status           deployments: booted, staged, rollback, pins
pulsar report           redacted diagnosis bundle, JSON or --text
pulsar manifest         what is in this image, and what it runs on
pulsar changelog        packages that moved in the latest published build
pulsar sbom             this system's packages as SPDX 2.3
pulsar verify           how to check where this image came from
pulsar update           fetch and stage the newest image   (root; --check needs none)
pulsar rollback         boot the previous deployment next  (root)
pulsar pin [on|off]     keep the booted deployment         (root to change)
pulsar checkpoint       snapshot /etc to diff or restore   (root)
pulsar theme <command>  recolor the whole desktop
pulsar setup <recipe>   apps | devbox | gamemode | quadlet | gamescale
pulsar agent            guide | list | add | remove | default | ask | run | sandbox | guard
```

If something is broken, run `pulsar report` and include its output when you
ask for help. `pulsar doctor` checks the actual system state, for example
reading `/sys/kernel/sched_ext/state` to see whether the scheduler is
attached, and it doesn't need root.

## Signing and provenance

The standard image, from `Containerfile`, needs no secrets and can be built
anywhere. The NVIDIA image signs its kernel module without the build ever
holding the private key: the build sends the module to a separate signing
host and attaches the signature it gets back
([docs/SIGNING.md](docs/SIGNING.md)). The build fails if the signed module
doesn't match the public key that ships in the image, `MOK.der`.

If you build Pulsar yourself, use your own signing key. Enrolling Pulsar's
key tells your firmware to trust any module signed with it.

Every image includes an SPDX software bill of materials, which you can list
with `oras discover ghcr.io/arclight-digital/pulsar:latest`. Pulsar compares
each night's bill of materials with the previous night's and publishes the
difference at [getpulsar.dev/docs/changelog](https://getpulsar.dev/docs/changelog)
and as [changelog.json](https://getpulsar.dev/changelog.json). On an
installed system, `pulsar changelog` shows the same list.

The installer ISOs are signed with Pulsar's cosign key,
[`keys/cosign.pub`](keys/cosign.pub). The container images aren't signed
yet. They were attested by GitHub Actions until the build moved to its own
host in August, and signing them with the same cosign key is planned.

## Working on it

```text
Containerfile          -> ghcr.io/arclight-digital/pulsar
Containerfile.nvidia   -> ghcr.io/arclight-digital/pulsar-nvidia
scripts/nightly.sh     version, build, push, publish; runs on the build host at 8pm Mountain
scripts/weekly.sh      installer ISOs, Saturday night, signed with keys/cosign.pub
scripts/publish.sh     SBOMs, the changelog and the site's data after each nightly
iso-config.toml        what the installer asks before it partitions
assets/                source of truth for art; branding in system_files/ is generated
system_files.nvidia/   overlay for the NVIDIA image only
scripts/build.sh       local test builds; the build host ships the real ones
docs/                  published to getpulsar.dev/docs with each nightly
```

Changes pushed to `main` go out with the next nightly build. Builds started
by hand are tagged `<version>-dev` and are for testing: they don't move any
tags or publish anything, and a machine booted from one says so in its boot
menu.

The website, [getpulsar.dev](https://getpulsar.dev), is in
[arclight-digital/pulsar-site](https://github.com/arclight-digital/pulsar-site).
`scripts/publish.sh` sends it this repo's docs and brand assets along with
each night's build data.

Pulsar is developed on a laptop with a Core Ultra 9 275HX, an RTX 5080
Max-Q alongside the integrated GPU, and a 2560×1600 display. The NVIDIA
image needs a GPU supported by nvidia-open; the standard image has no
hardware requirements beyond Fedora's.

## Field notes

- Don't `dnf install akmods-keys`. That package contains a private key.
- Don't add `akmod-nvidia`. Blackwell GPUs need nvidia-open, and the closed
  akmod quietly replaces it.
- Keep `dracut` as the last real step of the build. The initramfs includes
  the Plymouth theme and the NVIDIA modprobe options.
- The nvidia-open akmod comes from RPM Fusion's nvidia-driver repository.
  `Containerfile.nvidia` explains why.
- Pulsar patches the NVIDIA module with open-gpu-kernel-modules PR #1286,
  which fixes a deadlock that froze the desktop after resume. Phase 2b of
  `Containerfile.nvidia` says when to remove it.
- The CPU governor is left on `powersave`, which is the right setting for
  `intel_pstate` with HWP.

## License

MIT; see [LICENSE](LICENSE). The fonts are under the OFL and include their
license. The NVIDIA userspace driver is proprietary and is redistributed
through RPM Fusion's packages.
