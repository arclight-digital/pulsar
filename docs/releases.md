# Releases

- **Releases** (`YY.M.N`, written up here) are changes to what Pulsar adds
  on top of Silverblue: the year, the month, and that month's release
  number, so `26.9.1` is September 2026's first. The About page, the boot
  menu, `pulsar manifest` and `pulsar doctor` all show it.
- **Nightly builds** (`44.20260929.0`) carry each day's Fedora and Silverblue
  updates, listed in the [nightly changelog](/docs/changelog), generated from
  the images.

Releases ship inside a nightly; both arrive through the same update. The two
move independently: a month with no new Pulsar features keeps its release
while the builds go on, so the About page may read
`Pulsar 26.9.1 (44.20261103.0)` in November.

## 26.11.2

Coding-agent sessions get their own app. Antigravity CLI replaces Gemini
CLI, and opencode moves to version 2.

### The Agents app

- Agents, in the app grid and Pulsar Commands, shows every agent session
  under its project, with the ones that need you first. Each session is the
  agent's own terminal, inside the window. Closing the window leaves them
  working.
- With no session open, the window asks what the agent should do, in which
  project. That text becomes the agent's first message, and the session's
  name unless you type one in Name. The agent, a worktree of its own and
  the sandbox sit beside it, remembered per project. Renaming a session
  gives it a new icon.
- Opening a stopped session continues it, on the same conversation for
  Claude Code and opencode, and for Antigravity CLI once Pulsar has seen
  its conversation. Codex CLI picks up its latest conversation in that
  folder, which is the same one for a session in its own worktree.
- Changes lists the files the agent changed, since the session started or
  since the last commit, with each file's diff and Revert File. A comment
  on a diff line is typed into the agent's prompt as `path:line: …` for
  you to send.
- In the app a session is only its agent: tmux's keys, menus and status
  line aren't there, and when the agent quits you get Continue, not a
  shell. The mouse wheel scrolls back through the session, or through
  Claude Code's own transcript in its fullscreen mode, and typing goes
  back to the prompt. A terminal attached to the same session keeps tmux
  as it was. While the app shows a session, its window takes the smaller
  of the app's and a terminal's sizes, so the two stop resizing it in
  turn. A session the app has open but isn't showing doesn't count,
  on this machine or on another one.
- Sessions stay where they are in the list: newest started on top in each
  project, and the project with the newest session first. Drag a session
  within its group, or a group by its heading, to put them in your own
  order (or right-click for Move Up and Move Down, or Alt+Up and Alt+Down
  in the list, with Shift for the whole group); new ones still come in at
  the top. One whose turn it is pulses. Right-clicking a terminal gives Copy and Paste, and Select
  All in a shell.
