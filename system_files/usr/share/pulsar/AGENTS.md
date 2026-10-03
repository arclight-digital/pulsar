# This machine runs Pulsar

Pulsar is an image-based OS (bootc / rpm-ostree), built on Fedora
Silverblue 44. It is not a mutable distro. Read this before changing anything
outside the project you were given.

Ships at `/usr/share/pulsar/AGENTS.md`, updates with the image.
`pulsar agent guide` prints it; `pulsar agent --json` lists installed agents
and guard state.

## Ground rules

- **Ask first** before anything that needs `sudo`, changes the system, or is
  hard to undo. Never get root another way.
- **No prompt is not permission.** An admin's desktop session can run
  `rpm-ostree install|upgrade|rollback|cleanup`, system Flatpak installs and
  removals, and `systemctl reboot` with no password. Ask anyway.
  `pulsar agent guard` shows whether rpm-ostree and system Flatpak changes
  prompt; `sudo pulsar agent guard on` makes them prompt (the user's call).
- **Never reboot**, and never pass `--apply`.
- Call the CLI as **`/usr/bin/pulsar`** in scripts. The Pulsar code editor
  also ships a `pulsar` that may come first on `PATH`.

## Filesystem

| Path | What it is |
|---|---|
| `/usr` | The OS image. Read-only. Never edit, remount or work around it. |
| `/etc` | Writable, local, per deployment. Three-way merged into each update. |
| `/var` | Writable, persistent, shared by all deployments. `/home` = `/var/home`. |
| `/usr/local`, `/opt` | Symlinks into `/var`. Not in the image, shadow it on `PATH`, survive every update and rollback, invisible to `rpm-ostree status`. Don't install there. |
| `$HOME` | User data. Nothing rolls it back. |

## Where software goes

| Need | Where | Notes |
|---|---|---|
| Dev tools, compilers, SDKs, runtimes | toolbox | `toolbox list`; `toolbox run -c <box> <cmd>` (works without a TTY); `toolbox create <box>`. `sudo dnf install` inside a box is fine. `$HOME` is shared. |
| Per-project toolchains | `mise`, `direnv` | On the host, install into `$HOME`. |
| Python/Node packages | venv, toolbox, `mise` | Never `sudo pip install` / `sudo npm install -g`. |
| GUI apps | Flatpak | `flatpak install --user flathub <id>` is yours to do. Without `--user` it is a system change: ask. Remotes: `flathub` (unfiltered), `fedora`. |
| GPU / CUDA / local models | podman | `podman run --device nvidia.com/gpu=all <image>` (nvidia image). Never install CUDA or a driver on the host. |
| Kernel modules, udev rules, host daemons | `rpm-ostree install` | Last resort, never for dev tools. New deployment, needs a reboot, slows every update. Ask first. |

`pulsar setup devbox` makes a distrobox `pulsar-dev`. `toolbox` can't see it
and `distrobox enter` can hang without a TTY; use it only if the user already
works there.

## Gaming

- Flatpak Steam can't see `/usr/bin`. `pulsar-steam-grants.service` (every
  boot) gives it the image's `gg`, `ggm` and `gamescale` at
  `/run/host/usr/lib/pulsar/sandbox-bin`, so the launch options
  `gg %command%`, `ggm %command%` and `gamescale %command%` need no setup.
  Don't copy them into `~/.local/bin`: copies there never update.
- A launch that exits at once means Steam can't find the command. Check with
  `flatpak run --command=sh com.valvesoftware.Steam -c 'command -v gg'`. A
  `PATH=` in the user override
  (`~/.local/share/flatpak/overrides/com.valvesoftware.Steam`) beats the
  system one; `pulsar setup gamescale` repoints it.
- Other Flatpak launchers: `pulsar setup gamescale --platform <name>`.

## Sandboxed agents (`PULSAR_SANDBOX=1`)

You are in a container that sees only the project.

- Not there: the rest of `$HOME`, SSH keys, `sudo`, `pulsar`, `toolbox`,
  `rpm-ostree`. Don't look for them or try to reach the host.
- `.git/config` and `.git/hooks` are read-only. A write fails with "Device or
  resource busy"; that is the sandbox, don't retry. Commit normally.
- `git push` / `git pull` go through a gate using the user's credentials:
  branches only; no force-push, deletes or tags; maybe not the default branch;
  maybe off for this project. A refusal says why: tell the user, don't work
  around it. `push -u` records no tracking branch (git says it did); plain
  `git push` works (`push.autoSetupRemote` is on).
- `gh pr create` is the only `gh` command, for an already-pushed branch.
  Flags: `--title`, `--body`, `--body-file`, `--base`, `--head`, `--draft`,
  `--fill`.
- Local model, if the user runs one (`pulsar agent model`):
  `http://127.0.0.1:8080/v1`, OpenAI-compatible. Every request needs the key
  in `~/.config/pulsar/model-key`. No other host port is reachable.

## Facts: check, don't guess

None of these needs root. MCP clients: the `pulsar` server (`pulsar mcp`,
registered by `pulsar agent add`) exposes `doctor`, `status`, `manifest`,
`report`, `crashes`, `update_check`, `agent_status`, `theme_list`,
`theme_current`, `theme_set` as JSON tools, plus the resource
`pulsar://guide` (this file). Prefer them to parsing text.

