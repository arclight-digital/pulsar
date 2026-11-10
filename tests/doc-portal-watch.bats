#!/usr/bin/env bats
# Tests for scripts/doc-portal-watch.sh.
#
# The bug these exist for: xdg-document-portal 1.22.1 deadlocked on cherenkov
# on 2026-10-04 and again 2026-10-21 (document_add_full re-entered through
# app_has_file_access's nested main loop), and before that lost its mount
# twice. Either way every Flatpak app handed a file hung until someone
# restarted the portal by hand.
#
# Pinned here: a healthy or not-yet-started portal is left alone; a missing
# mount and an unanswered GetMountPoint each restart it, by SIGKILL and then
# a start, never a plain stop (TERM is ignored while deadlocked); its stacks
# are saved before the kill; and the apps that were running are named, by
# their launchers' names, since they keep a dead view of the mount until
# reopened. Only the notification's button closes them, and only by asking
# each one through its own quit action: one that quits is started again, one
# that does not (a save prompt) or cannot be asked is left open and named.
# Nothing is ever killed.
#
# systemctl, systemd-run, gdbus, flatpak, gio, notify-send and eu-stack are
# stubs; timeout is the real one, so the hang test times out for real.
# systemd-run runs the transient unit's command in place, so the button's
# side is the real script too.

bats_require_minimum_version 1.5.0

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/doc-portal-watch.sh"
    REPO="${BATS_TEST_DIRNAME}/.."
    BIN="${BATS_TEST_TMPDIR}/bin"
    LOG="${BATS_TEST_TMPDIR}/calls"
    mkdir -p "$BIN"
    export XDG_RUNTIME_DIR="${BATS_TEST_TMPDIR}/run"
    export XDG_STATE_HOME="${BATS_TEST_TMPDIR}/state"
    export PULSAR_MOUNTINFO="${BATS_TEST_TMPDIR}/mountinfo"
    export PULSAR_DOC_PORTAL_TIMEOUT=1
    export ACTIVE=0 HANG=0 RESTART_RC=0 ANSWER="" PULSAR_DOC_PORTAL_POLL=0
    export PULSAR_DOC_PORTAL_QUIT_WAIT=2
    # The apps that own their ID on the bus, by what their quit action does:
    # QUITS quit, STAYS stay (a save prompt), SLOW stay and the call times
    # out (a modal prompt inside the action), NOQUIT have no quit action.
    # Anything else owns no bus name (Steam, Electron apps).
    export QUITS="" STAYS="" SLOW="" NOQUIT=""
    unset LC_ALL LC_MESSAGES
    export LANG=C
    # The running Flatpak apps, one per line; a quit or a kill takes one out.
    export APPS="${BATS_TEST_TMPDIR}/apps"
    : > "$APPS"
    # Steam, Discord, Loupe and Text Editor have launchers; NautilusPreviewer,
    # a helper, does not. Loupe's name is nothing like its ID's tail, and
    # translated; its action's names are not the app's.
    export PULSAR_FLATPAK_EXPORTS="${BATS_TEST_TMPDIR}/exports"
    mkdir -p "$PULSAR_FLATPAK_EXPORTS"
    printf '[Desktop Entry]\nName=Steam\nExec=steam\n' \
        > "$PULSAR_FLATPAK_EXPORTS/com.valvesoftware.Steam.desktop"
    printf '[Desktop Entry]\nName=Discord\nExec=discord\n' \
        > "$PULSAR_FLATPAK_EXPORTS/com.discordapp.Discord.desktop"
    printf '[Desktop Entry]\nName=Text Editor\nExec=gnome-text-editor\n' \
        > "$PULSAR_FLATPAK_EXPORTS/org.gnome.TextEditor.desktop"
    cat > "$PULSAR_FLATPAK_EXPORTS/org.gnome.Loupe.desktop" <<'EOF2'
[Desktop Entry]
# Name=Commented Out
Name[de]=Bildbetrachter
Name[pt_BR]=Visualizador de imagens
Name = Image Viewer
Name[pt]=Visualizador de imagem
Exec=loupe %U

