# Handing Pulsar to an agent

What "the safest machine to hand to a coding agent" covers, what it doesn't,
and how to undo an agent's changes.

In short: the OS is hard to damage and easy to restore. **Your data is not.**
An agent running as you can do anything to `$HOME` that you can, and rollback
never touches it. A checkpoint restores your settings; documents and projects
need git and backups.

## Why the OS half holds

These come from Fedora Silverblue / bootc, not from Pulsar:

1. **`/usr` is read-only.** Not even root can edit a system binary or shipped
   config in place.
2. **Every OS change is a new deployment.** `rpm-ostree install`, an update,
   a rebase: each builds a deployment beside the booted one, used only after
   a reboot. The old one stays on disk.
3. **Going back is one reboot.** `sudo pulsar rollback` makes the previous
   deployment the default; greenboot does it automatically when a boot fails
   its health checks. `sudo pulsar pin on` keeps a deployment from being
   garbage-collected.

The worst an agent can do to the OS is stage a bad deployment. Discard it
before rebooting (`sudo rpm-ostree cleanup --pending`) or roll back after.

## What an agent running as you can and cannot do

"As you" means a CLI started from your terminal, with your UID.

| Target | Without your password | Undo |
|---|---|---|
| `/usr` (the OS image) | nothing | n/a |
| Stage a deployment (`rpm-ostree install`, `upgrade`, `rollback`, `cleanup`) | **yes**, see below; with guard on, only `upgrade` | `sudo rpm-ostree cleanup --pending` before a reboot, `sudo pulsar rollback` after |
| System Flatpaks (install or remove) | **yes**, see below; with guard on, nothing | reinstall; `sudo pulsar setup apps` restores the defaults |
| Flatpak remotes (add, modify) | nothing: polkit asks | n/a |
| Reboot (`systemctl reboot`) | **yes**: stock systemd, for any active session | nothing to undo, but it boots whatever is staged |
| `/etc` | nothing: it is root-owned | a copy you made first; `sudo ostree admin config-diff` shows what differs from the image |
| `/usr/local`, `/opt` (links to `/var/usrlocal`, `/var/opt`) | nothing: they are root-owned | delete by hand; no update or rollback touches them |
| `$HOME`: code, dotfiles, SSH keys, browser profiles | **everything**; sandboxed, only the project it was started in | settings (dotfiles, `~/.config`, `~/.local/bin`, `~/.ssh`): a checkpoint taken first. Everything else: your backups |
| User Flatpaks and all Flatpak app data (`~/.var/app`) | everything | your backups |
| Toolboxes, podman containers, user systemd units | everything | recreate them |

**The "yes" rows are stock Fedora.** Its polkit rules
(`org.projectatomic.rpmostree1.rules`, `org.freedesktop.Flatpak.rules`) let a
`wheel` member in an active local session do these without a password, and
an agent started from your terminal is in that session. It can only stage the
next system, which is reversible. Not being asked for a password is not
permission; AGENTS.md tells agents so.

**Guard makes them ask.** `sudo pulsar agent guard on` installs
`/etc/polkit-1/rules.d/49-pulsar-guard.rules`, which requires the admin
password for layering, `rollback`, `cleanup`, and system Flatpak installs and
removals. It leaves `upgrade`, `repo-refresh` and Flatpak updates alone (used
by background updates), and doesn't gate reboot (that would gate every
shutdown from GNOME's power menu). `pulsar agent guard` shows what polkit
answers for your session; `sudo pulsar agent guard off` restores the defaults.

**With `sudo`** (a password you gave it, passwordless sudo, or a cached sudo
ticket in its terminal), all of `/etc` and `/var` is exposed too. `/usr` is
still read-only and a new deployment is still only staged, but an `/etc` edit
applies immediately and outlives rollback. Anything installed into
`/usr/local` or `/opt` (`sudo make install`, a vendor `install.sh`) shadows the
image on `PATH`, never appears in `rpm-ostree status`, and outlives every
update and rollback.

## What is NOT protected

- **`$HOME`, unless the agent is sandboxed.** Deleted source, a rewritten
  `~/.ssh/config`, a force-pushed branch, a leaked token: none is an OS change,
  so rollback can't help. The sandbox limits this to one project and removes
  force-push and your keys; within the project, git and backups are the
  defense. A checkpoint restores settings, not documents or projects.
