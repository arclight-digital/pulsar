# This machine runs Pulsar

Pulsar is an image-based Fedora Silverblue 44 system (bootc / rpm-ostree).
It does not behave like a mutable distro. Read this before changing
anything outside the project you were asked to work on.

This file ships in the OS image at `/usr/share/pulsar/AGENTS.md` and updates
with it. `pulsar agent guide` prints it, and `pulsar agent --json` says
what else this machine gives you: which agents are installed, and whether
guard is on (below).

## The filesystem

| Path | What it is |
|---|---|
| `/usr` | The OS image. **Read-only.** Never edit it and never try to work around that. |
| `/etc` | Writable, **local to this machine**. Carried forward into each update by a three-way merge. |
| `/var` | Writable, persistent, shared by every deployment. `/home` is `/var/home`. |
| `/usr/local`, `/opt` | Writable symlinks into `/var` (`/var/usrlocal`, `/var/opt`). **Not part of the image.** Anything put there shadows the image on `PATH`, survives every update and rollback, and never shows in `rpm-ostree status`. |
| `$HOME` | The user's data. Nothing on this system rolls it back. |

"Package installed" means one of four things here. Pick the right one:

- **Dev tools, compilers, SDKs, language runtimes** go in a toolbox:
  `toolbox list` to see boxes, `toolbox run -c <box> <command>` to run in one,
  `toolbox create <box>` to make a new Fedora box. Inside a box, `sudo dnf install`
  is fine; it changes only that container. `$HOME` is shared with the host, so
  project files are the same files. Prefer toolbox: `toolbox run` works
  without a terminal. `pulsar setup devbox` makes a distrobox called
  `pulsar-dev`, which `toolbox` cannot see and `distrobox enter` can hang in
  without a TTY. Use it only when the user already works there.
- **Per-project toolchains**: `mise` and `direnv` are on the host and install
  into `$HOME`.
- **GUI apps are Flatpaks**: `flatpak install --user flathub <app-id>`
  installs into `$HOME` and is yours to do. A system install (no `--user`) is
  a system change: ask first, even though nothing will prompt (see below).
  The `flathub` (unfiltered) and `fedora` remotes are configured.
- **GPU workloads** (local models, CUDA) run in containers on the nvidia
  image: `podman run --device nvidia.com/gpu=all <image>`. Do not install CUDA
  or a driver on the host; the image already carries the driver.
- **Host packages** (`rpm-ostree install`) are a last resort for things that
  cannot run in a container at all (kernel modules, udev rules, host daemons).
  **Never** use it for dev tools. It builds a new deployment, needs a reboot,
  and makes every future update slower. Ask the user first.

## If you are sandboxed

`PULSAR_SANDBOX=1` in your environment means you are running in Pulsar's
agent sandbox: a container that shows you only the project you were started
in. The rest of `$HOME`, the user's SSH keys, `sudo`, `pulsar`, `toolbox`
and `rpm-ostree` are not there, so do not look for them or try to reach the
host. `.git/config` and `.git/hooks` are read-only; commit normally. A
write to `.git/config` fails with "Device or resource busy": that is the
sandbox, not a fault, so do not retry it. It means `push -u` records no
tracking branch in here (git still says it did); plain `git push` works
anyway, because `push.autoSetupRemote` is on, and Pulsar records the
tracking for every branch you pushed when the session ends.
`git push` and `git pull` work through a gate that pushes with the user's
credentials: branches only, never force-push, delete or tags, and maybe not
the default branch. If a push is refused, the message says why; tell the
user rather than work around it.

## Skills

`/usr/share/pulsar/skills/` holds skills for this machine, one folder each
with a `SKILL.md`: `pulsar-theme` makes, checks and applies desktop themes.
`pulsar agent add` links them where your agent looks for skills. If yours
does not read skills, read the matching `SKILL.md` yourself when a task fits
its description.

## Facts, not guesses

Run these before assuming anything about this machine. None needs root.

Call the CLI as **`/usr/bin/pulsar`** when you script it. The Pulsar code
editor also ships a command named `pulsar`, and if the user installed it
outside Flatpak it may come first on `PATH`. `/usr/bin/pulsar doctor --json`
always reaches this system's CLI, and its `cli` check says when another
`pulsar` is shadowing it.