[Desktop Action new-window]
Name=New Window
Name[fr]=Nouvelle fenêtre
EOF2
    # The portal's line, as /proc/self/mountinfo shows it.
    printf '36 25 0:50 / %s/doc rw,nosuid,nodev,relatime - fuse.portal portal rw,user_id=1000\n' \
        "$XDG_RUNTIME_DIR" > "$PULSAR_MOUNTINFO"

    cat > "${BIN}/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "${LOG}"
case "\$2" in
  is-active) exit "\${ACTIVE}" ;;
  show) echo 4242 ;;
  restart) exit "\${RESTART_RC}" ;;
esac
EOF
    cat > "${BIN}/gdbus" <<EOF
#!/usr/bin/env bash
echo "gdbus \$*" >> "${LOG}"
has() { case " \$1 " in *" \$2 "*) return 0 ;; esac; return 1; }
dest=""; prev=""
for a in "\$@"; do [ "\$prev" = --dest ] && dest=\$a; prev=\$a; done
case "\$*" in
  *GetMountPoint*)
    [ "\${HANG}" = 1 ] && exec sleep 30
    echo "(b'${XDG_RUNTIME_DIR}/doc',)" ;;
  *NameHasOwner*)
    if has "\$QUITS \$STAYS \$SLOW \$NOQUIT" "\${!#}"; then echo '(true,)'; else echo '(false,)'; fi ;;
  *ActivateAction*)
    if has "\$QUITS" "\$dest"; then
      # LINGER: it takes that long to quit after answering, as a real app does
      ( sleep "\${LINGER:-0}"; exec 9>"\${APPS}.lock"; flock 9; grep -vx "\$dest" "\${APPS}" > "\${APPS}.\$\$"; mv "\${APPS}.\$\$" "\${APPS}" ) >/dev/null 2>&1 &
      [ "\${LINGER:-0}" = 0 ] && wait
      echo '()'
    elif has "\$STAYS" "\$dest"; then echo '()'
    elif has "\$SLOW" "\$dest"; then echo 'Error: Timeout was reached' >&2; exit 1
    elif has "\$NOQUIT" "\$dest"; then
      echo "Error: GDBus.Error:org.freedesktop.DBus.Error.InvalidArgs: Unknown action 'quit'" >&2; exit 1
    else echo "Error: GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown: The name is not activatable" >&2; exit 1
    fi ;;
esac
EOF
    cat > "${BIN}/flatpak" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ps) cat "\${APPS}" ;;
  kill) echo "flatpak kill \$2" >> "${LOG}"
        [ "\${STUBBORN:-}" = 1 ] && exit 0
        grep -vx "\$2" "\${APPS}" > "\${APPS}.new"; mv "\${APPS}.new" "\${APPS}" ;;
esac
EOF
    cat > "${BIN}/notify-send" <<EOF
#!/usr/bin/env bash
printf 'notify-send %s\n' "\$*" >> "${LOG}"
# CLOSED: an app the user quits while the notification is up
if [ -n "\${CLOSED:-}" ]; then grep -vx "\${CLOSED}" "\${APPS}" > "\${APPS}.new"; mv "\${APPS}.new" "\${APPS}"; fi
[ -n "\${ANSWER}" ] && echo "\${ANSWER}"
exit 0
EOF
    cat > "${BIN}/systemd-run" <<EOF
#!/usr/bin/env bash
echo "systemd-run \$*" >> "${LOG}"
while [ "\$1" != -- ]; do shift; done
shift
exec "\$@"
EOF
    cat > "${BIN}/gio" <<EOF
#!/usr/bin/env bash
echo "gio \$*" >> "${LOG}"
EOF
    cat > "${BIN}/eu-stack" <<EOF
