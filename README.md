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
it the next time you restart.

On top of Silverblue, Pulsar adds a theme engine that recolors the whole
desktop, glass effects for GNOME Shell, a signed NVIDIA driver, and defaults
for gaming and development. Flathub comes unfiltered.

## Install

For a fresh install, the
[install guide](https://getpulsar.dev/docs/install) has the installer ISO and
walks through it. On Silverblue or Kinoite, you can switch in place instead:

```bash
sudo bootc switch ghcr.io/arclight-digital/pulsar:latest          # any hardware
sudo bootc switch ghcr.io/arclight-digital/pulsar-nvidia:latest   # adds the signed nvidia-open driver
sudo systemctl reboot
```

The NVIDIA image needs a GPU that nvidia-open supports. The standard image
has no hardware requirements beyond Fedora's.

### NVIDIA and Secure Boot

With Secure Boot on, the NVIDIA driver loads only after your firmware trusts
Pulsar's key, and the NVIDIA image blocks nouveau. Both images ship the key.
Import it with `mokutil`, which asks you to set a one-time password:

```bash
sudo mokutil --import /etc/pki/pulsar/MOK.der
sudo systemctl reboot
```

On the next boot, MokManager asks you to confirm. Choose `Enroll MOK`,
`Continue` and `Yes`, then enter the password
([RPM Fusion's Secure Boot guide](https://rpmfusion.org/Howto/Secure%20Boot)
shows each screen). If you miss the prompt, run the import again. Once
you're back in, check that the driver loaded:

```bash
modinfo -F signer nvidia && nvidia-smi
```

A BIOS update can clear the enrolled keys. GNOME Software then offers to
enroll Pulsar's key again, or you can rerun the import.

## Updates and rollback

Pulsar downloads each night's image in the background while the machine is
plugged in and on an unmetered connection, and a notification tells you when
it's ready. `sudo pulsar rollback`, or the boot menu, takes you back to the
previous image. After three failed boots in a row, `greenboot` rolls back on
its own. Rolling back replaces the OS image only: your home folder, `/var`,
Flatpak apps and containers stay as they are.
[Updates](https://getpulsar.dev/docs/updates) covers pins, checkpoints and
turning off background downloads.

## Themes

`pulsar theme set <name>` applies one of 24 themes to GNOME Shell, GTK 4 and
GTK 3 apps, the terminal, Text Editor, btop and the wallpaper at once, and
`pulsar theme revert` goes back to stock GNOME. Pulsar's Shell extension adds
blurred glass behind menus, notifications and the top bar, and translucent
app windows; each effect is a switch in Pulsar Settings.
[Themes](https://getpulsar.dev/docs/themes) shows them, and
[docs/theming.md](docs/theming.md) explains how the theme engine works.

## Gaming

Steam, Faugus, Heroic and Bottles are installed as Flatpaks the first time
the machine reaches Flathub. The image includes `gamescope`, `gamemode`,
`mangohud`, `steam-devices`, `ntsync` and
[gamescale](https://github.com/arclight-digital/gamescale), which sets the
display to 100% scaling while a game runs. In Steam, the launch option
`gg %command%` runs a game through gamescale and gamemode, and `ggm` adds the
MangoHud overlay. [Gaming](https://getpulsar.dev/docs/gaming) lists the
kernel and gamemode settings Pulsar changes, and
[gamescale](https://getpulsar.dev/docs/gamescale) covers other launchers.

## Development

Install development tools in a toolbox or distrobox. `pulsar setup devbox`
creates a Fedora distrobox, `pulsar-dev`, with git, gcc, gdb and other build
tools in it. `bpftrace`, `bcc-tools`, `sysstat`, `perf` and `direnv` are on
the host. On the NVIDIA image, containers can use the GPU:

```bash
podman run --rm --device nvidia.com/gpu=all registry.fedoraproject.org/fedora nvidia-smi
```

[Where things go](https://getpulsar.dev/docs/where-things-go) and
[GPU containers](https://getpulsar.dev/docs/gpu-containers) have the details.

## Coding agents

`pulsar agent add claude` installs Claude Code (or `codex`, `gemini`,
`opencode`, `aider`) into a toolbox named `agents`. The image ships a guide
for agents, `/usr/share/pulsar/AGENTS.md`, and `pulsar mcp` gives them the
machine's health checks and status without root. `pulsar agent sandbox on`
keeps an agent inside the current project, and `sudo pulsar agent guard on`
makes package layering, rollback, cleanup and system Flatpak installs and
removals ask for a password. [Agents](https://getpulsar.dev/docs/agents) and
[docs/AGENTS-SAFETY.md](docs/AGENTS-SAFETY.md) explain what an agent can and
can't change.

## The `pulsar` command

```text
pulsar doctor [check]    health checks; exit 1 if one fails
pulsar report            a diagnosis bundle to paste
pulsar update            download and stage the newest image    (root)
pulsar rollback          boot the previous deployment next      (root)
pulsar verify            check the running image's signature
```

`pulsar --help` lists every command, and
[getpulsar.dev/docs/cli](https://getpulsar.dev/docs/cli) has more. If
something is broken, include the output of `pulsar report` when you ask for
help.

## Signing and provenance

The published images (`pulsar` and `pulsar-nvidia` on ghcr.io) and the
installer ISOs are signed with Pulsar's cosign release key,
[`keys/cosign.pub`](keys/cosign.pub), and the build logs each signature in
Rekor. To check an image:

```bash
cosign verify --key https://raw.githubusercontent.com/arclight-digital/pulsar/main/keys/cosign.pub \
  ghcr.io/arclight-digital/pulsar:latest
```

On an installed system, `pulsar verify` runs the same check on the booted
image against the key the image ships. Machines don't enforce signatures when
they update: there is no `policy.json`. The key was replaced on 2026-11-09,
and every image signed before then was signed again with the new key. ISOs
from before the change verify with
[`keys/cosign-before-2026-11-09.pub`](keys/cosign-before-2026-11-09.pub).
[Provenance](https://getpulsar.dev/docs/provenance) shows how to check an ISO.

Every image includes an SPDX SBOM, which `oras discover` lists. Each night's
SBOM is compared with the previous night's, and the difference is published at
[getpulsar.dev/docs/changelog](https://getpulsar.dev/docs/changelog) and
shown by `pulsar changelog`.

The standard image needs no secrets and can be built anywhere. The NVIDIA
build sends its kernel module to a separate signing host and attaches the
signature it gets back, so it never holds the private key, and it fails if
the signature doesn't match `MOK.der`. If you build Pulsar yourself, use your
own signing key: enrolling Pulsar's key tells your firmware to trust any
module signed with it. [docs/SIGNING.md](docs/SIGNING.md) describes the signing
host and both keys.

## Working on it

```text
Containerfile            -> ghcr.io/arclight-digital/pulsar
Containerfile.nvidia     -> ghcr.io/arclight-digital/pulsar-nvidia
Containerfile.installer  the live installer ISO (the app is scripts/pulsar-installer)
system_files/            files laid over the image (system_files.nvidia/: NVIDIA only)
assets/                  source of truth for art; system_files/ branding is generated
cli/pulsar               the pulsar command
scripts/build.sh         the build pipeline, the same on a workstation and the build host
scripts/nightly.sh       version, build, push, publish; runs at 7:45 p.m. Mountain
scripts/weekly.sh        installer ISOs, Sundays at 1:45 a.m. Mountain
scripts/publish.sh       SBOMs, the changelog and the site's data after each nightly
docs/                    published to getpulsar.dev/docs
```

To build the standard image on your machine and run the tests:

```bash
./scripts/build.sh --variant vanilla    # builds localhost/pulsar
./scripts/check.sh                      # the checks each nightly runs before it builds
```

Changes pushed to `main` go out with the next nightly build. A build started
by hand runs the same pipeline and takes the next version number, but it
doesn't move `:latest` or `:<fedora>` or update the site, so machines don't
get it unless it's promoted.

Read the comments in `Containerfile.nvidia` before changing it. They say why
it never installs `akmods-keys` or `akmod-nvidia`, and when to drop the
[PR #1286](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1286)
suspend fix (phase 2b). `dracut` stays the last real step of each build,
because the initramfs carries the Plymouth theme and the NVIDIA modprobe
options.

The website is
[arclight-digital/pulsar-site](https://github.com/arclight-digital/pulsar-site).

## License

MIT; see [LICENSE](LICENSE). The fonts are under the OFL and include their
license. The NVIDIA userspace driver is proprietary and is redistributed
through RPM Fusion's packages.
