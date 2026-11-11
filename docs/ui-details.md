# Interface details

Facts cut from on-screen text, by the setting or screen they came from. The
interface keeps the one fact a user needs at each spot; the rest is here.

## Pulsar Settings: Appearance

### Effects (group)

- Glass windows and Glow change in apps you open after the change. Apps
  already open keep what they had.
- High contrast turns every effect off, except in app windows already open.
- The two Disable glass switches leave app windows' glass on.

### Glass

- Glass covers the top bar, the dash, menus, dialogs, notifications and
  on-screen displays.

### Glass windows

- Applies to GTK 4 and GTK 3 app windows, sidebars included.
- App windows are 80% opaque over the blur.
- Bars drawn apart from the window, such as Image Viewer's title bar and tab
  bars, stay solid.
- Fullscreen windows stay solid.

### Lighting

- A menu's lit edge turns warmer when the battery is low.

### Power-on

- The lit edge traces out from the button that opened the menu.

### Glow

- What glows: switches that are on, checked boxes, slider fills, progress bars
  and default buttons.

### Focus brackets

- There are four brackets, one at each corner.
- They mark the focused button or menu item.

### Disable glass when gaming

- "A game runs with GameMode" means a game started with `gg`, `ggm` or
  `gamemoderun`.

## Pulsar Settings: Updates

### Automatic downloads

- Nothing restarts by itself. A downloaded update starts at the next restart.

## Pulsar Settings: Agents

### Sessions (group)

- Each session runs one coding agent in a terminal session that keeps going
  when its window closes.
- You get a notification when an agent rings the terminal bell. Claude Code
  rings it when it waits for you.

### Undo the agent's changes

- Undo is available only after the session ends, so the agent can't write
  files during the undo.

## Pulsar Commands

### Read a QR code

- Pick an area with a QR code in it.

### Make a checkpoint

- Make one before a risky change.

### Nothing matches (empty state)

- Pulsar actions are the items such as Copy text from the screen, Themes and
  Health check.

### Pulsar Commands (app grid entry)

- Pulsar actions include copying text from the screen.

## Themes notifications

### Pulsar themes are available

- `pulsar theme list` lists the themes from a terminal.

### Pulsar theme applied

- Themes switches the whole desktop's colors.

## File access notifications

### Pulsar restarted file access for Flatpak apps

- The apps listed were running before the restart.
- Quit and Reopen asks each app to quit, as its own Quit command does, and
  opens it again once it has.
- Apps that stay open are listed afterward for you to close yourself.

### Close and reopen these apps yourself

- These apps didn't quit when asked, or have no Quit command Pulsar can call.

## NVIDIA notifications

### Restart Steam to use the NVIDIA GPU

- The app started without the NVIDIA driver. `pulsar doctor flatpak-gl`
  names the driver version.

## Crash notifications

### Ask (agent)

- The report the agent reads has the crash's stack trace and the program's
  log lines.
