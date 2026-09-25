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
#
# Since the list grew a second column -- the remote, defaulting to flathub --
# the stub records the remote it was actually handed rather than assuming one,
# so "installed from the right remote" is a thing a test can fail on. That
# matters more than it looks: the Silverblue set has to come from `fedora`,
# and installing it from flathub would succeed while being wrong.

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
org.example.FromFedora  fedora
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

    # The bus. `fedora` is an OCI remote, and the real flatpak can only install
    # from one over a session bus -- so the stub refuses a `fedora` install,
    # with the real error, unless it is on the PRIVATE bus the script is meant
    # to start. Not "any bus": a test can hand the script a bus of its own and
    # the install must still come through dbus-run-session.
    export STUB_PRIVATE_BUS="unix:path=${BATS_TEST_TMPDIR}/private-bus"
    cat > "${STUB}/dbus-run-session" <<'EOF'
#!/bin/sh
[ "$1" = -- ] && shift
echo x >> "${BATS_TEST_TMPDIR}/dbus-run-session.calls"
DBUS_SESSION_BUS_ADDRESS="$STUB_PRIVATE_BUS" exec "$@"
EOF
    # Answers GetConnectionUnixProcessID the way the real one does, for the
    # pid in AUTH_PID_FILE when there is one, and as "no owner" otherwise.
    cat > "${STUB}/gdbus" <<'EOF'
#!/bin/sh
f="${BATS_TEST_TMPDIR}/auth.pid"
if [ -s "$f" ] && [ "$DBUS_SESSION_BUS_ADDRESS" = "$STUB_PRIVATE_BUS" ]; then
    echo "($(printf 'uint32 %s' "$(cat "$f")"),)"
    exit 0
fi
echo "Error: GDBus.Error:org.freedesktop.DBus.Error.NameHasNoOwner" >&2
exit 1
EOF
    chmod +x "${STUB}/dbus-run-session" "${STUB}/gdbus"

    cat > "${STUB}/flatpak" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = list ]; then
    # Mirrors the real `flatpak list --columns=application,branch`: every ref
    # answers to its bare id and, when it carries one, to id//branch.
    #
    # It also HONOURS --app, which is the whole point. The real flag hides
    # runtime extensions, and a stub that ignored it would let the --app bug
    # back in while every test stayed green.
    only_apps=0
    for a in "$@"; do [ "$a" = "--app" ] && only_apps=1; done
    awk -v only_apps="$only_apps" '
        NF {
            id=$1; sub(/\/\/.*/,"",id)
            is_runtime = (id ~ /^org\.(freedesktop|kde)\.(Platform|Sdk)/)
            if (only_apps && is_runtime) next
            print id
            if (id != $1) print $1
        }' "$FLATPAK_STATE"
    exit 0
fi
# install: the application id is the last argument, the remote the one
# before it -- `flatpak install --system ... <remote> <app>`
prev=; app=
for a in "$@"; do prev="$app"; app="$a"; done
remote="$prev"
if [ "$remote" = fedora ] && [ "$DBUS_SESSION_BUS_ADDRESS" != "$STUB_PRIVATE_BUS" ]; then
    echo "error: Cannot autolaunch D-Bus without X11 \$DISPLAY" >&2
    exit 1
fi
if [ -n "$FLATPAK_FAIL_APP" ] && [ "$app" = "$FLATPAK_FAIL_APP" ]; then
    echo "error: ${app} not found in remote ${remote}" >&2
    exit 1
fi
origin=$(awk -v a="$app" '$1 == a {print $2}' "$FLATPAK_STATE")
if [ -n "$origin" ] && [ "$origin" != "$remote" ]; then
    echo "error: ${app}/x86_64/stable is already installed from remote ${origin}" >&2
    exit 1
fi
grep -q "^${app} " "$FLATPAK_STATE" || printf '%s %s\n' "$app" "$remote" >> "$FLATPAK_STATE"
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
    [[ "$output" == *"4 apps present"* ]]
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

@test "an app carrying a remote is installed from that remote, not flathub" {
    stub_flatpak
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installed org.example.FromFedora from fedora"* ]]
    run grep '^org.example.FromFedora ' "$FLATPAK_STATE"
    [[ "$output" == *"fedora"* ]]
}

@test "a bare line still means flathub, so old list lines are unchanged" {
    stub_flatpak
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installed com.example.One from flathub"* ]]
    run grep '^com.example.One ' "$FLATPAK_STATE"
    [[ "$output" == *"flathub"* ]]
}