- **`/etc` across rollback.** Each deployment has its own `/etc`; updates
  carry local edits forward with a three-way merge. Rolling back boots the
  older copy, which can restore files you meant to change, lack edits made
  since, and then merge forward from there. Rollback is not an `/etc` undo;
  see "Undoing an `/etc` change".
- **`/var`**, shared by every deployment and never versioned: container
  storage, libvirt images, Flatpak installations, `/var/home`, `/usr/local`,
  `/opt`.
- **Flatpak data** in `~/.var/app`. Apps can be reinstalled; their data can't.
- **The network.** An agent can reach anything you can, with any credentials
  in your `$HOME`.

## The toolbox is not a sandbox

`pulsar agent add` installs agents into a toolbox named `agents`, which keeps
Node, Python and the agent off the host (`toolbox rm -f agents` removes it
all). It is **not** isolation: it shares your `$HOME`, session bus and UID, and
`flatpak-spawn --host` runs anything on the host. Treat an agent there as an
agent on the host. Isolation is the sandbox.

## The sandbox, and a push that never holds your key

`pulsar agent sandbox on` (or `--here`, for one project) runs agents in a
rootless podman container. The agent's usual command does it: `claude` prints
`sandboxed: only ~/code/x is visible` as it starts.

What it sees:

- **The project** (the git root), read-write, except what git runs things
  from, which is read-only: `.git/config`, `.git/hooks`, each submodule's
  config and hooks under `.git/modules`, and any in-project hooks path or
  included config (`core.hooksPath` such as husky's `.husky/_`,
  `include.path`). The agent can commit but can't plant a hook or
  `core.fsmonitor` that would run when *you* next run git. `.git` and each
  submodule's git directory are pinned in place and can't be swapped.
- **Checked at session end**, before Pulsar runs git itself: a new
  `.git/commondir`, or a new or changed `.git` file or folder anywhere in the
  tree, is renamed to `<name>.from-sandbox` with a note. Until then an editor
  running git in the background could follow one: close the editor on the
  project while an untrusted agent works. Linked worktrees and submodule
  checkouts (git directory outside the project) are refused.
- **Its own home**, one per agent (`~/.local/share/pulsar/sandbox/<agent>`),
  for history and caches:
  - small files it also writes (settings, state file, `CLAUDE.md`, the login)
    are **copied in at every start**, over the sandbox's copy;
  - folders it only reads (skills, plugins, hooks, commands) are **mounted
    read-only** from the real ones;
  - the **login is the only thing copied back**, so you sign in once for both
    modes, and only if it's still JSON, changed inside, and your copy didn't
    change meanwhile.

  It isn't your real `~/.claude` because an agent that could write its own
  settings could add a hook or MCP server your unsandboxed agent would run on
  the host.
- `~/.gitconfig` (read-only, so commits are yours), the guide and skills, and
  anything you `pulsar agent sandbox allow` (read-only unless `--rw`).

Not visible: the rest of `$HOME`, SSH keys and agent, browser profiles, other
projects, the session bus, `flatpak-spawn`. It refuses to start from `$HOME`
itself.

**Project agent config** (`.claude/`, `.mcp.json`, `.codex/`, `.gemini/`,
`.opencode/`, `opencode.json`) is read-only inside if it exists. One the
sandbox *creates* is renamed to `<name>.from-sandbox` at session end, so no
agent loads it until you've read it.

**Push goes through a gate.** Inside, the project's remotes point at
`pulsar-agent-gate`, running on the host for the session. A push lands in a
per-project mirror the agent can't see; its hook checks it and pushes to the
real remote **with your credentials**. The agent sees the real remote's reply
but never holds a key or token. The gate allows:

- branches only: no tags, deletions or force-push (the real push never
  passes `--force`, so a moved remote rejects non-fast-forwards);
- only the remotes the project had on its first sandboxed run, **pinned** on
  the host (the project's `.git/config` isn't consulted again).
  `pulsar agent sandbox repin` re-pins after a real remote change;
- with `push branches`, any branch but the default; with `push off`, nothing.
  Pull and fetch go through the same gate.