| Command | Answers |
|---|---|
| `pulsar doctor --json` | Health checks. Exit 1 if one fails. `pulsar doctor <check>` runs one; `pulsar doctor --help` lists them. |
| `pulsar status --json` | Deployments: booted, staged, rollback, pinned, layered packages. |
| `pulsar manifest --json` | Image version, variant (vanilla or nvidia), kernel, components, and the hardware under `.host`. |
| `pulsar report --crash latest` | One of the user's crashes as systemd-coredump saw it: program, signal, package, unit, the crashing thread's stack trace, and that process's log lines. `pulsar doctor crashes` lists this boot's. |
| `pulsar report` | All of the above plus failed units, recent warning+ journal lines, GPU driver and Flatpak state, as one redacted JSON document. Use it when something is broken. |
| `pulsar doctor flatpak-gl` | Whether running Flatpak apps (Steam, in practice) have the NVIDIA driver. An app started before its GL extension arrived renders games black on the iGPU; the fix is quitting and reopening it. |
| `pulsar update --check --json` | Whether a newer image is published. Exit 0 = current or staged, 10 = available, 1 = could not tell. |
| `pulsar pin --json` | Whether the booted deployment is pinned. |
| `pulsar agent guard --json` | Whether layering and system Flatpak installs ask for a password here (`on`) or not (`off`). |

## Updates, rollback, and what they cover

- When the user asks for an update, `sudo pulsar update` fetches the new
  image and **stages** it. It takes effect on the next boot. **Never reboot
  the machine yourself**, and never pass `--apply`. Tell the user a reboot is
  pending.
- Nothing reboots by itself. Pulsar's update timer only notifies, and GNOME
  Software may download an update in the background, which still waits for a
  reboot.
- `sudo pulsar rollback` makes the previous deployment the default for the
  next boot. greenboot also rolls back on its own if a boot fails its health
  checks.
- `sudo pulsar pin on` keeps the booted deployment from being garbage-collected.

**Rollback covers the OS image, not your data.** It does **not** undo changes
to `$HOME`, `/var` (including `/usr/local` and `/opt`), Flatpak apps or their
data, toolboxes, or containers.

`/etc` is worse than "not undone". Each deployment has its own copy. Rollback
boots the older deployment's `/etc`, so edits made since it was current are
simply missing, and the next update merges forward from that older state. An
edit can disappear without anyone removing it. Before changing a file there,
copy it (`sudo cp -a <file> <file>.pre-agent`) so it can be put back by hand,
and `sudo ostree admin config-diff` lists every `/etc` file that differs from
what the image ships. Before a session that will touch `/etc`, suggest the
user run `sudo pulsar checkpoint`: it snapshots `/etc` so they can diff and
restore it afterwards. It is theirs to run, not yours, and so are its `diff`,
`restore` and `drop`.

A file moved into `/etc` with `mv`, or copied with `cp -a` from somewhere like
`$HOME`, keeps its old SELinux label (`user_home_t`, not `etc_t`), and the
service that reads it gets denied. Run `sudo restorecon -v <file>` after
putting a file there.

Everything that needs `sudo` is the user's call. Do not run `sudo` without
asking, and do not try to get root another way.

Some system changes **do not ask for a password** here. Stock Fedora polkit
rules let an administrator's desktop session run `rpm-ostree install`,
`upgrade`, `rollback` and `cleanup`, and install or remove system Flatpaks,
without a prompt. `systemctl reboot` does not prompt either. If nothing asks
you for a password, that does not mean you have permission. Ask the user
first. The user can make the rpm-ostree and Flatpak ones prompt with
`sudo pulsar agent guard on`; `pulsar agent guard` shows which way it is.

## Logs

- `journalctl -b -p warning` shows this boot's warnings and errors.
  Reading the system journal needs wheel, adm or systemd-journal membership.
- `systemctl --failed` and `systemctl --user --failed` list failed units.
- Pulsar's own units: `pulsar-flatpaks.service` (first-boot Flatpaks),
  `pulsar-gamemode-group.service`, `scx.service` (scheduler),
  `greenboot-healthcheck.service`, and on the nvidia image
  `pulsar-gl-nvidia.service` (Flatpak GL driver), `nvidia-cdi-refresh.service`
  and `pulsar-gpu-containers.service` (GPU containers). User units:
  `pulsar-update-check.timer`, `pulsar-gl-check.path`, `pulsar-crash-watch.path`,
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
- Install anything into `/usr/local` or `/opt` (`sudo install`, `sudo make
  install`, a vendor `.sh` installer). It is a way around the read-only `/usr`
  that no update or rollback will ever clean up. Use a toolbox, `mise`, or
  `~/.local/bin`.
- Run `sudo pip install` / `sudo npm install -g` on the host. They either fail
  on `/usr` or land in `/usr/local` (see above). Use a toolbox, `mise`, or a
  venv in the project.
- `flatpak install` or `flatpak uninstall` without `--user`, or
  `flatpak remote-add` / `remote-modify`, unless the user asked. They change
  the system for every account, and installs and removals do not prompt.
- Disable `greenboot-healthcheck.service`. It is what makes a bad update roll
  itself back.