@test "the shipped list names only remotes the image actually configures" {
    remotes=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' \
        "${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar/flatpaks.list" \
        | awk '{print ($2 == "" ? "flathub" : $2)}' | sort -u)
    for r in $remotes; do
        # A remote that is not shipped as a remotes.d file cannot resolve on a
        # fresh install, and the service would then retry every 120s forever.
        [ -f "${BATS_TEST_DIRNAME}/../system_files/etc/flatpak/remotes.d/${r}.flatpakrepo" ]
    done
}

@test "an empty list is a broken list, not a quiet success" {
    stub_flatpak
    printf '# only a comment\n' > "$PULSAR_FLATPAKS_LIST"
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"lists no apps"* ]]
    [ ! -f "$STAMP" ]
}

# ---------------------------------------------------------------------------
# Runtime extensions. MangoHud's Vulkan layer is not an application, and the
# presence check used to run `flatpak list --app`, which cannot see one. The
# consequence was not a wasted reinstall: the verification loop shares that
# predicate, so the stamp was never written and the unit retried every 120s
# forever -- the failure this script exists to have ended.
# ---------------------------------------------------------------------------

@test "a branch-pinned runtime extension installs and is then seen as present" {
    printf 'org.freedesktop.Platform.VulkanLayer.MangoHud//25.08\n' > "$PULSAR_FLATPAKS_LIST"
    stub_flatpak
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installed org.freedesktop.Platform.VulkanLayer.MangoHud//25.08"* ]]
    [ -f "$STAMP" ]
}

@test "an already-present extension is skipped rather than reinstalled" {
    printf 'org.freedesktop.Platform.VulkanLayer.MangoHud//25.08\n' > "$PULSAR_FLATPAKS_LIST"
    stub_flatpak "org.freedesktop.Platform.VulkanLayer.MangoHud//25.08:flathub"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed"* ]]
    [ -f "$STAMP" ]
}

@test "the shipped list pins a branch on every runtime extension it names" {
    # A bare extension id is ambiguous on flathub, which carries 21.08 through
    # 26.08. Both resolutions are wrong: erroring stalls the first-boot
    # service, and silently taking the newest installs a layer no app can see,
    # with no symptom but a missing overlay.
    local list="${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar/flatpaks.list"
    while read -r app _; do
        case "$app" in
            org.freedesktop.Platform.*|org.kde.Platform.*|*.VulkanLayer.*)
                [[ "$app" == *//* ]] || {
                    echo "unpinned runtime extension in flatpaks.list: $app" >&2
                    return 1
                } ;;
        esac
    done < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$list")
}

# ---------------------------------------------------------------------------
# The session bus. Installing from the `fedora` OCI remote goes through
# flatpak's OCI authenticator, which lives on the SESSION bus, and the
# first-boot service is a system unit with none. On the first machine installed
# from a Pulsar ISO every flathub app landed and all 18 Silverblue apps failed
# with "Cannot autolaunch D-Bus without X11 $DISPLAY", every 120s.
# ---------------------------------------------------------------------------

@test "REGRESSION: a fedora-remote app installs when the caller has no session bus" {
    stub_flatpak
    run env -u DBUS_SESSION_BUS_ADDRESS -u XDG_RUNTIME_DIR -u DISPLAY "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Cannot autolaunch"* ]]
    [[ "$output" == *"installed org.example.FromFedora from fedora"* ]]
    [ -f "$STAMP" ]
}

@test "the private bus is used even when the caller already has one" {
    # sudo from a desktop session: a bus exists, but it is the user's, and a
    # root install must not depend on someone being logged in.
    stub_flatpak
    DBUS_SESSION_BUS_ADDRESS="unix:path=${BATS_TEST_TMPDIR}/someone-elses-bus" run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"installed org.example.FromFedora from fedora"* ]]
    [ "$(wc -l < "${BATS_TEST_TMPDIR}/dbus-run-session.calls")" -eq 1 ]
}

@test "the authenticator left on the private bus is stopped on the way out" {
    # It outlives dbus-run-session and holds stdout open, which is what makes
    # `sudo pulsar setup apps | tee log` never return.
    stub_flatpak
    # Detached from every fd bats reads, or bats waits on it instead.
    sleep 300 </dev/null >/dev/null 2>&1 3>&- &
    local auth=$!
    echo "$auth" > "${BATS_TEST_TMPDIR}/auth.pid"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    sleep 0.2
    if kill -0 "$auth" 2>/dev/null; then
        kill "$auth"
        echo "the authenticator (pid ${auth}) survived the script" >&2
        return 1
    fi
}

@test "no authenticator to stop is the ordinary case, not an error" {
    stub_flatpak
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$STAMP" ]
}