**Pull requests too.** Inside, `gh` is the gate's client and only supports
`gh pr create`: the gate opens the PR on GitHub as you, with a token from your
host's `git credential` that never enters the sandbox. The head must already be
pushed through the gate; `push off` means no PRs. No merging, closing,
commenting or editing. GitHub only.

`.git/config` stays read-only, so `push -u` can't record upstream tracking
inside. At session end Pulsar sets `branch.<name>.remote` and `.merge` on the
host for each branch that reached the real remote, and nothing else.

**Settings, most specific first**; what the agent could write can only
tighten:

| Layer | Where | Can loosen? |
|---|---|---|
| repo | `<project>/.pulsar/agent.toml`: `sandbox = "on"`, `push = "off"` or `"branches"` | no: it can only turn the sandbox on or push down |
| yours, per project | `~/.config/pulsar/agent-projects`, via `--here` | yes |
| global | `~/.config/pulsar/agent.conf` | yes |

`pulsar agent sandbox` shows the effective setting and which layer set it.
`pulsar agent run <name> --no-sandbox` runs one session unsandboxed, unless the
repo file requires the sandbox.

Limits:

- **The network is open.** The agent needs its API, so project contents can
  leave with it.
- **SELinux doesn't confine it.** Label separation is off, as in toolbox, so
  your files are never relabeled; the mounts do the isolating.
- **Typing an agent's name is sandboxed in interactive bash only.**
  `/etc/profile.d/pulsar-agents.sh` defines `claude`, `codex` and the rest as
  functions that call `pulsar agent run` (which also covers vendor-installed
  agents). Scripts, other shells (zsh, fish) and `command claude` start the
  agent directly. `pulsar agent run <name>` always applies your settings;
  `pulsar agent sandbox wrap off` removes the functions.
- **Review what it writes into the project.** A Makefile, test script or
  `.envrc` runs when you run it.
- **A killed session** (`kill -9`, a crash) skips the end-of-session steps:
  new project agent config isn't renamed and a refreshed login isn't copied
  back.

## Undoing an `/etc` change

`/etc` (sshd, sudoers, network and firewall config) and your settings (shell
rc, git and ssh config, GNOME settings, `~/.local/bin`) are what an agent
session most often changes. Use `pulsar checkpoint`:

```
sudo pulsar checkpoint "before the agent"   # snapshot /etc and your settings, pin the booted deployment
sudo pulsar checkpoint diff                  # what changed, appeared, vanished since
sudo pulsar checkpoint restore <id>          # put changed and deleted files back
sudo pulsar checkpoint drop <id>             # delete it, and unpin what it pinned
```

- `/etc` is saved as a tar with owners, modes, ACLs and SELinux labels.
- Settings of the user who ran `sudo`: top-level dotfiles, `~/.config`
  without caches, `~/.local/bin`, `~/.ssh`, read and written as that user (so a
  planted symlink reaches nothing the user couldn't). Skipped over 512 MB, or
  with `--no-home`.
- The booted deployment is pinned.
- `restore` lists files added since but doesn't delete them. It discards a
  deployment staged since; if a newer one was already booted, it tells you to
  `sudo pulsar rollback`. It restarts nothing: restart services that read
  `/etc`, and log out for GNOME settings.
- It restores **everything** changed since, not only the agent's changes.
  Read `diff` first.
- Every subcommand, including `list` and `diff`, needs root: snapshots hold
  shadow and private keys, and an agent that could restore its own checkpoints
  could erase evidence.
- Not covered: documents, projects, `~/.local/share`, the rest of `/var`,
  Flatpak data, anything sent over the network.

Without a checkpoint:

- `sudo ostree admin config-diff` lists `/etc` files that differ from the
  image: `M` modified, `A` added, `D` deleted.
- Copy a file before an agent edits it (`sudo cp -a <file> <file>.pre-agent`);
  AGENTS.md tells agents to.
- The image's pristine `/etc` is in `/usr/etc/<path>`.
- After restoring a file by hand, run `sudo restorecon -v <file>`: `cp -a` and
  `mv` keep the old SELinux label, and a `user_home_t` file in `/etc` is
  denied to its reader.

## The MCP server

`pulsar mcp` is an MCP server on stdio. `pulsar agent add` registers it (as
`pulsar`, only if no entry exists) with Claude Code, Codex, Gemini CLI and
opencode. Tools are the CLI's `--json` answers: `doctor`, `status`,
`manifest`, `report`, `crashes`, `update_check`, `agent_status`,
`theme_list`, `theme_current`, plus the guide as a resource.

Its one write is `theme_set` (the user's desktop theme, undone by
`pulsar theme revert`). Nothing needs root and no root command is exposed:
update, rollback, checkpoint, guard and pin stay yours. The sandbox doesn't
include it (it reads the host).

## A local model

`pulsar agent model on` runs llama.cpp's server image as a rootless podman
user service (a quadlet): CUDA on the nvidia image via CDI, Vulkan with a
`/dev/dri`, CPU otherwise. The model downloads from Hugging Face into
`~/.local/share/pulsar/models`. opencode gets a "Local (Pulsar)" provider;
aider gets a printed command line. (RTX 5080, 0.5B model: about 550
tokens/s.)

- Listens on `127.0.0.1` only, with a required random key in
  `~/.config/pulsar/model-key` (0600); CORS allows only the server itself.
  llama.cpp's defaults (no key, CORS open) would let any web page use it.
- Doesn't start at login unless `--at-login` (a loaded model holds gigabytes
  of VRAM).
