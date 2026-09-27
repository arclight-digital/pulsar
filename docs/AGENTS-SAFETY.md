# Handing Pulsar to an agent

The pitch is that Pulsar is **the safest machine to hand to a coding agent**.
This document says what that claim covers, what it does not, and what to do
when an agent has changed something you want back.

The short version: the operating system is hard to damage and easy to
restore. **Your data is not.** An agent that runs as you can do anything to
`$HOME` that you can, and no part of this image rolls that back.

## Why the OS half holds

Pulsar is a bootc image on Fedora Silverblue. Three properties do the work,
and none of them is Pulsar-specific. They come from the base system:

1. **`/usr` is read-only.** The OS is one image, mounted read-only. An
   agent cannot edit a system binary or a shipped config file in place, even
   as root.
2. **Every OS change is a new deployment.** `rpm-ostree install`, an update, a
   rebase: each builds a separate deployment next to the booted one. The
   change takes effect only after a reboot, and the old deployment stays on
   disk.
3. **Going back is one reboot.** `sudo pulsar rollback` makes the previous
   deployment the default. greenboot does it automatically when a boot fails
   its health checks. `sudo pulsar pin on` keeps a known-good deployment from
   being garbage-collected.

So the worst an agent can do to the OS is stage a bad deployment. You can
discard it before rebooting (`sudo rpm-ostree cleanup --pending`), or roll
back after rebooting.

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
| `/usr/local`, `/opt` (links to `/var/usrlocal`, `/var/opt`) | nothing: they are root-owned | delete what was put there by hand. No update or rollback touches them |
| `$HOME`: code, dotfiles, SSH keys, browser profiles | **everything**; sandboxed, only the project it was started in | your backups. Nothing here rolls `$HOME` back |
| User Flatpaks and all Flatpak app data (`~/.var/app`) | everything | your backups |
| Toolboxes, podman containers, user systemd units | everything | recreate them |

**The "yes" rows are stock Fedora, not a Pulsar choice.** Fedora's polkit
rules (`org.projectatomic.rpmostree1.rules`, `org.freedesktop.Flatpak.rules`)
let a member of `wheel` in an active local session run these without a
password prompt. An agent started from your desktop terminal is in that
session. It still cannot touch the booted system: what it can do is stage the
next one. That is exactly the kind of change the deployment model makes
reversible, and it is why this document does not call the rows a hole. It
does make the AGENTS.md line "not being asked for a password is not
permission" a real instruction rather than a nicety.

**Guard makes them ask.** `sudo pulsar agent guard on` installs a polkit rule
(`/etc/polkit-1/rules.d/49-pulsar-guard.rules`) that answers "ask for the
admin password" for layering, `rollback`, `cleanup`, and system Flatpak
installs and removals, before the stock rules can answer "yes". It is opt-in
because it departs from Silverblue's defaults and costs a human one more
prompt. It leaves `upgrade`, `repo-refresh` and Flatpak updates alone, which
is what GNOME Software's background updates use. It does not gate reboot:
logind's action is the one GNOME's own power menu uses, and making that ask
for a password would make every shutdown ask too. `pulsar agent guard` shows
what polkit answers for your session, and `sudo pulsar agent guard off` puts
the defaults back.

With `sudo`, all of `/etc` and `/var` is exposed too. That happens if you
give an agent a password, set up passwordless sudo, or leave a cached sudo
ticket in the terminal it runs in. `/usr` is still read-only, and a new
deployment is still just a staged deployment. But an `/etc` edit takes effect
immediately, and it outlives rollback (next section).

