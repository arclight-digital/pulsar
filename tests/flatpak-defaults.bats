#!/usr/bin/env bats
# Tests for scripts/flatpak-defaults.sh.
#
# The bug these exist for: the script used to install the whole list in one
# batched `flatpak install`, so a single application that could not be
# installed took the other seven with it. On cherenkov that single application
# was easyeffects -- preinstalled system-wide from the Silverblue base's
# `fedora` OCI remote, which our list also asks for from flathub. flatpak
# treats a cross-remote collision as a hard error, the batch aborted, four
# defaults were never installed, the success-only stamp never landed, and
# Restart=on-failure looped every 120s for six days.
#
# So what is pinned here is not "install was called". It is the three
# decisions: an app that is already present is skipped rather than attempted,
# one app failing does not stop the others, and the stamp is written only when
# every listed app is genuinely present afterwards.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/flatpak-defaults.sh"

    export PULSAR_STATE_DIR="${BATS_TEST_TMPDIR}/state"
    STAMP="${PULSAR_STATE_DIR}/flatpaks-installed"

    export PULSAR_FLATPAKS_LIST="${BATS_TEST_TMPDIR}/flatpaks.list"
    cat > "$PULSAR_FLATPAKS_LIST" <<'LIST'
# a comment, and a blank line, both of which the script strips

com.example.One
com.example.Two
com.github.wwmm.easyeffects
LIST
}

# A flatpak that keeps its installed set in a file, as "application remote"
# pairs, so a test can seed one from a remote other than flathub. Refuses a
# cross-remote install the way the real one does, with the real message.
#
# $1.. = optional "app:remote" pairs to preinstall.
stub_flatpak() {
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    export FLATPAK_STATE="${BATS_TEST_TMPDIR}/installed"
    : > "$FLATPAK_STATE"
    local pair
    for pair in "$@"; do
        printf '%s %s\n' "${pair%%:*}" "${pair##*:}" >> "$FLATPAK_STATE"
    done
    # FAIL_APP is the app the stub should refuse outright, standing in for an
    # app that is simply unavailable rather than one that collides.
    export FLATPAK_FAIL_APP="${FLATPAK_FAIL_APP:-}"
    cat > "${STUB}/flatpak" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = list ]; then
    awk '{print $1}' "$FLATPAK_STATE"
    exit 0
fi
# install: the application id is the last argument
for a in "$@"; do app="$a"; done
if [ -n "$FLATPAK_FAIL_APP" ] && [ "$app" = "$FLATPAK_FAIL_APP" ]; then
    echo "error: ${app} not found in remote flathub" >&2
    exit 1
fi
origin=$(awk -v a="$app" '$1 == a {print $2}' "$FLATPAK_STATE")
if [ -n "$origin" ] && [ "$origin" != flathub ]; then
    echo "error: ${app}/x86_64/stable is already installed from remote ${origin}" >&2
    exit 1
fi
grep -q "^${app} " "$FLATPAK_STATE" || printf '%s flathub\n' "$app" >> "$FLATPAK_STATE"
EOF
    chmod +x "${STUB}/flatpak"
    PATH="${STUB}:${PATH}"
    export PATH
}

installed() { awk '{print $1}' "$FLATPAK_STATE"; }

@test "REGRESSION: an app preinstalled from another remote is skipped, not fatal" {
    stub_flatpak "com.github.wwmm.easyeffects:fedora"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
    [ -f "$STAMP" ]
}

@test "REGRESSION: the collision does not stop the rest of the list installing" {
    stub_flatpak "com.github.wwmm.easyeffects:fedora"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    # The four that went missing on cherenkov are these two here: everything
    # ordered after the colliding app in the list.
    run installed
    [[ "$output" == *"com.example.One"* ]]
    [[ "$output" == *"com.example.Two"* ]]
}

@test "the preinstalled app is left on its own remote rather than reinstalled" {
    stub_flatpak "com.github.wwmm.easyeffects:fedora"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run grep '^com.github.wwmm.easyeffects ' "$FLATPAK_STATE"
    [[ "$output" == *"fedora"* ]]
}

@test "a genuinely uninstallable app costs that app and not the set" {
    FLATPAK_FAIL_APP=com.example.One
    stub_flatpak
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    run installed
    [[ "$output" == *"com.example.Two"* ]]
    [[ "$output" == *"com.github.wwmm.easyeffects"* ]]
}

@test "the stamp is not written while any listed app is missing" {
    FLATPAK_FAIL_APP=com.example.One
    stub_flatpak
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"still missing"* ]]
    [ ! -f "$STAMP" ]
}

@test "a clean run installs everything and stamps" {
    stub_flatpak
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$STAMP" ]
    [[ "$output" == *"3 apps present"* ]]
}

@test "a second run is a no-op that still stamps" {
    stub_flatpak
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    # Nothing was reinstalled: every line reports the app as already there.
    [[ "$output" == *"com.example.One is already installed"* ]]
    [ -f "$STAMP" ]
}

@test "an empty list is a broken list, not a quiet success" {
    stub_flatpak
    printf '# only a comment\n' > "$PULSAR_FLATPAKS_LIST"
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"lists no apps"* ]]
    [ ! -f "$STAMP" ]
}