- Ctrl+\` (or the terminal button in the header) opens a shell under the
  agent, in the session's folder (its worktree, when it has one), with a
  divider to drag. Ctrl+Shift+\` or + opens another in a new tab; each tab
  is named for the folder its shell is in. Each session keeps the panel
  shown or hidden as you left it there. Hiding it leaves the shells running, and when one finishes a command or rings its bell while
  you can't see it, its tab and the terminal button get a dot. `exit`
  closes a tab. A session on another machine gets its shells on that
  machine (`pulsar machine shell`). A sandboxed session's shells run on
  your machine, outside the sandbox.
- Each session in the list has a bar for how full its context is. A
  status bar under the open session shows the agent and model, what it is
  doing, the context used against the window, Codex CLI's 5-hour and
  weekly limits, whether it is sandboxed, its branch, and how many files
  it changed (click for Changes). It also shows the account the agent is
  signed in with on the session's machine, what it may do without asking
  (Claude Code's permission mode, Codex CLI's approvals and sandbox, in
  the warning color when it never asks), the ports that servers in the
  session's folder listen on (click one to open it in the browser), and
  the session's scratch folder once it holds 100 MB, in a warning color
  when the disk gets tight. Each of these shows whole or not at all: on a
  narrow window the least needed make room first (the scratch folder,
  unless the disk is low, then the branch, the mode, the account, the
  ports).
  The numbers come from each agent's own files. Claude Code and
  Antigravity CLI don't write their plan limits to disk, so those two
  show context only.
- Ctrl+Shift+B (or the button over the list) narrows the session list to
  the agents' tiles, which still show who is working and who needs you.
- The list's footer shows how much room is left on `/var`, amber when it's
  getting tight and red when it's nearly full. Click it for the big things
  in `/var/tmp`, `~/.cache` and the sessions' scratch folders, each with
  Delete. `pulsar agent disk` lists the same, and
  `pulsar doctor suspend-room` says whether a suspend will fit.
- Antigravity CLI and Codex CLI sessions now say when they finish a turn,
  as Claude Code's do: the session shows as waiting in the app until you
  send it something, and a notification comes when you aren't looking at
  it. Pulsar adds a `pulsar` entry to agy's `~/.gemini/config/hooks.json`
  (a Stop hook for the end of a turn, and a PreInvocation hook that says
  when the next one starts, so typing a draft or opening `/context`
  leaves it waiting), and gives Codex a `notify` program on its command
  line unless you have one of your own. opencode doesn't yet. A Claude
  Code or Codex CLI session whose screen hasn't changed for 20 seconds is
  waiting too, even without that signal: both show a ticking counter
  while they work, and Claude Code runs no hook when you cancel a turn.
- Each session started with `--tmux` gets a scratch folder,
  `$PULSAR_SCRATCH`, for VM disks, builds and downloads, mounted into the
  sandbox too. It's deleted with the session.
- History lists the snapshot taken at each start, and Go Back puts the
  files back, stopping the agent first if it's working. The Undo button
  that appears after takes it back.
- Archive (the × on a session, or Ctrl+Shift+Delete) hides a session, with
  Undo. Archived sessions are deleted after 7 days with their undo
  snapshots. A worktree with uncommitted changes is never deleted, and
  branches stay. `pulsar agent sessions --archive`, `--unarchive` and
  `--tidy` do the same from a terminal.
- A notification's Open, Pulsar Commands and Pulsar Settings' Agents page
  all open the session in the app. Open finds the app when it's running,
  wherever it was started from. The notification also has Open in
  Terminal, for a terminal on the session instead. Without the app, Open
  opens a terminal.
- Sessions can see each other. `pulsar agent read <name>` shows a
  session's screen, and `pulsar agent send <name> <text>` types a message
  into its prompt, labelled as from another session (`<name>@<machine>`
  for a session on another of your machines). It goes in only at the end
  of that agent's turn, never into a permission question, and while you
  watch the session only with `--now`. Messages are logged in
  `~/.local/state/pulsar/agents/messages.log`, and one session can send
  another at most 10 in 10 minutes. Claude Code, Codex CLI and Antigravity
  CLI sessions take messages; sandboxed sessions don't yet.
- Help (F1, or the main menu) has the practices that keep agents out of
  each other's way, each tied to the feature that does it, and the keyboard
  shortcuts.
- Preferences (Ctrl+, or the main menu) sets the agent, sandbox and pushes
  new sessions start with, whether sessions can message each other and how
  many, and how long archived sessions are kept (a day, a week, 30 days or
  for good). The first four are the CLI's own settings: `pulsar agent
  settings` shows them.
- Each message has an id. `pulsar agent inbox` lists a session's messages
  both ways, `send --reply-to <id>` answers one, and the Messages tab
  beside Changes and History shows the open session's. A Claude Code
  session gets its mail through its own hooks, at the end of a turn or as
  it arrives while the session sits idle, so nothing is typed into it.
  Antigravity CLI gets it the same way at the end of a turn. Codex CLI, and
  an idle Antigravity CLI, get it typed into their prompt.
- `pulsar job run -- <command>` runs a long command in a tmux of its own,
  keeps its output (`pulsar job log`), and notifies you when it ends.
  `--notify <session>` also tells that agent session how it ended.
- `pulsar mcp` gives agents the same: `sessions`, `session_read`,
  `session_message` (with `reply_to`), `inbox`, `job_start`, `jobs`,
  `job_log` and `job_stop`, and for your other machines `machines`,
  `machine_job`, `machine_run` and `machine_fetch`: ask Claude on the laptop
  to train it on the desktop, and it sends the work there, starts the job,
  and hears how it ended. The
  ones that change something are marked as writes, so the agent asks you
  first. A sandboxed agent doesn't have `pulsar mcp`.
- Your other Pulsar machines, over SSH: `pulsar machine add <name> <ssh
  target>`, then their sessions show in the app as `name@machine`, and open
  there as here. Each machine keeps one SSH connection open until it
  breaks, you remove the machine or you log out. The app connects only
  while its window is in front and the screen is unlocked, so an SSH agent
  like 1Password asks for the key once per connection. If you cancel that
  or don't answer, the app stops asking until you click Try Again. A key
  that needs a passphrase typed fails.
- Announce This Machine, in Agents > Preferences > Your Machines (or
  `pulsar machine announce on`), publishes the machine on the local network
  over mDNS with your user name and release. It's off until you turn it on.
  The same page, and `pulsar machine discover`, list the Pulsar machines
  that announce, each with Add. If your SSH key isn't on one yet, Add says
  the `ssh-copy-id` line to run.
- Work can move to another machine. `pulsar machine run <machine> <agent>
  --prompt <text>` sends your branch there, with what isn't committed as one
  commit on top, to the same project under your home there, and starts the
  agent on it in a worktree. `pulsar machine job <machine> --notify <session>
  -- <command>` runs a command there the same way, and the session here hears
  how it ended. `pulsar machine fetch <machine> <session>` brings that
  session's branch back as `<machine>/<session>`, its uncommitted work on
  top. Your checkout is never touched, on either side. Code goes by git;
  data files don't move.
- `pulsar agent diff <name>` shows what a session changed since it started.
  `pulsar agent run --prompt <text>` starts the agent with a first message.

### Agents

- Antigravity CLI (`agy`) replaces Gemini CLI in `pulsar agent add` and the
  welcome. `gemini` and `aider` still run and can be removed if you have
  them, but are no longer offered.
- opencode is version 2 (`@opencode/cli`).
- Agents in the agents toolbox (Codex, opencode, agy) can message other
  sessions and read their inbox through `pulsar mcp`. Its server runs on
  the host and couldn't tell which session they were in, so it refused.

### Also

- git keeps HTTPS passwords in the keyring (`git-credential-libsecret` is
  in the image) instead of in plain text in `~/.git-credentials`.
- A speaker on the network (AirPlay and other network audio) plays only
  when you pick it; PipeWire no longer makes one the default by itself.
- Sublime Text's menu bar gets the glass blur, and GTK 3 windows take glass
  like GTK 4 ones.
- With glass on, icons dragged onto the dash reach it again, so you can
  reorder favorites and add one from the app grid, and Alt+Tab selects the
  app under the pointer. The glass's light lay over both and took the drag
  and the hover.
- On the NVIDIA image, DirectX 11 games in Steam and Faugus no longer hang
  the GPU on DXVK's descriptor heap (Boltgun every run, Sins of a Solar
  Empire II on its first frame in a game): Pulsar sets
  `DXVK_CONFIG=dxvk.enableDescriptorHeap = False`. A launch option that sets
  `DXVK_CONFIG` replaces it, so add that setting to yours.
- The NVIDIA driver is 620.70.06.

## 26.11.1

Coding agents can run in sessions that outlive their terminal, and
Super+Space opens Pulsar Commands. The desktop is GNOME 51.

### Agents

- `pulsar agent run <agent> --tmux <name>` keeps a coding agent in a named
  session that outlives its terminal window. `pulsar agent attach <name>`
  goes back to it from any terminal, and `pulsar agent attach` alone goes
  to the one you used last. When a Claude Code session restarts, Pulsar
  starts it with `--resume` and that session's conversation ID, and a
  sandboxed session stays sandboxed. Sessions run on their own tmux
  server, apart from yours. tmux is now in the image.
- When an agent in a session you aren't looking at rings the terminal bell,
  a notification says so (for Claude Code, whether it finished or needs
  you), and its Open button takes you to that session.
- `--worktree` gives a session its own git worktree and branch, so several
  agents can work in one project without touching each other's files. It
  works in the sandbox too.
- `pulsar agent undo <name>` puts a project's files back as they were when
  the session started (in a git repository), however often it was restarted
  since, and `--redo` takes that back. Commits made since, and the branch,
  stay where they are. Files git ignores, and any file `--redo` couldn't
  put back, are left as they are, and the undo lists them. Untracked files
  over 50 MB aren't saved.
- `pulsar agent sessions` lists the sessions and what each is doing, and
  `pulsar agent usage <name>` shows a Claude Code session's tokens.
- Pulsar Settings has an Agents page listing each session with its folder
  and usage, and Open, Undo and End buttons.

### Pulsar Commands

- Super+Space opens Pulsar Commands. Type to find one of Pulsar's actions:
  copy text or read a QR code on the screen, switch themes, check for
  updates, open agent sessions, run the health check, make a checkpoint
  before a risky change, or ask your agent. With one keyboard layout,
  Super+Space has no layout to switch to, so Pulsar Commands takes it;
  Shift+Super+Space still switches if you add a second. With several
  layouts, Pulsar Commands is on Super+/.
- Type a sum (`2^10`, `15% of 80`), a conversion (`5 mi in km`,
  `100 f in c`, `2 GiB in MB`, `255 in hex`), money (`100 usd in eur`) or a
  date (`in 90 days`, `days until dec 25`), and Enter copies the answer.
  Exchange rates are the European Central Bank's, fetched from
  frankfurter.dev only when you type a conversion, and kept for 12 hours.
- Type part of an app's name and Enter opens it. Files come from GNOME's
  file index (LocalSearch), by name: Enter opens one, Ctrl+Enter shows it
  in its folder. A long name scrolls into view when its row is selected.
- It has a few easter eggs.

### Screen

- Super+Print copies the text in an area of the screen you select (English
  only). `pulsar screen qr` reads a QR code the same way, and a link in it
  can be opened from the notification.
- Super+Print and the Pulsar Commands shortcut are each set once. If your
  account already uses the key, it's left alone, and you can change either
  in Settings > Keyboard.

### Gaming

- When a program hits a GPU fault on NVIDIA, a notification names the
  program and the fault, once per program each boot. For a game's Xid 13
  or 109 it also suggests turning off DLSS in the game.
  `pulsar doctor gpu-faults` lists this boot's faults.
- Faugus games run the image's `gamescale`, as Steam games do. A game with
  `gamescale` in its launch arguments no longer hangs on its splash.
- Steam's window comes back when it stops redrawing after a resume on
  NVIDIA. The fix shipped in 26.10.1 never fired; now it does, and Steam in
  the background no longer counts as stuck.
- An update to the NVIDIA driver that Flatpak apps use is no longer
  installed under a running Steam or Discord. If an app is using the
  driver, the update is downloaded and waits for the next boot.
- Super+F makes any window fullscreen, and pressing it again puts it back.
  A Windows game whose windowed fullscreen sits under the top bar fills the
  screen with one press (tested with World of Warcraft).
- Discord shows the game you're playing. The Discord Flatpak's sandbox
  hides other programs from it, so Pulsar finds the game (a Steam game by
  its Steam ID, any other by its program) and tells Discord. Your Activity
  Privacy settings in Discord still decide who sees it. Windows games run
  with GE-Proton that set their own Discord status now reach it from
  Faugus, as they already did from Steam.

### Desktop

- GNOME 51, on Fedora 45.
- Menus, Quick Settings, notifications, the on-screen displays and the top
  bar have new glass: what's behind them is blurred and redrawn in the
  theme's colors, so a menu keeps its theme over any page or wallpaper,
  and a colored window behind it tints it a little. The button that opened
  a menu lights the glass nearest it.
- With Glass windows on, every app window, GTK 4 or GTK 3, is the theme's
  background color at 80% opacity, like the terminal, sidebar and page
  alike. A title bar is part of the window, except where an app draws a bar
  apart from it, such as Image Viewer's title bar and tab bars: those are
  solid. Fullscreen windows are solid. Apps that draw their own window, such
  as Firefox, are unchanged.
- Dialogs that open in their own window are 80% opaque too, in the color
  the theme uses for menus inside apps. Dialogs inside a window
  (preferences, an alert) and toasts get the top bar menus' glass on
  GTK 4.22 and later, and are solid on older GTK.
- The lock screen is glass in the theme's colors over your wallpaper,
  toned so the clock, notifications and login text stay readable on any
  wallpaper.
- The Glass tint slider now sets how much of the color behind the glass
  comes through. All the way up, the glass is the theme's color alone.
- If the glass extension fails to load (after a GNOME update, say), apps
  open with solid windows instead of see-through ones with no glass behind.
- A window's glass no longer sits off to one side after you unmaximize it.
- The clock shows one highlight while the date menu is open, not two.
- The calendar's weekday names (2.9:1 before) now have at least 4.5:1
  contrast over the glass, and "No Notifications" at least 3:1.
- Pulsar uses the kernel's standard scheduler, EEVDF, by default again. On
  the hybrid Intel CPU it was measured on (a 275HX, 8 performance and 16
  efficiency cores), the sched_ext scheduler Pulsar shipped ran GNOME Shell
  on efficiency cores 66-78% of the time, and animations jumped to their
  end. `scx.service` is still there to turn on.
- Pulsar checks the document portal once a minute and restarts it when it
  stops answering, which hangs any Flatpak app opening a file. Flatpak apps
  already running can't open files again until they're reopened, so a
  notification offers to reopen them.
- AppImages that need FUSE 2 no longer stop at "AppImages require FUSE to
  run". Fedora ships only FUSE 3, so the image now adds FUSE 2.
- Welcome to Pulsar opens on a new account's first login again; on Fedora
  45 it never did. After an update to a new release, a notification opens
  What's New for it.

### Installer

- Before it erases a disk, the installer shows a warning, the disk and what
  is on it in red, and a red Erase and Install button.
- The disk step shows what it is doing. The install log is at
  `~/pulsar-install.log` while the installer runs, named on the failure
  page, and a finished install keeps it at `/var/log/pulsar-install.log`.
- The ISO's boot menu says "Install Pulsar", not "Install Pulsar 44", and
  no longer offers a rescue entry the installer can't use.

## 26.10.1

Pulsar's own installer, Pulsar Settings, and glass everywhere.

### Installer

- The ISO starts straight into Pulsar's own installer, which replaces
  Anaconda.
- Every disk is listed with its size, what is on it and its device name,
  so two drives of the same model can't be mistaken for each other. The
  USB stick the installer runs from is never offered, and no other disk is
  touched.
- Install beside Windows in 36 GB of free space, or erase the disk. Before
  an erase, the installer lists every partition that will be deleted and
  asks you to confirm. Nothing is written until you press Erase and Install
  on the last page.
- Beside Windows, Windows' partitions and boot files are left as they are,
  and Windows is added to the startup menu. A disk with BitLocker on is
  refused until it is turned off in Windows.
- Disk encryption is on by default, and you can turn it off. The
  passphrase prompt at startup uses the keyboard layout the passphrase
  was typed in.
- A failed install removes the partitions it made and says what state the
  disk is in. The window can't be closed while the install is writing to
  the disk.

### Pulsar Settings

- A new app for what GNOME Settings has no room for. Appearance has the
  theme and every glass and lighting switch. Updates shows the release and
  image, checks for an update, downloads it and restarts into it, rolls
  back to the previous image, and keeps the current one from being cleaned
  up.
- The gear in Themes opens it, and so does the last page of the welcome.

### Glass and light

- Menus, OSDs, notification banners, dialogs and the dash are clearer:
  what is behind them keeps its shapes, softly blurred.
- The overview stands on the blurred wallpaper. Its search box and the
  dash's labels are lit glass.
- In apps, menus, popovers, floating dialogs and Files' file area are
  glass too.
- Alt+Tab's thumbnails, window previews in the overview and "not
  responding" dialogs get glass.
- File choosers and other windows that Flatpak apps open through the
  system are blurred like every other window. Before, they were
  see-through with the app behind them sharp.
- In the notification list under the clock, a collapsed group shows the
  notifications behind the newest as slivers, each a step darker, as stock
  GNOME does. Before, they showed through the one in front, text and all.
- Floating glass casts a soft shadow in the theme's own deep color.
- Glass turns off in Power Saver (a switch, on by default) and, if you
  want, while a game is running. A fullscreen game stops every blur
  beneath it and over it, and fullscreen apps are solid.

### Themes

- Four new themes: Eclipse, a pearl corona with a rose rim; Regolith,
  lunar dust and an amber gauge; Magnetosphere, green aurora over polar
  night; and Redshift, receding light in a plum dusk. Eclipse and
  Magnetosphere are dark only.
- A theme's blue or purple accent reaches GNOME as blue or purple, not
  gray.
- A theme with only one mode keeps it when Dark Style is flipped.

### Gaming

- Flatpak Steam runs `gg`, `ggm` and `gamescale` from the image, with no
  setup. If you set them up on an older image, quit Steam and run
  `pulsar setup gamescale` once to move to the image's copies. While Steam
  is open it keeps the old copies, so launches keep working until Steam
  restarts.
- On NVIDIA, the Steam client's window draws at the display's refresh
  rate instead of pausing for up to a tenth of a second. Games keep their
  own vsync setting.
- When Steam's window stops redrawing after a resume on NVIDIA, Pulsar
  restarts the stuck process.

### Crashes

- A crash notification has an "Ignore this" button, and
  `pulsar crashes ignore` lists and edits what is ignored. A Proton game
  that crashes as it quits no longer interrupts you.

### Under the hood

- Image signatures are logged in Rekor. `pulsar verify` checks the running
  image's signature and its log entry.
- The sched_ext scheduler loads on machines installed by Pulsar's
  installer, which never had the kernel config file it needed.
- AGENTS.md, the briefing coding agents read, is rewritten: shorter, and
  checked against the system.
- A rare misread is fixed: the first boot's install of the default apps
  could report an installed app as missing and keep retrying, and
  `pulsar checkpoint restore` could miss an update staged since the
  checkpoint and leave it to boot next.

## 26.9.1

The first numbered release: Pulsar's own look, and glass.

### Themes

- 20 themes, each recoloring the whole desktop in one step: GNOME Shell, GTK
  4 and GTK 3 apps, the terminal, Text Editor, btop, coding agents and the
  wallpaper. Two-mode themes follow Dark Style on their own.
- The theme picker (Super+T) shows every theme as a card in its own colors;
  `pulsar theme set <name>` does the same from a terminal, and
  `pulsar theme revert` puts stock GNOME back.
- Flatpak apps are themed by default, and GTK 3 apps follow Dark Style.
- btop gets the theme's own colors in light themes too, instead of labels
  drawn in pale gray.

### Glass and light

- Menus, the top bar, OSDs, notification banners and app windows go
  translucent over a live blur of whatever is really beneath them, redrawn
  every frame, so it keeps up with a window dragged across it.
- Light: the button that opened a menu glows, the menu's rim is lit from it,
  and the edge warms when the battery runs low.
- App windows get a little glass too, with their cards kept solid and lifted
  so they stay readable.
- Every effect is its own switch, in the picker's Effects panel and the
  Pulsar Theme page of the Extensions app, with a tint slider and a Reset.
  High contrast turns them all off.

### Under the hood

- The sched_ext scheduler (scx_bpfland) runs again on Fedora's 7.2 kernels.
  Two things had kept it off: a build check that misread the kernel, and a
  missing link to the kernel config that every BPF scheduler needs.
  `pulsar doctor` now names that second cause if it ever comes back.
- `pulsar manifest` and `pulsar doctor` show the release beside the nightly
  build.
