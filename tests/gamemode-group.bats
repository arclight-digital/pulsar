#!/usr/bin/env bats
# Tests for scripts/gamemode-group.sh and the config it exists to make work.
#
# What this pins is not "usermod was called". It is the four decisions that
# make the unit safe to leave on a retry loop:
#
#   1. It refuses to stamp unless membership is VERIFIED afterwards, so a
#      fresh install (no account yet, gnome-initial-setup still running)
#      retries instead of stamping an empty success and never trying again.
#   2. It enrols humans and only humans -- uid >= 1000, not nobody, with a
#      real shell -- rather than a hardcoded uid 1000.
#   3. It refuses to run at all if the @gamemode nice grant is gone, because
#      enrolling people into a group nothing references is theatre, and the
#      failure would otherwise be invisible.
#   4. It is idempotent, so `pulsar setup gamemode` after a second user is
#      added is the documented fix rather than a hazard.
#
# The stamp path is asserted against the unit file too. A stamp the script
# writes and the unit's ConditionPathExists does not read is a unit that runs
# forever, and that drift is exactly the kind a comment does not catch.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/gamemode-group.sh"

    export PULSAR_STATE_DIR="${BATS_TEST_TMPDIR}/state"
    STAMP="${PULSAR_STATE_DIR}/gamemode-group-enrolled"

    export PULSAR_LIMITS_DIR="${BATS_TEST_TMPDIR}/limits.d"
    export PULSAR_LIMITS_CONF="${BATS_TEST_TMPDIR}/limits.conf"
    mkdir -p "$PULSAR_LIMITS_DIR"
    : > "$PULSAR_LIMITS_CONF"
    printf '@gamemode - nice -10\n' > "${PULSAR_LIMITS_DIR}/10-gamemode.conf"

    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    PATH="${STUB}:${PATH}"

    # The fake account database: "name:uid:shell" per line.
    export PASSWD_DB="${BATS_TEST_TMPDIR}/passwd"
    # Members of the gamemode group, one per line.
    export GROUP_DB="${BATS_TEST_TMPDIR}/groupmembers"
    : > "$GROUP_DB"
    # Whether the gamemode group exists at all.
    export GROUP_EXISTS=1
    # The real state on an ostree host: the group is in /usr/lib/group (served
    # by nss-altfiles, so getent finds it) and /etc/group has no line at all.
    export PULSAR_ETC_GROUP="${BATS_TEST_TMPDIR}/group"
    printf 'wheel:x:10:proto\n' > "$PULSAR_ETC_GROUP"

    cat > "${STUB}/getent" <<'EOF'
#!/bin/sh
case "$1" in
group)
    [ "${GROUP_EXISTS}" = 1 ] || exit 2
    printf 'gamemode:x:983:\n'
    ;;
passwd)
    # getent passwd format: name:x:uid:gid:gecos:home:shell
    while IFS=: read -r n u sh; do
        [ -n "$n" ] || continue
        printf '%s:x:%s:%s::/home/%s:%s\n' "$n" "$u" "$u" "$n" "$sh"
    done < "$PASSWD_DB"
    ;;
esac
exit 0
EOF

    # `id -u` answers the root check; `id -nG` answers group membership.
    cat > "${STUB}/id" <<'EOF'
#!/bin/sh
if [ "$1" = "-u" ]; then printf '%s\n' "${FAKE_UID:-0}"; exit 0; fi
if [ "$1" = "-nG" ]; then
    printf '%s' "$2"
    grep -qx "$2" "$GROUP_DB" 2>/dev/null && printf ' gamemode'
    printf '\n'
    exit 0
fi
exit 1
EOF

    cat > "${STUB}/usermod" <<'EOF'
#!/bin/sh
# usermod -aG gamemode <user> -- the name is the third argument.
#
# Reproduces the behaviour that made this fix necessary: usermod edits
# /etc/group and nothing else, so when the group is image-only it writes to
# gshadow, changes no membership, and STILL EXITS 0.
user=$3
if [ -n "$USERMOD_FAIL_USER" ] && [ "$user" = "$USERMOD_FAIL_USER" ]; then
    echo "usermod: refusing $user" >&2
    exit 1
fi
if ! grep -q "^gamemode:" "$PULSAR_ETC_GROUP"; then
    echo "add '$user' to shadow group 'gamemode'"
    exit 0
fi
echo "$user" >> "$GROUP_DB"
exit 0
EOF
    export USERMOD_FAIL_USER=""
    chmod +x "${STUB}/getent" "${STUB}/id" "${STUB}/usermod"
    export PATH
}

@test "a human account is enrolled and the stamp is written" {
    printf 'proto:1000:/bin/bash\n' > "$PASSWD_DB"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"enrolled proto"* ]]
    grep -qx proto "$GROUP_DB"
    [ -f "$STAMP" ]
}

@test "the stamp says membership only applies at the next login" {
    printf 'proto:1000:/bin/bash\n' > "$PASSWD_DB"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"NEXT login"* ]]
}

@test "no human accounts yet is a retry, not a stamped success" {
    # The expected first pass on a fresh install: gnome-initial-setup has not
    # created anyone. Stamping here would mean the real user is never enrolled.
    : > "$PASSWD_DB"
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no human accounts yet"* ]]
    [ ! -f "$STAMP" ]
}

