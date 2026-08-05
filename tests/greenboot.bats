#!/usr/bin/env bats
# Tests for the greenboot health checks.
#
# These matter more than most tests in this repo: a required check that
# returns nonzero does not print a warning, it reboots the machine, and three
# of those roll the deployment back. A false negative here is indistinguishable
# from a broken OS image, from the user's side.
#
# That is not hypothetical. The first version of 10-graphical-target.sh polled
# `systemctl is-active graphical.target`, which can never succeed from inside
# greenboot-healthcheck.service -- the service is WantedBy=multi-user.target and
# graphical.target Requires+After multi-user.target, so the target it waited for
# was waiting on it. It rebooted a working laptop 112 seconds after the user had
# logged in.

setup() {
    CHECK_DIR="${BATS_TEST_DIRNAME}/../system_files/usr/lib/greenboot/check"
    GRAPHICAL="${CHECK_DIR}/required.d/10-graphical-target.sh"
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    PATH="${STUB}:${PATH}"
    export PATH
    export PULSAR_GRAPHICAL_TIMEOUT=1
}

# $1 = what `loginctl list-sessions --no-legend` prints, $2 = session Type
stub_loginctl() {
    cat > "${STUB}/loginctl" <<EOF
#!/bin/sh
case "\$1" in
  list-sessions) printf '%s' '$1'; [ -n '$1' ] && echo ;;
  show-session)  echo '$2' ;;
esac
EOF
    chmod +x "${STUB}/loginctl"
}

@test "passes when a wayland session exists" {
    stub_loginctl "  2 1000 proto seat0 -" wayland
    run bash "$GRAPHICAL"
    [ "$status" -eq 0 ]
    [[ "$output" == *"graphical session present"* ]]
}

@test "passes at the login screen, before anyone has logged in" {
    # class=greeter is a successful boot: the machine is offering a login.
    stub_loginctl "  c1 977 gdm-greeter seat0 -" wayland
    run bash "$GRAPHICAL"
    [ "$status" -eq 0 ]
}

@test "passes on x11 as well as wayland" {
    stub_loginctl "  2 1000 proto seat0 -" x11
    run bash "$GRAPHICAL"
    [ "$status" -eq 0 ]
}

@test "fails when the only session is a tty" {
    stub_loginctl "  1 1000 proto seat0 tty2" tty
    run bash "$GRAPHICAL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no graphical session"* ]]
}

@test "fails when there are no sessions at all" {
    stub_loginctl "" ""
    run bash "$GRAPHICAL"
    [ "$status" -eq 1 ]
}

@test "fails rather than crashes when loginctl is missing entirely" {
    printf '#!/bin/sh\nexit 127\n' > "${STUB}/loginctl"
    chmod +x "${STUB}/loginctl"
    run bash "$GRAPHICAL"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no graphical session"* ]]
}

@test "a failure explains itself instead of just exiting" {
    stub_loginctl "" ""
    run bash "$GRAPHICAL"
    [[ "$output" == *"display-manager.service"* ]]
    [[ "$output" == *"failed units"* ]]
}

@test "REGRESSION: never waits on graphical.target" {
    # The deadlock that rebooted a healthy machine. graphical.target cannot
    # activate until this script exits, so any wait on it is unsatisfiable.
    run grep -n "is-active.*graphical\.target" "$GRAPHICAL"
    [ "$status" -ne 0 ]
}

@test "every check is executable and starts with a shebang" {
    for f in "${CHECK_DIR}"/*/*.sh; do
        [ -x "$f" ] || fail "not executable: $f"
        head -1 "$f" | grep -q '^#!' || fail "no shebang: $f"
    done
}