#!/usr/bin/env bash
echo "eu-stack \$*" >> "${LOG}"
echo "#2  document_add_full"
EOF
    chmod +x "${BIN}"/*
    PATH="${BIN}:${PATH}"
}

@test "a portal that answers is left alone" {
    run -0 "$SCRIPT"
    [ -z "$output" ]
    grep -q '^gdbus call --session --dest org.freedesktop.portal.Documents .*GetMountPoint$' "$LOG"
    ! grep -qE '^systemctl --user (kill|restart)' "$LOG"
}

@test "a portal that is not running is not probed or started" {
    ACTIVE=3 run -0 "$SCRIPT"
    ! grep -q '^gdbus' "$LOG" || false
    ! grep -qE '^systemctl --user (kill|restart)' "$LOG"
}

@test "a vanished mount restarts the portal without asking it anything" {
    : > "$PULSAR_MOUNTINFO"
    run -0 "$SCRIPT"
    [[ "$output" == *"its mount at ${XDG_RUNTIME_DIR}/doc is gone"* ]]
    ! grep -q '^gdbus' "$LOG" || false
    grep -Fxq 'systemctl --user restart xdg-document-portal.service' "$LOG"
}

@test "a portal that does not answer is killed, then started, and the wait is bounded" {
    SECONDS=0
    HANG=1 run -0 "$SCRIPT"
    [ "$SECONDS" -lt 10 ]
    [[ "$output" == *"did not answer GetMountPoint within 1s"* ]]
    grep -Fxq 'systemctl --user kill --signal=SIGKILL xdg-document-portal.service' "$LOG"
    [ "$(grep -n '^systemctl --user kill' "$LOG" | cut -d: -f1)" -lt \
      "$(grep -n '^systemctl --user restart' "$LOG" | cut -d: -f1)" ]
    # Never a stop: TERM is what the deadlocked portal ignores.
    ! grep -q '^systemctl --user stop' "$LOG"
}

@test "the hung portal's stacks are saved before it is killed" {
    HANG=1 run -0 "$SCRIPT"
    grep -Fxq 'eu-stack -p 4242' "$LOG"
    [ "$(grep -n '^eu-stack' "$LOG" | cut -d: -f1)" -lt "$(grep -n '^systemctl --user kill' "$LOG" | cut -d: -f1)" ]
    f=$(echo "${XDG_STATE_HOME}"/pulsar/doc-portal-hang-*.txt)
    grep -q document_add_full "$f"
    [[ "$output" == *"its stacks are in ${f}"* ]]
}

@test "the apps open across the restart are named once each, and offered a button" {
    printf '%s\n' com.valvesoftware.Steam com.discordapp.Discord com.discordapp.Discord > "$APPS"
    HANG=1 run -0 "$SCRIPT"
    # In a unit of its own, which does not take the apps it starts with it.
    grep -q '^systemd-run --user --collect --quiet -p KillMode=process --unit=pulsar-doc-portal-reopen-[0-9]* -- .*doc-portal-watch.sh --offer com.discordapp.Discord com.valvesoftware.Steam$' "$LOG"
    grep -Fxq "notify-send --app-name=Pulsar --icon=dialog-warning --action=reopen=Quit and Reopen Pulsar restarted file access for Flatpak apps Apps that were running before the restart can't open or save files until they're reopened: Discord, Steam. Quit and Reopen asks each one to quit, as its own Quit command does, and opens it again once it has. Apps that stay open are listed afterward for you to close yourself." "$LOG"
}

@test "apps are named by their launchers, in the user's language, else by their ID" {
    printf '%s\n' org.gnome.Loupe org.gnome.NautilusPreviewer com.valvesoftware.Steam > "$APPS"
    HANG=1 run -0 "$SCRIPT"
    grep -Fq "until they're reopened: Image Viewer, org.gnome.NautilusPreviewer, Steam. " "$LOG"
    # Name[de] for de_DE; the most specific match first; the language alone
    # when the country has none; LC_ALL over LANG; and never a name from an
    # action's group.
    : > "$LOG"; LANG=de_DE.UTF-8 run -0 "$SCRIPT" --offer org.gnome.Loupe
    grep -Fq "reopened: Bildbetrachter. " "$LOG"
    : > "$LOG"; LANG=pt_BR.UTF-8 run -0 "$SCRIPT" --offer org.gnome.Loupe
    grep -Fq "reopened: Visualizador de imagens. " "$LOG"
    : > "$LOG"; LANG=pt_PT.UTF-8 run -0 "$SCRIPT" --offer org.gnome.Loupe
    grep -Fq "reopened: Visualizador de imagem. " "$LOG"
    : > "$LOG"; LANG=de_DE.UTF-8 LC_ALL=pt_BR.UTF-8 run -0 "$SCRIPT" --offer org.gnome.Loupe
    grep -Fq "reopened: Visualizador de imagens. " "$LOG"
    : > "$LOG"; LANG=fr_FR.UTF-8 run -0 "$SCRIPT" --offer org.gnome.Loupe
    grep -Fq "reopened: Image Viewer. " "$LOG"
}

@test "without a click nothing is asked, closed or started" {
    printf '%s\n' org.gnome.Loupe com.discordapp.Discord > "$APPS"
    QUITS=org.gnome.Loupe HANG=1 run -0 "$SCRIPT"
    grep -q '^notify-send' "$LOG"
    ! grep -q '^flatpak kill' "$LOG" || false
    ! grep -q 'ActivateAction' "$LOG" || false
    ! grep -q '^gio' "$LOG"
}

@test "the button asks each app to quit and starts it again, each one gone before it starts" {
    printf '%s\n' org.gnome.Loupe org.gnome.TextEditor > "$APPS"
    SECONDS=0
    # A real poll interval: apps that have quit are not waited on further.
    # They quit a second after they are asked, and are started only after.
    LINGER=1 QUITS="org.gnome.Loupe org.gnome.TextEditor" PULSAR_DOC_PORTAL_POLL=1 ANSWER=reopen HANG=1 run -0 "$SCRIPT"
    [ "$SECONDS" -lt 8 ]
    # Through the app's own quit action at its GApplication path, never a kill.
    grep -Fxq "gdbus call --session --timeout 5 --dest org.gnome.Loupe --object-path /org/gnome/Loupe --method org.freedesktop.Application.ActivateAction quit [] {}" "$LOG"
    grep -Fxq "gdbus call --session --timeout 5 --dest org.gnome.TextEditor --object-path /org/gnome/TextEditor --method org.freedesktop.Application.ActivateAction quit [] {}" "$LOG"
    ! grep -q '^flatpak kill' "$LOG" || false
    grep -Fxq "gio launch ${PULSAR_FLATPAK_EXPORTS}/org.gnome.Loupe.desktop" "$LOG"
    grep -Fxq "gio launch ${PULSAR_FLATPAK_EXPORTS}/org.gnome.TextEditor.desktop" "$LOG"
    [ "$(grep -n 'dest org.gnome.Loupe .*ActivateAction' "$LOG" | cut -d: -f1)" -lt \
      "$(grep -n '^gio launch .*Loupe' "$LOG" | cut -d: -f1)" ]
    # All of them reopened: no notification about any left open.
    [ "$(grep -c '^notify-send' "$LOG")" -eq 1 ]
}

@test "an app that does not quit, or cannot be asked, is left open and named" {
    printf '%s\n' org.gnome.Loupe org.gnome.TextEditor com.valvesoftware.Steam com.discordapp.Discord org.gnome.NautilusPreviewer > "$APPS"
    SECONDS=0
    QUITS=org.gnome.Loupe STAYS=org.gnome.TextEditor SLOW=com.discordapp.Discord NOQUIT=org.gnome.NautilusPreviewer \
        ANSWER=reopen HANG=1 run -0 "$SCRIPT"
    # The wait for the one with a save prompt up is bounded.
    [ "$SECONDS" -lt 8 ]
    ! grep -q '^flatpak kill' "$LOG" || false
    # Steam owns no bus name: it is not called at all, so not activated.
    ! grep -q 'dest com.valvesoftware.Steam' "$LOG" || false
    grep -Fxq "gio launch ${PULSAR_FLATPAK_EXPORTS}/org.gnome.Loupe.desktop" "$LOG"
    [ "$(grep -c '^gio launch' "$LOG")" -eq 1 ]
    [[ "$output" == *"asked org.gnome.TextEditor to quit"* ]]
    [[ "$output" == *"asked com.discordapp.Discord to quit"* ]]
    [[ "$output" == *"org.gnome.TextEditor is still open; leaving it to the user"* ]]
    [[ "$output" == *"com.valvesoftware.Steam has no quit action to call; leaving it open"* ]]
    [[ "$output" == *"org.gnome.NautilusPreviewer has no quit action to call; leaving it open"* ]]
    # The rest are named, by their launchers' names, alphabetically.
    grep -Fxq "notify-send --app-name=Pulsar --icon=dialog-warning Close and reopen these apps yourself Still open: Discord, org.gnome.NautilusPreviewer, Steam, Text Editor. They didn't quit when asked, or have no Quit command Pulsar can call, and can't open or save files until you close and reopen them." "$LOG"
    # and every one of them is still running
    [ "$(sort "$APPS" | paste -sd' ')" = "com.discordapp.Discord com.valvesoftware.Steam org.gnome.NautilusPreviewer org.gnome.TextEditor" ]
}

@test "an app closed before the click is not started again" {
    printf '%s\n' com.valvesoftware.Steam com.discordapp.Discord > "$APPS"
    QUITS="com.valvesoftware.Steam com.discordapp.Discord" CLOSED=com.discordapp.Discord ANSWER=reopen HANG=1 run -0 "$SCRIPT"
    [[ "$output" == *"com.discordapp.Discord is closed already; not starting it"* ]]
    # the one still open is reopened, the closed one is left alone
    grep -q 'dest com.valvesoftware.Steam .*ActivateAction' "$LOG"
    grep -Fxq "gio launch ${PULSAR_FLATPAK_EXPORTS}/com.valvesoftware.Steam.desktop" "$LOG"
    [ "$(grep -c 'ActivateAction' "$LOG")" -eq 1 ]
    [ "$(grep -c '^gio launch' "$LOG")" -eq 1 ]
}

@test "a helper with no launcher is asked to quit and not started" {
    printf '%s\n' org.gnome.NautilusPreviewer > "$APPS"
    QUITS=org.gnome.NautilusPreviewer ANSWER=reopen HANG=1 run -0 "$SCRIPT"
    grep -q 'dest org.gnome.NautilusPreviewer .*ActivateAction quit' "$LOG"
    [[ "$output" == *"org.gnome.NautilusPreviewer quit and has no launcher; not starting it"* ]]
    ! grep -q '^flatpak kill' "$LOG" || false
    ! grep -q '^gio' "$LOG"
}

@test "an app that will not close is not started again into its old sandbox" {
    printf '%s\n' com.valvesoftware.Steam > "$APPS"
    STAYS=com.valvesoftware.Steam ANSWER=reopen HANG=1 run -0 "$SCRIPT"
    grep -q 'dest com.valvesoftware.Steam .*ActivateAction quit' "$LOG"
    [[ "$output" == *"com.valvesoftware.Steam is still open; leaving it to the user"* ]]
    ! grep -q '^gio' "$LOG"
}

@test "with no app running there is nothing to reopen and no notification" {
    HANG=1 run -0 "$SCRIPT"
    ! grep -q '^systemd-run' "$LOG" || false
    ! grep -q '^notify-send' "$LOG"
}

@test "a portal that does not come back fails the unit and says so" {
    HANG=1 RESTART_RC=1 run -1 "$SCRIPT"
    [[ "$output" == *"the portal did not come back"* ]]
}

@test "the watcher is copied, enabled --global and in the user preset, in lockstep" {
    cf="${REPO}/Containerfile"
    preset="${REPO}/system_files/usr/lib/systemd/user-preset/50-pulsar.preset"
    grep -qx 'enable pulsar-doc-portal-watch.timer' "$preset"
    grep -q 'systemctl --global enable pulsar-doc-portal-watch.timer' "$cf"
    grep -qx 'COPY scripts/doc-portal-watch.sh /usr/libexec/pulsar/doc-portal-watch.sh' "$cf"
    grep -qx '      /usr/libexec/pulsar/doc-portal-watch.sh \\' "$cf"
    awk '/^    for u in podman-auto-update.timer/,/; do/' "$cf" | grep -q 'pulsar-doc-portal-watch.timer'
    grep -qx 'ExecStart=/usr/libexec/pulsar/doc-portal-watch.sh' \
        "${REPO}/system_files/usr/lib/systemd/user/pulsar-doc-portal-watch.service"
}