@test "system accounts and nobody are not human" {
    printf 'nobody:65534:/usr/sbin/nologin\n' >> "$PASSWD_DB"
    printf 'dnsmasq:983:/usr/sbin/nologin\n'  >> "$PASSWD_DB"
    printf 'flatpak:1001:/usr/sbin/nologin\n' >> "$PASSWD_DB"
    printf 'svc:1002:/bin/false\n'            >> "$PASSWD_DB"
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no human accounts yet"* ]]
    [ ! -s "$GROUP_DB" ]
}

@test "every human account is enrolled, not just uid 1000" {
    printf 'proto:1000:/bin/bash\n' > "$PASSWD_DB"
    printf 'ada:1001:/bin/zsh\n'   >> "$PASSWD_DB"
    printf 'nobody:65534:/usr/sbin/nologin\n' >> "$PASSWD_DB"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -qx proto "$GROUP_DB"
    grep -qx ada "$GROUP_DB"
    [ "$(wc -l < "$GROUP_DB")" -eq 2 ]
}

@test "an account already in the group is left alone" {
    printf 'proto:1000:/bin/bash\n' > "$PASSWD_DB"
    printf 'proto\n' > "$GROUP_DB"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already in gamemode"* ]]
    [[ "$output" != *"enrolled proto"* ]]
    [ "$(wc -l < "$GROUP_DB")" -eq 1 ]
}

@test "one account that cannot be enrolled does not stamp over the others" {
    printf 'proto:1000:/bin/bash\n' > "$PASSWD_DB"
    printf 'ada:1001:/bin/zsh\n'   >> "$PASSWD_DB"
    export USERMOD_FAIL_USER=ada
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    grep -qx proto "$GROUP_DB"
    [[ "$output" == *"still not in gamemode"* ]]
    [[ "$output" == *ada* ]]
    [ ! -f "$STAMP" ]
}

@test "a missing gamemode group is a loud failure" {
    printf 'proto:1000:/bin/bash\n' > "$PASSWD_DB"
    export GROUP_EXISTS=0
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no 'gamemode' group"* ]]
    [ ! -f "$STAMP" ]
}

@test "a missing nice grant is refused rather than silently useless" {
    # Without @gamemode in limits.d, renice=10 cannot work no matter who is in
    # the group -- so enrolling anyone would be theatre with no symptom.
    printf 'proto:1000:/bin/bash\n' > "$PASSWD_DB"
    rm -f "${PULSAR_LIMITS_DIR}/10-gamemode.conf"
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nice grant"* ]]
    [ ! -f "$STAMP" ]
}

@test "running as a normal user is refused" {
    printf 'proto:1000:/bin/bash\n' > "$PASSWD_DB"
    export FAKE_UID=1000
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"must run as root"* ]]
}

@test "the unit's condition path is the stamp the script writes" {
    # Drift here means a unit that runs on every boot forever, or one that
    # never runs again after a failure. Neither shows up in a log.
    local unit="${BATS_TEST_DIRNAME}/../system_files/usr/lib/systemd/system/pulsar-gamemode-group.service"
    local from_unit
    from_unit=$(sed -n 's/^ConditionPathExists=!//p' "$unit")
    [ "$from_unit" = "/var/lib/pulsar/gamemode-group-enrolled" ]
    # the script's default stamp, with no PULSAR_STATE_DIR override in play
    grep -q 'STAMP="\${STAMP_DIR}/gamemode-group-enrolled"' "$SCRIPT"
    grep -q 'STAMP_DIR=\${PULSAR_STATE_DIR:-/var/lib/pulsar}' "$SCRIPT"
}

@test "the unit runs the script the setup recipe runs" {
    local unit="${BATS_TEST_DIRNAME}/../system_files/usr/lib/systemd/system/pulsar-gamemode-group.service"
    local cli="${BATS_TEST_DIRNAME}/../cli/pulsar"
    grep -q 'ExecStart=/usr/libexec/pulsar/gamemode-group.sh' "$unit"
    grep -q '/usr/libexec/pulsar/gamemode-group.sh' "$cli"
}

@test "an image-only group is copied into /etc/group before anyone is enrolled" {
    # THE BUG THIS PINS. On an ostree host the group ships in /usr/lib/group
    # and is merged in by nss-altfiles, so `getent group gamemode` answers
    # while /etc/group has no line. usermod edits only /etc/group, so it wrote
    # to gshadow, reported success, and enrolled nobody -- silently, with
    # res=success in the audit log. Without the copy, this test hangs the unit
    # in its retry loop forever.
    printf 'proto:1000:/bin/bash\n' > "$PASSWD_DB"
    ! grep -q '^gamemode:' "$PULSAR_ETC_GROUP"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"copied gamemode into"* ]]
    grep -q '^gamemode:x:983:' "$PULSAR_ETC_GROUP"
    grep -qx proto "$GROUP_DB"
    [ -f "$STAMP" ]
}

@test "a group already in /etc/group is not copied twice" {
    printf 'gamemode:x:983:\n' >> "$PULSAR_ETC_GROUP"
    printf 'proto:1000:/bin/bash\n' > "$PASSWD_DB"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"copied gamemode"* ]]
    [ "$(grep -c '^gamemode:' "$PULSAR_ETC_GROUP")" -eq 1 ]
}
