# This machine runs Pulsar

Pulsar is an image-based Fedora Silverblue 44 system (bootc / rpm-ostree).
It does not behave like a mutable distro. Read this before changing
anything outside the project you were asked to work on.

This file ships in the OS image at `/usr/share/pulsar/AGENTS.md` and updates
with it. `pulsar agents-md` prints it.

## The filesystem

| Path | What it is |
|---|---|
| `/usr` | The OS image. **Read-only.** Never edit it and never try to work around that. |
| `/etc` | Writable, **local to this machine**. Carried forward into each update by a three-way merge. |
| `/var` | Writable, persistent, shared by every deployment. `/home` is `/var/home`. |
| `$HOME` | The user's data. Nothing on this system rolls it back. |

"Package installed" means one of four things here. Pick the right one:

- **Dev tools, compilers, SDKs, language runtimes** go in a toolbox:
  `toolbox list` to see boxes, `toolbox run -c <box> <command>` to run in one,
  `toolbox create <box>` to make a new Fedora box. Inside a box, `sudo dnf install`
  is fine; it changes only that container. `$HOME` is shared with the host, so
  project files are the same files. `pulsar setup devbox` makes a distrobox
  called `pulsar-dev` from `/usr/share/pulsar/distrobox.ini`.
- **Per-project toolchains**: `mise` and `direnv` are on the host and install
  into `$HOME`.
- **GUI apps are Flatpaks**: `flatpak install flathub <app-id>`. The `flathub`
  (unfiltered) and `fedora` remotes are configured.
- **GPU workloads** (local models, CUDA) run in containers on the nvidia
  image: `podman run --device nvidia.com/gpu=all <image>`. Do not install CUDA
  or a driver on the host; the image already carries the driver.
- **Host packages** (`rpm-ostree install`) are a last resort for things that
  cannot run in a container at all (kernel modules, udev rules, host daemons).
  **Never** use it for dev tools. It builds a new deployment, needs a reboot,
  and makes every future update slower. Ask the user first.

## Facts, not guesses

Run these before assuming anything about this machine. None needs root.

Call the CLI as **`/usr/bin/pulsar`** when you script it. The Pulsar code
editor also ships a command named `pulsar`, and if the user installed it
outside Flatpak it may come first on `PATH`. `/usr/bin/pulsar doctor --json`
always reaches this system's CLI, and its `cli` check says when another
`pulsar` is shadowing it.

| Command | Answers |
|---|---|
| `pulsar doctor --json` | Health checks. Exit 1 if one fails. |
| `pulsar status --json` | Deployments: booted, staged, rollback, pinned, layered packages. |
| `pulsar manifest --json` | Image version, variant (vanilla or nvidia), kernel, components, and the hardware under `.host`. |
| `pulsar report` | All of the above plus failed units, recent warning+ journal lines, GPU driver and Flatpak state, as one redacted JSON document. Use it when something is broken. |
| `pulsar flatpak-gl` | Whether running Flatpak apps (Steam, in practice) have the NVIDIA driver. An app started before its GL extension arrived renders games black on the iGPU; the fix is quitting and reopening it. |
| `pulsar update --check` | Whether a newer image is published. Exit 0 = current or staged, 10 = available, 1 = could not tell. |

## Updates, rollback, and what they cover

- `sudo pulsar update` fetches the new image and **stages** it. It takes
  effect on the next boot. **Never reboot the machine yourself**, and never
  pass `--apply`. Tell the user a reboot is pending.
- Nothing reboots by itself. Pulsar's update timer only notifies, and GNOME
  Software may download an update in the background, which still waits for a
  reboot.
- `sudo pulsar rollback` makes the previous deployment the default for the
  next boot. greenboot also rolls back on its own if a boot fails its health
  checks.
- `sudo pulsar pin` keeps the booted deployment from being garbage-collected.

**Rollback covers the OS image, not your data.** It does **not** undo changes
to `$HOME`, `/var`, Flatpak apps or their data, toolboxes, or containers.
`/etc` belongs to each deployment and is merged forward, so rollback is not a
reliable undo for an `/etc` edit. Before changing a file there, copy it
(`sudo cp -a <file> <file>.pre-agent`) so it can be put back, and
`sudo ostree admin config-diff` lists every `/etc` file that differs from what
the image ships.

Everything that needs `sudo` is the user's call. Do not run `sudo` without
asking, and do not try to get root another way.

Some system changes **do not ask for a password** here. Stock Fedora polkit
rules let an administrator's desktop session run `rpm-ostree install`,
`upgrade`, `rollback` and `cleanup`, and install or remove system Flatpaks,
without a prompt. If nothing asks you for a password, that does not mean you
have permission. Ask the user first.

## Logs

- `journalctl -b -p warning` shows this boot's warnings and errors.
  Reading the system journal needs wheel, adm or systemd-journal membership.
- `systemctl --failed` and `systemctl --user --failed` list failed units.
- Pulsar's own units: `pulsar-flatpaks.service` (first-boot Flatpaks),
  `pulsar-gamemode-group.service`, `scx.service` (scheduler),
  `greenboot-healthcheck.service`, and on the nvidia image
  `pulsar-gl-nvidia.service` (Flatpak GL driver), `nvidia-cdi-refresh.service`
  and `pulsar-gpu-containers.service` (GPU containers). User units:
  `pulsar-update-check.timer`, `pulsar-gl-check.path`,
  `gamescale-reconcile.service`, `podman-auto-update.timer`.
  Use `journalctl -u <unit>` for system units and
  `journalctl --user -u <unit>` for user units.
- `rpm-ostree status` shows what is booted, staged, and layered.

## Do not

- Edit or replace anything under `/usr`, or remount it read-write.
- `rpm-ostree install` / `override` / `rebase` / `reset`, `bootc switch`, or
  `ostree admin` anything, unless the user asked for exactly that.
- Reboot, or run `update --apply`.
- Edit `/etc` to "fix" something the image ships. A local `/etc` edit
  outlives image updates and silently shadows the fix that ships later.
  If you must, say which file you changed so the user can undo it.
- Run `sudo pip install` / `sudo npm install -g` on the host. They cannot write
  `/usr` anyway. Use a toolbox, `mise`, or a venv in the project.
- Disable `greenboot-healthcheck.service`. It is what makes a bad update roll
  itself back.
