# Handing Pulsar to an agent

What a coding agent running on Pulsar can change, and how to undo it.

## What Silverblue protects

These come from Fedora Silverblue / bootc, not from Pulsar:

1. **`/usr` is read-only.** Not even root can edit a system binary or shipped
   config in place.
2. **Every OS change is a new deployment.** `rpm-ostree install`, an update
   and a rebase each build a new deployment beside the booted one, which the
   machine uses only after a reboot. The old one stays on disk.
3. **Going back is one reboot.** `sudo pulsar rollback` makes the previous
   deployment the default; greenboot does it automatically after three boots
   in a row fail its health checks (its default
   [`GREENBOOT_MAX_BOOT_ATTEMPTS`](https://github.com/fedora-iot/greenboot-rs/blob/main/etc/greenboot/greenboot.conf)).
   `sudo pulsar pin on` keeps a deployment from being garbage-collected.

Staging a deployment doesn't change the running system. Discard a staged
deployment before rebooting (`sudo rpm-ostree cleanup --pending`), or roll
back after.

## What an agent running as you can and cannot do

"As you" means a CLI started from your terminal, with your UID.

| Target | Without your password | Undo |
|---|---|---|
| `/usr` (the OS image) | nothing | n/a |
| Stage a deployment (`rpm-ostree install`, `upgrade`, `rollback`, `cleanup`) | **yes**, see below; with guard on, only `upgrade` | `sudo rpm-ostree cleanup --pending` before a reboot, `sudo pulsar rollback` after |
| System Flatpaks (install or remove) | **yes**, see below; with guard on, nothing | reinstall; `sudo pulsar setup apps` restores the defaults |
| Flatpak remotes (add, modify) | nothing: polkit asks | n/a |
| Reboot (`systemctl reboot`) | **yes**: systemd-logind's [default policy](https://github.com/systemd/systemd/blob/main/src/login/org.freedesktop.login1.policy) allows it for any active session | nothing to undo, but it boots whatever is staged |
| `/etc` | nothing: it is root-owned | a copy you made first; `sudo ostree admin config-diff` shows what differs from the image |
| `/usr/local`, `/opt` (links to `/var/usrlocal`, `/var/opt`) | nothing: they are root-owned | delete by hand; no update or rollback touches them |
| `$HOME`: code, dotfiles, SSH keys, browser profiles | **everything**; sandboxed, only the project it was started in | settings (dotfiles, `~/.config`, `~/.local/bin`, `~/.ssh`): a checkpoint taken first. Everything else: your backups |
| User Flatpaks and all Flatpak app data (`~/.var/app`) | everything | your backups |
| Toolboxes, podman containers, user systemd units | everything | recreate them |

The "yes" rows come from Fedora's polkit rules,
[`org.projectatomic.rpmostree1.rules`](https://src.fedoraproject.org/rpms/fedora-release/blob/rawhide/f/org.projectatomic.rpmostree1.rules)
and Flatpak's
[`org.freedesktop.Flatpak.rules`](https://github.com/flatpak/flatpak/blob/main/system-helper/org.freedesktop.Flatpak.rules.in).
They let a `wheel` member in an active local session do these without a
password, and an agent started from your terminal is in that session.
AGENTS.md tells agents to ask you first anyway.

`sudo pulsar agent guard on` makes them ask. It installs
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

## What is not protected

- **`$HOME`, unless the agent is sandboxed.** Rollback restores only the OS,
  so it can't bring back deleted source or a rewritten `~/.ssh/config`, undo
  a force-push, or revoke a leaked token. The sandbox limits the agent to one
  project and takes away force-push and your keys; inside the project, commit
  often and keep backups. A session started with
  `pulsar agent run <agent> --tmux <name>` in a git repository snapshots the
  project's files first, and `pulsar agent undo <name>` puts them back; it
  leaves ignored files, commits and branches alone, and it is not a backup.
  `pulsar agent diff <name>` shows what changed since that snapshot, and the
  Agents app shows the same diff beside the session's terminal.
  `pulsar agent undo <name> --file <path>` puts back one file, even while the
  session runs, and `--redo` takes that back too.
  Archiving a session (`pulsar agent sessions --archive <name>`, or Archive
  in the Agents app) ends it and keeps its record, worktree, branch and
  snapshots. `pulsar agent sessions --tidy`, which the Agents app runs at
  each start, forgets sessions archived 7 or more days ago: their snapshots
  are deleted and a clean worktree is removed. A worktree with uncommitted
  changes is never removed, and branches always stay.
- **`/etc` across rollback.** Each deployment has its own `/etc`; updates
  carry local edits forward with a three-way merge. Rolling back boots the
  older copy, which can restore files you meant to change, lack edits made
  since, and then merge forward from there. See "Undoing an `/etc` change".
- **`/var`**, shared by every deployment and never versioned: container
  storage, libvirt images, Flatpak installations, `/var/home`, `/usr/local`,
  `/opt`.
- **Flatpak data** in `~/.var/app`. Apps can be reinstalled; their data can't.
- **The network.** An agent can reach anything you can, with any credentials
  in your `$HOME`.

## The `agents` toolbox

`pulsar agent add` installs agents into a toolbox named `agents`, which keeps
Node, Python and the agent off the host (`toolbox rm -f agents` removes it
all). It shares your `$HOME`, session bus and UID, and `flatpak-spawn --host`
runs anything on the host, so an agent in it can reach what an agent on the
host can. To isolate an agent, use the sandbox below.

## The sandbox, and a push that never holds your key

`pulsar agent sandbox on` (or `--here`, for one project) runs agents in a
rootless podman container. The agent's usual command does it: `claude` prints
`sandboxed: <project> and the paths you allowed are visible; push: <setting>, through the gate`
as it starts.

What it sees:

- **The project** (the git root), read-write; for a session in its own
  worktree (`--worktree`), only that worktree and the repository's `.git`,
  not the checkout or the other sessions' worktrees. Read-only in either
  case is what git runs things from: `.git/config`, `.git/hooks`, each submodule's
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
    change meanwhile. Two exceptions sign in separately inside the sandbox.
    agy keeps its login in the keyring, which the sandbox can't reach; with
    no session bus it falls back to a file in its own home, but signing in
    that way hasn't been tested yet. opencode 2 keeps its login in
    `opencode.db`, which isn't copied; only a login from opencode 1.x
    (`auth.json`) comes in.

  It isn't your real `~/.claude` because an agent that could write its own
  settings could add a hook or MCP server your unsandboxed agent would run on
  the host.
- **Its session's scratch folder**, read-write, for a session started with
  `--tmux`: `/var/tmp/pulsar-agents/<session>` (`$PULSAR_SCRATCH`), where the
  guide tells agents to put VM disks, builds and downloads. It's deleted with
  the session (`--forget`, or `--tidy` a week after it's archived).
- `~/.gitconfig` (read-only, so commits are yours), the guide and skills, and
  anything you `pulsar agent sandbox allow` (read-only unless `--rw`).

Not visible: the rest of `$HOME`, SSH keys and agent, browser profiles, other
projects, the session bus, `flatpak-spawn`. It refuses to start from `$HOME`
itself.

**Project agent config** (`.claude/`, `.mcp.json`, `.codex/`, `.gemini/`,
`.agents/`, `.opencode/`, `opencode.json`) is read-only inside if it exists.
`.agents/` is where agy reads a project's hooks and MCP servers, and where
Codex, opencode and agy read its skills. One the
sandbox *creates* is renamed to `<name>.from-sandbox` at session end, so no
agent loads it until you've read it.

Pushes go through a gate. Inside, the project's remotes point at
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

Pull requests go through the gate too. Inside, `gh` is the gate's client and
supports only `gh pr create`: the gate opens the PR on GitHub as you, with a
token from your host's `git credential` that never enters the sandbox. The
head must already be pushed through the gate, and `push off` means no PRs.
It can't merge, close, comment on or edit a PR, and it works only with
GitHub.

`.git/config` stays read-only, so `push -u` can't record upstream tracking
inside. At session end Pulsar sets `branch.<name>.remote` and `.merge` on the
host for each branch that reached the real remote, and nothing else.

Sandbox settings come from three layers, most specific first. The repo's
file is inside the project, where the agent can write, so it can only make
the setting stricter:

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
- The image's default `/etc` is in `/usr/etc/<path>`
  ([OSTree's deployment docs](https://ostreedev.github.io/ostree/deployment/)).
- After restoring a file by hand, run `sudo restorecon -v <file>`: `cp -a` and
  `mv` keep the old SELinux label, and a `user_home_t` file in `/etc` is
  denied to its reader.

## The MCP server

`pulsar mcp` is an MCP server on stdio. `pulsar agent add` registers it (as
`pulsar`, only if no entry exists) with Claude Code, Codex, Antigravity
CLI (`~/.gemini/config/mcp_config.json`), Gemini CLI and opencode. Tools are the CLI's `--json` answers: `doctor`, `status`,
`manifest`, `report`, `crashes`, `update_check`, `agent_status`,
`theme_list`, `theme_current`, plus the guide as a resource.

Its writes are `theme_set` (the user's desktop theme, undone by
`pulsar theme revert`), `session_message`, `job_start`, `job_stop`,
`machine_job`, `machine_run` and `machine_fetch`, each
marked as a write so the agent's own permission prompt asks you. Nothing
needs root and no root command is exposed: update, rollback, checkpoint,
guard and pin stay yours. The sandbox doesn't include it (it reads the
host).

Sessions talking to each other: `session_read` returns another session's
screen, which can hold anything that session's agent printed, so an agent
reading it is reading untrusted text.

A message from `session_message` reaches the other agent with a label naming
the sender, only once that agent has ended its turn. A Claude Code session
gets it from its own hooks, and nothing is typed: at the end of a turn its
Stop hook answers "keep going" with the messages, and while it sits idle a
background hook (`asyncRewake`) waits up to an hour for mail and wakes it
with the messages. That can happen while you're looking at the session; it
doesn't touch what you're typing. Antigravity CLI gets it from its Stop hook
the same way at the end of a turn ("continue", in agy's words). Codex CLI,
and an idle Antigravity CLI, get it typed into the prompt with Enter, only
when Pulsar's own turn-end hook has marked the turn's end (a file beside the
session's record; a bell in the agent's output doesn't count) and nobody is
looking at the session. Nothing is typed into a permission question, where
that Enter would answer for you, or into the shell left in a pane after its
agent exits. Other agents (opencode) take no messages: Pulsar can't tell
when their turns end.

Sandboxed sessions take no messages yet. Every sandboxed Claude session
shares one home, which each of them can write, so nothing there can say
when a particular one has ended its turn; Pulsar never writes mail into it
and never reads an unsandboxed session's turn ends from it.

Every message is logged in `~/.local/state/pulsar/agents/messages.log`. One
session can send another at most 10 in 10 minutes, and Agents > Preferences
(or `pulsar agent messages off|on --cap N`) turns messages off or changes
the cap; both apply to every sender, named or not. The sender's name is what
the sending session said it was: Pulsar fills it in for an agent using
`session_message` (which refuses when it can't tell), but an agent with a
shell can run `pulsar agent send --from` with any name, or change the cap
the same way. A message with no sender is labelled as from a sender that
gave no name, never as from you, and a line of a message that starts with
`[` is shifted by a space, so a message can't pass one off as a header.

A job started with `job_start` runs as you, outside any sandbox, so a
sandboxed agent can't start one: it has no `pulsar mcp`.

## Other machines

`pulsar machine` reaches your other Pulsar machines with your own SSH setup:
no relay, no account. Every call is `ssh` in BatchMode, so a key that needs a
prompt fails instead of asking. On the other side, `machine exec` runs only
`pulsar agent ...` and `pulsar job wait|log|list|stop`.

`machine run` and `machine job` send code by git: your branch, plus what
isn't committed as one commit made in a scratch index, pushed to a new
branch in the same project under your home there (made if missing, never
over a folder that isn't a repository). A branch that's there already is
refused, not overwritten. The agent or job there runs as you on that
machine, with that machine's own settings: its sandbox default, its agents'
logins. `machine fetch` brings a session's branch back under
`refs/remotes/<machine>/`, so nothing changes in your checkout until you
merge it yourself.

Announcing (`pulsar machine announce on`, or the switch in Agents >
Preferences) is off by default. On, a user service publishes this machine
on the local network over mDNS as `_pulsar._tcp`, with your user name, its
host name, its Pulsar release and whether SSH is on: anyone on that network
can see those. It opens nothing; reaching the machine still takes your SSH
key.

A Claude Code session started this way in a project new to that machine
stops at Claude's question about trusting the folder; open it in the app to
answer.

## A local model

`pulsar agent model on` runs llama.cpp's server image as a rootless podman
user service (a quadlet): CUDA on the NVIDIA image via CDI, Vulkan with a
`/dev/dri`, CPU otherwise. The model downloads from Hugging Face into
`~/.local/share/pulsar/models`. opencode gets a "Local (Pulsar)" provider;
aider gets a printed command line.

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

The agent sends what it reads to its provider, as it would if you pasted the
report in. Command lines can hold secrets the redaction misses:
`pulsar report --crash <pid> --text` shows exactly what would be sent.

With no agent installed there's no notification. `pulsar doctor crashes`
lists this boot's crashes either way.

## How agents find out about this machine

The image ships one guide for every agent, `/usr/share/pulsar/AGENTS.md`,
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
   - Antigravity CLI (`agy`): `~/.gemini/config/rules/pulsar.md`, a file
     rather than a link. agy drops a rules file without a `trigger` in its
     front matter, so this one is five lines that set `trigger: always_on`
     and include the guide with `@[Pulsar machine guide](/usr/share/pulsar/AGENTS.md)`.
   - Gemini CLI: a printed hint to add `@/usr/share/pulsar/AGENTS.md` to
     `~/.gemini/GEMINI.md` (a symlink would break `/memory add`).
   - aider: the shim passes `--read /usr/share/pulsar/AGENTS.md`.

   It also links each skill in `/usr/share/pulsar/skills/` into the agent's
   skills folder (`~/.claude/skills`, `~/.agents/skills` for Codex,
   `~/.gemini/config/skills` for agy, `~/.gemini/skills`,
   `~/.config/opencode/skills`), never over a folder of yours with the same
   name.

   Gemini CLI and aider are no longer offered in `pulsar agent list`, but
   `agent add`, `run` and `remove` still work for them. Google moved free
   and AI Pro/Ultra accounts from Gemini CLI to Antigravity CLI on
   2026-06-18, and aider has had no release since 2026-02-12.

   **Vendor-installed agents** (e.g. Claude Code's `install.sh` writing
   `~/.local/bin/claude`) are left as they are: `agent add` installs nothing
   and still links the guide. `pulsar agent list` marks them `native`;
   `pulsar agent remove` removes only the link.

For an organization deploying Pulsar, a vendor's managed-policy path (such as
`/etc/claude-code/CLAUDE.md`) with the line `@/usr/share/pulsar/AGENTS.md`
applies the guide to every user.