- `off` stops and removes it and the provider; `--purge` deletes the models.
- A sandboxed agent reaches it: the sandbox's network (pasta) forwards that
  one port to the host, and the key is mounted read-only. No other host port
  is reachable.

## Crashes, and what an agent is sent

systemd-coredump records every crash. If you have an agent installed,
`pulsar-crash-watch.path` shows one notification per program per boot with an
"Ask <agent>" button. Nothing is sent until you click it. The click opens a
terminal running `pulsar agent ask --crash <pid>`, which:

- writes `pulsar report --crash <pid>` to a file in `$XDG_RUNTIME_DIR` (yours
  only, deleted at logout): the usual report plus coredumpctl's summary, the
  crashing thread's stack trace and that process's journal lines, redacted.
  **Never the core file**;
- starts your default agent (`pulsar agent default`) with a prompt naming the
  file and ending "Do not change the system without asking me first."

What the agent reads goes to its provider, the same as pasting the report;
the click is consent. Command lines can hold secrets the redaction misses:
`pulsar report --crash <pid> --text` shows exactly what would be sent.

With no agent installed there's no notification. `pulsar doctor crashes`
lists this boot's crashes either way.

## How agents find out about this machine

The image ships one vendor-neutral briefing, `/usr/share/pulsar/AGENTS.md`,
updated with the image. It covers the read-only `/usr`, toolboxes, Flatpaks,
`pulsar doctor/status/manifest --json` and `pulsar report`, staging vs.
rebooting, rollback and its limits, logs, and what not to touch.

1. **`pulsar agent guide`** prints it; works with any agent ("run
   `pulsar agent guide` first"). `pulsar agent --json` adds the installed
   agents and whether guard is on.
2. **`pulsar agent add <name>`** symlinks it (so it follows image updates) into
   the agent's global instructions path, **only if that path is free**:
   - Claude Code: `~/.claude/rules/pulsar.md` (loads in every project, leaves
     `~/.claude/CLAUDE.md` alone).
   - Codex CLI: `$CODEX_HOME/AGENTS.md` (default `~/.codex`).
   - opencode: `~/.config/opencode/AGENTS.md`.
   - Gemini CLI: a printed hint to add `@/usr/share/pulsar/AGENTS.md` to
     `~/.gemini/GEMINI.md` (a symlink would break `/memory add`).
   - aider: the shim passes `--read /usr/share/pulsar/AGENTS.md`.

   It also links each skill in `/usr/share/pulsar/skills/` into the agent's
   skills folder (`~/.claude/skills`, `$CODEX_HOME/skills`,
   `~/.gemini/skills`, `~/.config/opencode/skills`), never over a folder of
   yours with the same name.

   **Vendor-installed agents** (e.g. Claude Code's `install.sh` writing
   `~/.local/bin/claude`) are left as they are: `agent add` installs nothing
   and still links the guide. `pulsar agent list` marks them `native`;
   `pulsar agent remove` removes only the link.

For an organization deploying Pulsar, a vendor's managed-policy path (such as
`/etc/claude-code/CLAUDE.md`) with the line `@/usr/share/pulsar/AGENTS.md`
applies the guide to every user.
