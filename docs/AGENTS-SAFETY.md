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

1. **`/usr` is read-only.** The OS is a signed image, mounted read-only. An
   agent cannot edit a system binary or a shipped config file in place, even
   as root.
2. **Every OS change is a new deployment.** `rpm-ostree install`, an update, a
   rebase: each builds a separate deployment next to the booted one. The
   change takes effect only after a reboot, and the old deployment stays on
   disk.
3. **Going back is one reboot.** `sudo pulsar rollback` makes the previous
   deployment the default. greenboot does it automatically when a boot fails
   its health checks. `sudo pulsar pin` keeps a known-good deployment from
   being garbage-collected.

So the worst an agent can do to the OS is stage a bad deployment. You can
discard it before rebooting (`sudo rpm-ostree cleanup --pending`), or roll
back after rebooting.

## What an agent running as you can and cannot do

"As you" means a CLI started from your terminal, with your UID.

| Target | Without your password | Undo |
|---|---|---|
| `/usr` (the OS image) | nothing | n/a |
| Stage a deployment (`rpm-ostree install`, `upgrade`, `rollback`, `cleanup`) | **yes**, see below | `sudo rpm-ostree cleanup --pending` before a reboot, `sudo pulsar rollback` after |
| System Flatpaks (install or remove) | **yes**, see below | reinstall; `sudo pulsar setup apps` restores the defaults |
| `/etc` | nothing: it is root-owned | a copy you made first; `sudo ostree admin config-diff` shows what differs from the image |
| `$HOME`: code, dotfiles, SSH keys, browser profiles | **everything** | your backups. Nothing here rolls `$HOME` back |
| User Flatpaks and all Flatpak app data (`~/.var/app`) | everything | your backups |
| Toolboxes, podman containers, user systemd units | everything | recreate them |

**The two "yes" rows are stock Fedora, not a Pulsar choice.** Fedora's polkit
rules (`org.projectatomic.rpmostree1.rules`, `org.freedesktop.Flatpak.rules`)
let a member of `wheel` in an active local session run these without a
password prompt. An agent started from your desktop terminal is in that
session. It still cannot touch the booted system: what it can do is stage the
next one. That is exactly the kind of change the deployment model makes
reversible, and it is why this document does not call the rows a hole. It
does make the AGENTS.md line "not being asked for a password is not
permission" a real instruction rather than a nicety.

With `sudo`, all of `/etc` and `/var` is exposed too. That happens if you
give an agent a password, set up passwordless sudo, or leave a cached sudo
ticket in the terminal it runs in. `/usr` is still read-only, and a new
deployment is still just a staged deployment. But an `/etc` edit takes effect
immediately, and it outlives rollback (next section).

## What is NOT protected

Be exact about this when you make the pitch:

- **`$HOME`.** Deleted source, a rewritten `~/.ssh/config`, a force-pushed
  branch, a leaked token: none of it is an OS change, so none of it has a
  deployment to roll back to. Git, backups, and scoped credentials are the
  defence, the same as on any other machine.
- **`/etc` across rollback.** Each deployment has its own `/etc`, and updates
  carry local edits forward with a three-way merge. Rollback boots the old
  deployment's copy. That can bring back files you wanted changed, or keep an
  edit you did not want, depending on when the edit happened relative to the
  update. So rollback is not an `/etc` undo. See "Undoing an `/etc` change"
  below.
- **`/var`.** Everything under it is shared by every deployment: container
  storage, libvirt images, Flatpak installations, `/var/home`. None of it is
  versioned.
- **Flatpak data.** Apps can be reinstalled. Their data in `~/.var/app`
  cannot.
- **The network.** An agent can reach anything you can, with whatever
  credentials your `$HOME` holds.

## The toolbox is not a sandbox

Installing an agent into a toolbox keeps Node, Python and the agent itself
out of the image and off the host's package database, and `toolbox rm`
deletes all of it. It is **not** an isolation boundary. The box shares your `$HOME`, your session bus and your
UID, and `flatpak-spawn --host` runs anything on the host. Treat an agent in
the box as an agent on the host. Anything the box does to `$HOME` is done.

Real isolation is a separate user account, or a rootless container started
**without** `$HOME` mounted. Both cost convenience, and neither is built here.
See "Proposals" below.

## Undoing an `/etc` change

The OS half already has an undo. `/etc` does not have one yet, and it is the
one piece that matters most after an agent session. It holds sshd config,
sudoers, network and firewall config, and it survives rollback in ways that
are hard to reason about.

What works today:

- `sudo ostree admin config-diff` lists every `/etc` file that differs from
  what the image ships: `M` modified, `A` added, `D` deleted. Run it after a
  session to see what was touched.
- Before an agent edits a file there, copy it (`sudo cp -a <file>
  <file>.pre-agent`). AGENTS.md tells agents to do exactly that.
- A file you want back to the image's version can be copied from
  `/usr/etc/<path>`, which holds the image's pristine `/etc`.

A `pulsar checkpoint` command (snapshot `/etc` and pin the booted deployment
before a session, then diff or restore after) is built and waiting on a real
run before it ships. It will need root on purpose: an agent that can take and
restore its own checkpoints can also erase the evidence of what it did.

## How agents find out about this machine

The image ships one vendor-neutral briefing, `/usr/share/pulsar/AGENTS.md`.
It updates with the image, so it never describes an older system than the one
it ships in. It covers the read-only `/usr`, toolboxes for dev tools, Flatpaks
for apps, `pulsar doctor/status/manifest --json` and `pulsar report` for
facts, staging vs. rebooting, rollback and its limits, where the logs are, and
what not to touch.

Today they discover it one way, and it works for every agent:
**`pulsar agents-md`** prints it. Put "run `pulsar agents-md` first" in a
prompt, or in an agent's own global instructions file.

Coming next: a `pulsar setup agent <name>` recipe that installs an agent's
CLI into a toolbox and links the guide into the one global instructions path
that agent reads by itself, only if that path is free.

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

- **Require a password for layering.** A polkit rule in
  `/etc/polkit-1/rules.d/` returning `AUTH_ADMIN` for
  `org.projectatomic.rpmostree1.install-uninstall-packages` would make the
  "stage a deployment" row above say "nothing". The cost is one more prompt
  for a human who layers something, and it departs from Silverblue's default.
  It could be an opt-in recipe (`pulsar setup strict`) rather than image
  policy.
- **A sandboxed agent box.** A rootless podman container with only the
  project directory mounted, no `$HOME` and no session bus. That would give
  real isolation for `$HOME`, at the price of the agent losing your git
  config, SSH agent and logins. It is a bigger design than a maintenance-mode
  project should take on without a user asking for it.
- **Automatic checkpoints**, once `pulsar checkpoint` ships. For example,
  before each `pulsar update`. Probably not: a checkpoint is only useful if
  you know which one predates the thing you want to undo, and automatic ones
  pile up pins.