`/var` includes `/usr/local` and `/opt`, which are links into it. A binary a
root agent installs there (`sudo make install`, a vendor's `install.sh`)
shadows the image on `PATH`, never appears in `rpm-ostree status`, and
outlives every update and rollback. It is a way around the read-only `/usr`
that the deployment model does not see at all.

## What is NOT protected

Be exact about this when you make the pitch:

- **`$HOME`, unless the agent is sandboxed.** Deleted source, a rewritten
  `~/.ssh/config`, a force-pushed branch, a leaked token: none of it is an OS
  change, so none of it has a deployment to roll back to. The sandbox (below)
  narrows this to the one project the agent was started in, and takes
  force-push and your keys off the table; inside that project, git and
  backups are still the defense.
- **`/etc` across rollback.** Each deployment has its own `/etc`, and updates
  carry local edits forward with a three-way merge. Rollback boots the old
  deployment's copy. That can bring back files you wanted changed, or keep an
  edit you did not want, depending on when the edit happened relative to the
  update. An edit made after the old deployment was current is simply
  missing once you boot it, and the next update merges forward from there,
  so an edit can vanish without anyone removing it. Rollback is not an
  `/etc` undo. See "Undoing an `/etc` change" below.
- **`/var`.** Everything under it is shared by every deployment: container
  storage, libvirt images, Flatpak installations, `/var/home`, and
  `/usr/local` and `/opt`, which are links into it. None of it is versioned.
- **Flatpak data.** Apps can be reinstalled. Their data in `~/.var/app`
  cannot.
- **The network.** An agent can reach anything you can, with whatever
  credentials your `$HOME` holds.

## The toolbox is not a sandbox

`pulsar agent add` installs each agent into a toolbox named `agents`. That
keeps Node, Python and the agent itself out of the image and off the host's
package database, and `toolbox rm -f agents` deletes all of it. It is **not**
an isolation boundary. The box shares your `$HOME`, your session bus and your
UID, and `flatpak-spawn --host` runs anything on the host. Treat an agent in
the box as an agent on the host. Anything the box does to `$HOME` is done.

Real isolation is the sandbox, next.

## The sandbox, and a push that never holds your key

`pulsar agent sandbox on` (or `--here`, for one project) starts agents in a
rootless podman container instead. The agent's own command does it: `claude`
stays `claude`, and says `sandboxed: only ~/code/x is visible` as it starts.

What it sees:

- **The project** it was started in (the git root), read-write, except
  `.git/config` and `.git/hooks`, which are read-only. A hook or a
  `core.fsmonitor` planted there would run on the host the next time *you*
  ran git in that repo; read-only, it can still commit but cannot change what
  git runs.
- **A home of its own**, one per agent (`~/.local/share/pulsar/sandbox/<agent>`),
  where its history and caches live. Your agent setup comes in without
  anything going back out:
  - small files it also writes (settings, its state file, `CLAUDE.md`, the
    login) are **copied in at every start**, over whatever the sandbox did to
    its copy;
  - folders it only reads (skills, plugins, hooks, commands) are **mounted
    read-only** from the real ones, so nothing is copied and nothing planted;
  - the **login is the one thing copied back**, so you sign in once for both
    modes. Only if it is still JSON, changed inside, and your own copy did
    not change meanwhile (then yours is newer).

  This is why it is not your real `~/.claude`: an agent that could write its
  own settings could add a hook or an MCP server there, and your unsandboxed
  agent would run it on the host.
- `~/.gitconfig`, read-only, so commits are still yours; the guide and the
  skills; anything you `pulsar agent sandbox allow` (a tool your hooks run,
  read-only unless `--rw`).

What it does not: the rest of `$HOME`, your SSH keys and agent, browser
profiles, other projects, the session bus, `flatpak-spawn`. It refuses to
start from `$HOME` itself.

**Project agent config** (`.claude/`, `.mcp.json`, `.codex/`, `.gemini/`,
`.opencode/`, `opencode.json`) is read-only inside when it exists, like
`.git/config`: your agent loads it by itself. One the sandbox *creates* is
renamed to `<name>.from-sandbox` when the session ends, with a note, so no
agent loads it until you have read it.

**Push goes through a gate.** Inside, the project's remotes point at
`pulsar-agent-gate`, which runs on the host for the length of the session.
A push arrives in a per-project mirror the agent cannot see; its hook checks
the push and, if it passes, pushes it to the real remote **with your
credentials**, whatever you already use. The agent sees the real remote's
answer in its own `git push`. It never holds a key or a token. The gate
allows:

- branches only: no tags, no deleting, no force-push (the real push never
  passes `--force`, so a remote that moved refuses a non-fast-forward itself);
- the remotes the project had the first time it ran sandboxed, **pinned**
  then, on the host. The project's `.git/config` is not consulted again, so an
  agent cannot point `origin` somewhere else and push there as you.
  `pulsar agent sandbox repin` re-pins after a real change of remote;
- with `push branches`, anything but the default branch; with `push off`,
  nothing. Pull and fetch go through the same gate, freshly fetched.

**Pull requests go through it too.** Inside, `gh` is the gate's own client,
and `gh pr create` is the one thing it does: the gate opens the pull request
on GitHub as you, with a token your host's `git credential` gives for
github.com, which never enters the sandbox. The head must already be on the
remote (pushed through the gate), and `push off` means no pull requests.
Nothing else on the forge: no merging, closing, commenting or editing.
GitHub only, for now.

`.git/config` stays read-only for the whole session, so `push -u` cannot
record upstream tracking inside. The gate notes each branch that reached the
real remote instead, and when the session ends Pulsar sets
`branch.<name>.remote` and `.merge` for it on the host, and nothing else. A
config that was writable during the session would be filtered too late: an
editor runs git in the background, and a planted `core.fsmonitor` would
fire before the session ended.

**Settings, most specific first**, where whatever the agent could write can
only tighten:

| Layer | Where | Can loosen? |
|---|---|---|
| repo | `<project>/.pulsar/agent.toml`: `sandbox = "on"`, `push = "off"` or `"branches"` | no: it can only turn the sandbox on or push down |
| yours, per project | `~/.config/pulsar/agent-projects`, via `--here` | yes |
| global | `~/.config/pulsar/agent.conf` | yes |

`pulsar agent sandbox` shows the answer for the project you are in and
which layer gave it. `pulsar agent run <name> --no-sandbox` starts one
session unsandboxed, except where the repo file says otherwise.

What it does **not** do, said plainly:

- **The network is open.** The agent needs its API. The sandbox limits what
  it can read, not where it can send what it read: the project's contents
  can still leave with it.
- **SELinux is not confining it.** Label separation is off, as toolbox has
  it, so your files are never relabeled; the mounts do the isolating.
- **Typing an agent's name is sandboxed in interactive bash only.**
  `/etc/profile.d/pulsar-agents.sh` makes `claude`, `codex` and the rest
  shell functions that go through `pulsar agent run`, which is what reaches
  an agent installed with its vendor's own installer. A script that runs the
  agent, another shell (zsh, fish), or `command claude` starts it as
  installed. `pulsar agent run <name>` always goes through the settings;
  `pulsar agent sandbox wrap off` turns the functions off.
- **What it writes into the project is yours to review.** A Makefile, a test
  script or an `.envrc` it edits runs when you run it.
- **A session killed outright** (not ended: `kill -9`, a crash) skips the
  end-of-session steps: new project agent config is not defused and a
  refreshed login is not copied back.

## Undoing an `/etc` change

The OS half already has an undo. `/etc` is the piece that matters most after
an agent session. It holds sshd config, sudoers, network and firewall config,
and it survives rollback in ways that are hard to reason about. Its undo is
`pulsar checkpoint`:

```
sudo pulsar checkpoint "before the agent"   # snapshot /etc, pin the booted deployment
sudo pulsar checkpoint diff                  # what changed, appeared, vanished since
sudo pulsar checkpoint restore <id>          # put changed and deleted files back
sudo pulsar checkpoint drop <id>             # delete it, and unpin what it pinned
```

A checkpoint keeps `/etc` as a tar with owners, modes, ACLs and SELinux
labels, so a restored file comes back as it was, label included. It also pins
the booted deployment so the OS state it describes cannot be garbage
collected. `restore` does not delete files added since: it lists them, because
one of them may be the change you wanted. It discards a deployment staged
since the checkpoint, and if a newer one has already been booted it tells you
to `sudo pulsar rollback` instead of rebooting for you.

It restores **all** of `/etc` that changed since, not only what the agent
touched. Read `diff` before `restore`.

It needs root on purpose, for every subcommand including `list` and `diff`:
the snapshot holds shadow and private keys, and an agent that can take and
restore its own checkpoints can also erase the evidence of what it did. It
does not cover `$HOME`, the rest of `/var`, Flatpak data, or anything sent
over the network.

Without a checkpoint:

- `sudo ostree admin config-diff` lists every `/etc` file that differs from
  what the image ships: `M` modified, `A` added, `D` deleted. Run it after a
  session to see what was touched.
- Before an agent edits a file there, copy it (`sudo cp -a <file>
  <file>.pre-agent`). AGENTS.md tells agents to do exactly that.
- A file you want back to the image's version can be copied from
  `/usr/etc/<path>`, which holds the image's pristine `/etc`.
- After putting a file back by hand, run `sudo restorecon -v <file>`. `cp -a`
  and `mv` carry the old SELinux label with them, and a file labelled
  `user_home_t` in `/etc` gets its reader denied.

## The MCP server

`pulsar mcp` is an MCP server on stdio, and `pulsar agent add` registers it
with each agent that speaks MCP (Claude Code, Codex, Gemini CLI, opencode),
as an entry named `pulsar` written only if none exists. Its tools are the
CLI's own `--json` answers: `doctor`, `status`, `manifest`, `report`,
`crashes`, `update_check`, `agent_status`, `theme_list`, `theme_current`,
and the guide as a resource.

It can change one thing, on purpose: `theme_set`, the user's own desktop
theme, through the same engine as `pulsar theme set` and undone by
`pulsar theme revert`. Nothing in it needs root, and none of the root
commands are there: update, rollback, checkpoint, guard and pin stay
commands the user runs. An agent that could call them could undo the checks
meant to hold it. The sandbox leaves the server out: it reads the host.

## Crashes, and what an agent is sent

systemd-coredump records every crash. When one of your programs crashes and
you have an agent installed, `pulsar-crash-watch.path` puts up one
notification per program per boot, with an "Ask <agent>" button. Nothing is
sent anywhere until you click it. The click opens a terminal on
`pulsar agent ask --crash <pid>`, which:

- writes `pulsar report --crash <pid>` to a file in `$XDG_RUNTIME_DIR` (yours
  only, gone at logout). That is the usual report plus the crash:
  coredumpctl's summary, the crashing thread's stack trace and that process's
  journal lines, with the same redaction. **Never the core file**, which holds
  the program's memory;
- starts your default agent (`pulsar agent default`) with a prompt that names
  the file and ends "Do not change the system without asking me first."

From then on the agent reads the file like any other, and what it reads goes
to its provider. That is the same exposure as pasting the report into it, and
the button is the consent. A program's command line can carry secrets that
the redaction does not recognize, so `pulsar report --crash <pid> --text`
shows exactly what would go.

With no agent installed the watcher stays silent. `pulsar doctor crashes`
lists this boot's crashes either way.

## How agents find out about this machine

The image ships one vendor-neutral briefing, `/usr/share/pulsar/AGENTS.md`.
It updates with the image, so it never describes an older system than the one
it ships in. It covers the read-only `/usr`, toolboxes for dev tools, Flatpaks
for apps, `pulsar doctor/status/manifest --json` and `pulsar report` for
facts, staging vs. rebooting, rollback and its limits, where the logs are, and
what not to touch.

Agents discover it in two ways:

1. **`pulsar agent guide`** prints it. This works for every agent, including
   one that reads no instruction files at all: put "run `pulsar agent guide`
   first" in a prompt. `pulsar agent --json` adds what else the machine
   gives it: the agents installed and whether guard is on.
2. **`pulsar agent add <name>`** links it into the one global instructions
   path the chosen agent reads by itself, **only if that path is free**. It
   uses a symlink, so the link follows image updates:
   - Claude Code: `~/.claude/rules/pulsar.md`. User-level rules load in every
     project with no import approval, and it leaves the user's own
     `~/.claude/CLAUDE.md` alone.
   - Codex CLI: `$CODEX_HOME/AGENTS.md` (default `~/.codex`).
   - opencode: `~/.config/opencode/AGENTS.md`.
   - Gemini CLI: a printed one-line hint (`@/usr/share/pulsar/AGENTS.md` for
     `~/.gemini/GEMINI.md`). Its only global file is the one `/memory add`
     writes to, and a symlink into read-only `/usr` would break that.
   - aider: the shim passes `--read /usr/share/pulsar/AGENTS.md` whenever the
     image has it, because aider reads nothing unless asked.

   It also links each skill in `/usr/share/pulsar/skills/` (Agent Skills
   layout) into that agent's own skills folder: `~/.claude/skills`,
   `$CODEX_HOME/skills`, `~/.gemini/skills`, `~/.config/opencode/skills`.
   One link per skill, never over a folder of the user's with the same name.

   **An agent installed its own way is supported too.** If a vendor's
   installer already put the command on `PATH` (Claude Code's `install.sh`
   writes `~/.local/bin/claude`), `agent add` leaves it exactly as it is,
   never installs a second copy, and still links the guide.
   `pulsar agent list` marks it `native`, and `pulsar agent remove` takes back
   only the link.

Rejected alternatives:

- **`~/AGENTS.md` seeded at first login.** Claude Code walks parent
  directories, so it would read the file in every project under `$HOME` that
  has no `CLAUDE.md`. Codex
  walks only from the git root down, so it would never read it. The result is
  inconsistent coverage plus a file in everyone's home that nobody asked for,
  and a user unit to create it.
- **`/etc/skel`.** Reaches only accounts created after the image ships, so it
  misses the people already using it.
- **Vendor managed-policy paths** such as `/etc/claude-code/CLAUDE.md`. These
  are enterprise policy locations: loaded for every user, not excludable by
  them, and specific to one vendor. Shipping one by default would make the
  image take a side, which the no-agent-by-default rule exists to prevent.
  They are still the right tool for an organisation that deploys Pulsar, and
  one line (`@/usr/share/pulsar/AGENTS.md`) is all they need.

## Proposals, not built

Each of these is a decision for the maintainer, not a default:

- **Automatic checkpoints.** For example,
  before each `pulsar update`. Probably not: a checkpoint is only useful if
  you know which one predates the thing you want to undo, and automatic ones
  pile up pins.
