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

On the next boot, MokManager asks you to confirm. Choose `Enroll MOK`,
`Continue` and `Yes`, then enter the password
([RPM Fusion's Secure Boot guide](https://rpmfusion.org/Howto/Secure%20Boot)
shows each screen). If you miss the prompt, run the import again. Once
you're back in, check that the driver loaded:

```bash
modinfo -F signer nvidia && nvidia-smi
```

A BIOS update can clear the enrolled keys (one did on 2026-09-10). On the
NVIDIA image, GNOME Software then offers to enroll the key again, and
`pulsar-akmods-cert.service` makes sure it offers Pulsar's key.

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
failed boots in a row (its default
[`GREENBOOT_MAX_BOOT_ATTEMPTS`](https://github.com/fedora-iot/greenboot-rs/blob/main/etc/greenboot/greenboot.conf)),
it rolls back automatically.

Rolling back replaces the OS image only. Your home folder, `/var`, Flatpak
apps and containers stay as they are.

## Themes

`pulsar theme set <name>` applies one of 24 themes to GNOME Shell, GTK 4 and
GTK 3 apps, the terminal, Text Editor, btop and the wallpaper at once. You
can also pick one in Themes (Super+T, unless your account already uses that
shortcut). New accounts start on the Pulsar theme, and `pulsar theme revert`
goes back to stock GNOME.

The Shell extension draws blurred glass behind menus, notifications, OSDs
and the top bar, makes app windows translucent over a blur of what's behind
them, and lights a menu's edge from the button that opened it. Each effect is
a switch on the Appearance page of Pulsar Settings.
[docs/theming.md](docs/theming.md) lists them and what each part of the theme
engine writes.

## Gaming

Steam, Heroic, Bottles and other launchers are installed as Flatpaks the
first time the machine reaches Flathub. The image itself includes
`gamescope`, `gamemode`, `mangohud`, `steam-devices`, and `ntsync` for
Proton. It also turns off split-lock mitigation, raises `vm.max_map_count`, and tunes hugepage defragmentation
and memory compaction so they don't stall a running game.

### gamemode on laptops with two GPUs

By default, gamemode compares integrated GPU power with CPU power and drops
the CPU governor to `powersave` when the ratio goes above 0.3
([gamemode's example config](https://github.com/FeralInteractive/gamemode/blob/master/example/gamemode.ini)
documents both settings). That makes
sense when the integrated GPU is running the game. On a laptop where it only
drives the screen and a discrete GPU does the rendering, the check misfires.
`/etc/gamemode.ini` turns it off and enables the `nice -10` setting the
package already includes. `pulsar-gamemode-group.service` adds your account
to the gamemode group on first boot; the change applies from your next
login, and `pulsar doctor` shows whether it has.

### Loading screens

GNOME offers to force-quit a window that stops responding for 5 seconds
(mutter's
[`check-alive-timeout`](https://gitlab.gnome.org/GNOME/mutter/-/blob/main/data/org.gnome.mutter.gschema.xml.in)),
which can happen during a long level load or shader compile. Pulsar raises
the limit to 20 seconds, and switches the check off entirely while gamemode
is active.

### gamescale

When fractional scaling is on, XWayland doesn't give games the panel's real
resolution, so they either upscale and look blurry or render more pixels than
the panel has. [gamescale](https://github.com/arclight-digital/gamescale),
whose README has the numbers, sets the display to 100% while a game runs and
puts your scaling back when it quits, even if it crashes. The image ships a pinned, hash-verified release
with an indicator in the top bar. Native launchers use it as installed, and
`pulsar-steam-grants.service` gives the Steam and Faugus Flatpaks read-only
access to the image's copy. Other Flatpak launchers need a copy in your home
folder:

```bash
pulsar setup gamescale --platform heroic    # or bottles, lutris
```

`gamescale --version` shows which copy is running.

### Steam launch options

`gg` runs a game through gamescale and gamemode. `ggm` does the same and
turns on the MangoHud overlay. In a game's Properties, set Launch Options to:

```text
gg %command%
ggm %command%
```

Flags before `%command%` go to gamescale, so `gg -x %command%` works too.
Both work in the Steam and Faugus Flatpaks with no setup (in Faugus they go
in a game's launch arguments). For other Flatpak launchers,
`pulsar setup gamescale --platform <name>` copies them into `~/.local/bin`
beside gamescale. If you already have your own `gg` or `ggm` there, setup
leaves it alone and says so.

If you set up Steam with `pulsar setup gamescale` before, run it again with
no arguments, or with `--platform steam faugus` if you set up Faugus too. It
points them at the image's copies and removes the old copies from your home
folder.

### Scheduler

Pulsar runs the kernel's own scheduler, EEVDF, the same as Fedora. On the
Core Ultra 9 275HX it was measured on, EEVDF kept GNOME Shell on the
performance cores (15-24% of its time on efficiency cores). `scx_bpfland`,
which Pulsar used to run by default, put 66-78% of it on the efficiency
cores, and animations jumped to their end.

`scx_bpfland` is still installed. To use it, run
`sudo systemctl enable --now scx.service`. Some Fedora kernels can't load
BPF schedulers because of a bug in their type information. The build tests
for this with `scripts/check-scx-btf.sh`, and on an affected kernel
`scx.service` is skipped and the default scheduler runs.

## Development

Install development tools in a toolbox or distrobox. `pulsar setup devbox`
creates a Fedora distrobox, `pulsar-dev`, with git, make, cmake, gcc, gdb,
ripgrep, fd, jq and Python's pip and headers already in it, and
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
update; `pulsar doctor` warns when a spec there is stale.

## Coding agents

You can install a coding agent with `pulsar agent add claude`, or `codex`,
`gemini`, `opencode` or `aider`. They all install into one toolbox, `agents`,
and each gets a command that works from any terminal.

| Command | What it does |
|---|---|
| `pulsar agent guide` | prints the agent guide that ships with the image, `/usr/share/pulsar/AGENTS.md` |
| `pulsar mcp` | serves health checks, system status and crash reports to MCP clients, without root |
| `pulsar agent sandbox on` | runs agents in a container that only sees the current project; their pushes go through a gate that blocks force-pushes and deletes |
| `sudo pulsar agent guard on` | requires the admin password for layering packages, rollback, cleanup, and system Flatpak installs and removals |
| `sudo pulsar checkpoint` | snapshots `/etc` and your settings and pins the booted deployment, so you can compare or restore them later |
| `pulsar agent model on` | runs a local model for opencode and aider (llama.cpp in rootless podman, on 127.0.0.1 with a key), on the GPU when there is one and on the CPU otherwise |

[docs/AGENTS-SAFETY.md](docs/AGENTS-SAFETY.md) explains what an agent can
and can't change on this system.

## The `pulsar` command

```text
pulsar doctor [check]    health checks; exit 1 if one fails
pulsar status            deployments: booted, staged, rollback, pins
pulsar report            a redacted diagnosis bundle to paste; JSON, or --text
pulsar crashes           this boot's crashes, and programs not to announce
pulsar manifest          what is in this image, and what it runs on
pulsar changelog         packages that moved in the latest published build
pulsar sbom              this system's packages as SPDX 2.3
pulsar verify            check the running image's signature
pulsar update            fetch and stage the newest image       (root)
pulsar update --check    is a newer image published? exit 10 if so
pulsar rollback          boot the previous deployment next      (root)
pulsar pin [on|off]      keep the booted deployment through GC  (root)
pulsar checkpoint        snapshot /etc, your settings and pin   (root)
pulsar theme <command>   recolor the whole desktop
pulsar setup <recipe>    apps | devbox | gamemode | quadlet | gamescale
pulsar screen text|qr    the text or QR code in an area of the screen, onto the clipboard
pulsar agent             guide | list | add | remove | default | run | attach | sessions |
                         undo | usage | sandbox | guard
pulsar agent model on    a local model server for agents, on the GPU when there is one
pulsar agent ask         start your agent on a redacted pulsar report
pulsar mcp               the CLI's --json answers as MCP tools, without root
```

`pulsar help <command>` describes one command. `pulsar doctor` doesn't need
root. If something is broken, run `pulsar report` and include its output when
you ask for help.

## Signing and provenance

The standard image, from `Containerfile`, needs no secrets and can be built
anywhere. The NVIDIA image signs its kernel module without the build ever
holding the private key: the build sends the module to a separate signing
host and attaches the signature it gets back
([docs/SIGNING.md](docs/SIGNING.md)). The build fails if the signed module
doesn't match the public key that ships in the image, `MOK.der`.

If you build Pulsar yourself, use your own signing key. Enrolling Pulsar's
key tells your firmware to trust any module signed with it.

Every image includes an SPDX SBOM, which you can list with
`oras discover ghcr.io/arclight-digital/pulsar:latest`. Pulsar compares each
night's SBOM with the previous night's and publishes the difference at
[getpulsar.dev/docs/changelog](https://getpulsar.dev/docs/changelog) and as [changelog.json](https://getpulsar.dev/changelog.json). On an
installed system, `pulsar changelog` shows the same list.

The published images (`pulsar` and `pulsar-nvidia` on ghcr.io) and the
installer ISOs are signed with Pulsar's cosign release key,
[`keys/cosign.pub`](keys/cosign.pub). Images have been signed since
2026-09-28, on the build host after the boot gate, and each signature is
logged in Rekor (rekor.sigstore.dev). The key replaced the old one on
2026-11-09; images and ISOs from before then verify with
[`keys/cosign-before-2026-11-09.pub`](keys/cosign-before-2026-11-09.pub).
`pulsar verify` checks the booted image's signature against the key the image
ships, `/etc/pki/containers/pulsar.pub`. Installed systems don't enforce
signatures when they update: there is no signature policy (`policy.json`).

## Working on it

```text
Containerfile          -> ghcr.io/arclight-digital/pulsar
Containerfile.nvidia   -> ghcr.io/arclight-digital/pulsar-nvidia
scripts/nightly.sh     version, build, push, publish; runs on the build host at 7:45 p.m. Mountain
scripts/weekly.sh      installer ISOs, Sundays at 1:45 a.m. Mountain, signed with the release key and verified with keys/cosign.pub
scripts/publish.sh     SBOMs, the changelog and the site's data after each nightly
iso-config.toml        what the installer asks before it partitions
assets/                source of truth for art; branding in system_files/ is generated
system_files.nvidia/   overlay for the NVIDIA image only
scripts/build.sh       the build pipeline, the same on a workstation and the build host
docs/                  published to getpulsar.dev/docs with each nightly
```

Changes pushed to `main` go out with the next nightly build. A build started
by hand runs the same pipeline and takes the next version number, but it
doesn't move the floating tags (`:latest`, `:<fedora>`) or update the site,
so machines don't get it unless it's promoted.

The website, [getpulsar.dev](https://getpulsar.dev), is in
[arclight-digital/pulsar-site](https://github.com/arclight-digital/pulsar-site).
`scripts/publish.sh` sends it this repo's docs and brand assets along with
each night's build data.

Pulsar is developed on a laptop with a Core Ultra 9 275HX and an RTX 5080
Max-Q alongside the integrated GPU. The NVIDIA image needs a GPU supported
by nvidia-open; the standard image has no hardware requirements beyond
Fedora's.

## Field notes

- Don't `dnf install akmods-keys` (the top of `Containerfile.nvidia` says
  why).
- Don't add `akmod-nvidia`. Blackwell GPUs need the open kernel modules
  ([NVIDIA](https://developer.nvidia.com/blog/nvidia-transitions-fully-towards-open-source-gpu-kernel-modules/)),
  and when the closed akmod is the newer version, dnf installs it and
  downgrades nvidia-open (phase 2 of `Containerfile.nvidia`).
- Keep `dracut` as the last real step of the build. The initramfs includes
  the Plymouth theme and the NVIDIA modprobe options.
- The nvidia-open akmod comes from RPM Fusion's nvidia-driver repository
  (`Containerfile.nvidia` says why).
- Pulsar patches the NVIDIA module with open-gpu-kernel-modules
  [PR #1286](https://github.com/NVIDIA/open-gpu-kernel-modules/pull/1286),
  which fixes a system hang after repeated suspend and resume. Phase 2b of
  `Containerfile.nvidia` says when to remove it.

## License

MIT; see [LICENSE](LICENSE). The fonts are under the OFL and include their
license. The NVIDIA userspace driver is proprietary and is redistributed
through RPM Fusion's packages.