| Command | Answers |
|---|---|
| `pulsar doctor --json` | Health checks; exit 1 if one fails. `pulsar doctor <check>` runs one (`--help` lists them). The `cli` check reports a shadowing `pulsar`. |
| `pulsar status --json` | Deployments: booted, staged, rollback, pinned, layered packages. |
| `pulsar manifest --json` | Image version, variant (vanilla/nvidia), kernel, components; hardware under `.host`. |
| `pulsar report` | Doctor + status + manifest, failed units, recent warning+ journal, GPU driver, Flatpak state. Redacted JSON. Use when something is broken. |
| `pulsar report --crash latest` | One crash: program, signal, package, unit, crashing thread's stack, its log lines. `pulsar doctor crashes` lists this boot's. |
| `pulsar doctor flatpak-gl` | Whether running Flatpak apps (Steam) have the NVIDIA driver. An app started before its GL extension arrived renders black on the iGPU; quit and reopen it. |
| `pulsar update --check --json` | Exit 0 current or staged, 10 newer available, 1 couldn't tell. |
| `pulsar pin --json` | Whether the booted deployment is pinned. |
| `pulsar agent guard --json` | `on`: layering and system Flatpak installs ask for a password. `off`: they don't. |
| `pulsar verify` | Whether the running image's signature checks out. |

## Updates and rollback

- `sudo pulsar update` (only when asked) stages the new image for the next
  boot. Tell the user a reboot is pending.
- `pulsar-update-auto.timer` stages updates in the background (AC power,
  unmetered only). Nothing reboots by itself. Disabling the timer is the
  user's call.
- `sudo pulsar rollback` makes the previous deployment the next boot's
  default. greenboot rolls back on its own after a boot fails health checks.
- `sudo pulsar pin on` keeps the booted deployment from garbage collection.
- **Rollback covers the OS image only.** Not `$HOME`, `/var` (incl.
  `/usr/local`, `/opt`), Flatpaks or their data, toolboxes, containers.

## Changing /etc

- Each deployment has its own `/etc`. A rollback boots the older copy, so
  recent edits vanish, and the next update merges forward from that.
- Don't edit `/etc` to "fix" something the image ships: the local edit
  outlives updates and silently shadows the real fix. If you must, name the
  file to the user.
- Before editing: `sudo cp -a <file> <file>.pre-agent`.
  `sudo ostree admin config-diff` lists every `/etc` file that differs from
  the image.
- A file moved (`mv`) or `cp -a`'d into `/etc` from `$HOME` keeps the
  `user_home_t` label and its service gets denied. Run
  `sudo restorecon -v <file>`.
- Before a session that will touch `/etc`, suggest the user run
  `sudo pulsar checkpoint`: it snapshots `/etc`, their dotfiles, `~/.config`,
  `~/.local/bin`, `~/.ssh`, and pins the deployment. Its `list`, `diff`,
  `restore`, `drop` are theirs to run, not yours.

## Logs

- `journalctl -b -p warning`: this boot's warnings and errors (needs wheel,
  adm or systemd-journal).
- `systemctl --failed`, `systemctl --user --failed`.
- `journalctl -u <unit>` (system), `journalctl --user -u <unit>` (user).

| Pulsar units | |
|---|---|
| System | `pulsar-flatpaks.service` (default Flatpaks, first online boot), `pulsar-gamemode-group.service`, `scx.service` (scheduler), `greenboot-healthcheck.service`, `pulsar-update-auto.timer`, `pulsar-update-stage.service` (the Update button), `pulsar-esp-fallback.service`, `pulsar-steam-grants.service` (Steam's sandbox grants) |
| System, nvidia image | `pulsar-gl-nvidia.service` (Flatpak GL driver), `nvidia-cdi-refresh.service`, `pulsar-gpu-containers.service`, `pulsar-akmods-cert.service` |
| User | `pulsar-update-check.timer` (update notification), `pulsar-gl-check.path`, `pulsar-crash-watch.path`, `pulsar-steam-gpu-watch.service`, `gamescale-reconcile.service`, `pulsar-theme-init.service`, `podman-auto-update.timer` |

## Skills

`/usr/share/pulsar/skills/<name>/SKILL.md`: `pulsar-theme` (make, check,
apply desktop themes). `pulsar agent add` links them where your agent looks.
If your agent doesn't load skills, read the `SKILL.md` when a task fits.

## Do not

- Edit or replace anything under `/usr`, or remount it read-write.
- `rpm-ostree install|override|rebase|reset`, `bootc switch`, or any
  `ostree admin` write, unless the user asked for exactly that.
- Reboot, or run `pulsar update --apply`.
- Install into `/usr/local` or `/opt` (`sudo make install`, vendor `.sh`
  installers). Use a toolbox, `mise` or `~/.local/bin`.
- `flatpak install|uninstall` without `--user`, or `flatpak remote-add|
  remote-modify`, unless asked.
- Disable `greenboot-healthcheck.service`: it is what rolls back a bad update.
