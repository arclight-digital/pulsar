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
# are saved before the kill; and the apps that were running are named, since
# they keep a dead view of the mount until reopened. They are closed and
# started again only when the notification's button is clicked, never by
# the watcher itself.
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
    # The running Flatpak apps, one per line; flatpak kill takes its app out.
    export APPS="${BATS_TEST_TMPDIR}/apps"
    : > "$APPS"
    # Steam and Discord have launchers; NautilusPreviewer, a helper, does not.
    export PULSAR_FLATPAK_EXPORTS="${BATS_TEST_TMPDIR}/exports"
    mkdir -p "$PULSAR_FLATPAK_EXPORTS"
    touch "$PULSAR_FLATPAK_EXPORTS/com.valvesoftware.Steam.desktop" \
          "$PULSAR_FLATPAK_EXPORTS/com.discordapp.Discord.desktop"
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
[ "\${HANG}" = 1 ] && exec sleep 30
echo "(b'${XDG_RUNTIME_DIR}/doc',)"
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
    grep -Fxq "notify-send --app-name=Pulsar --icon=dialog-warning --action=reopen=Reopen them Opening files was stuck, and is fixed now Discord, Steam can't open or save files until they're reopened." "$LOG"
}

@test "without a click nothing is closed or started" {
    printf '%s\n' com.valvesoftware.Steam com.discordapp.Discord > "$APPS"
    HANG=1 run -0 "$SCRIPT"
    grep -q '^notify-send' "$LOG"
    ! grep -q '^flatpak kill' "$LOG" || false
    ! grep -q '^gio' "$LOG"
}

@test "the button closes each app and starts it again, each one gone before it starts" {
    printf '%s\n' com.valvesoftware.Steam com.discordapp.Discord > "$APPS"
    SECONDS=0
    # A real poll interval: an app that has closed is not waited on further.
    PULSAR_DOC_PORTAL_POLL=1 ANSWER=reopen HANG=1 run -0 "$SCRIPT"
    [ "$SECONDS" -lt 8 ]
    grep -Fxq 'flatpak kill com.valvesoftware.Steam' "$LOG"
    grep -Fxq "gio launch ${PULSAR_FLATPAK_EXPORTS}/com.valvesoftware.Steam.desktop" "$LOG"
    grep -Fxq "gio launch ${PULSAR_FLATPAK_EXPORTS}/com.discordapp.Discord.desktop" "$LOG"
    [ "$(grep -n '^flatpak kill com.valvesoftware.Steam' "$LOG" | cut -d: -f1)" -lt \
      "$(grep -n '^gio launch .*Steam' "$LOG" | cut -d: -f1)" ]
}

@test "a helper with no launcher is closed and not started" {
    printf '%s\n' org.gnome.NautilusPreviewer > "$APPS"
    ANSWER=reopen HANG=1 run -0 "$SCRIPT"
    grep -Fxq 'flatpak kill org.gnome.NautilusPreviewer' "$LOG"
    ! grep -q '^gio' "$LOG"
}

@test "an app that will not close is not started again into its old sandbox" {
    printf '%s\n' com.valvesoftware.Steam > "$APPS"
    STUBBORN=1 ANSWER=reopen HANG=1 run -0 "$SCRIPT"
    grep -Fxq 'flatpak kill com.valvesoftware.Steam' "$LOG"
    [[ "$output" == *"com.valvesoftware.Steam did not close; not starting it again"* ]]
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
