#!/usr/bin/env bats
# Tests for the pulsar CLI.
#
# These run in CI on Ubuntu, on a machine that is not a Pulsar system and has
# no bootc, no rpm-ostree and no /sys/kernel/sched_ext. That is the point: the
# CLI has to degrade honestly on a system it does not understand rather than
# crash or, worse, report health it cannot actually see.
#
# What is deliberately NOT tested here: that `pulsar update` upgrades anything.
# It is one exec into bootc, and a test that mocked bootc would only assert
# that the mock was called.

setup() {
    PULSAR="${BATS_TEST_DIRNAME}/../cli/pulsar"
    export PULSAR_MANIFEST="${BATS_TEST_TMPDIR}/manifest.json"
    cat > "$PULSAR_MANIFEST" <<'JSON'
{
  "image": "pulsar",
  "variant": "vanilla",
  "version": "44.20260805.0",
  "base": "fedora-silverblue:44",
  "built": "2026-08-05T19:44:00Z",
  "kernel": "7.1.5-201.fc44.x86_64",
  "components": { "scheduler": "scx_bpfland", "gamescope": "3.16.14-1.fc44" },
  "changelog_url": "https://example.invalid/changelog.json",
  "attestation": "gh attestation verify oci://ghcr.io/x --owner y"
}
JSON
}

@test "runs and reports a version" {
    run "$PULSAR" --version
    [ "$status" -eq 0 ]
    [[ "$output" == pulsar\ * ]]
}

@test "bare --help prints the top-level usage" {
    run "$PULSAR" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"pulsar manifest"* ]]
    [[ "$output" == *"pulsar doctor"* ]]
}

@test "--help after a subcommand belongs to that subcommand" {
    run "$PULSAR" setup --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"devbox"* ]]
    [[ "$output" == *"quadlet"* ]]
    # must NOT have fallen through to the global usage
    [[ "$output" != *"pulsar rollback"* ]]
}

@test "unknown command fails and does not look like success" {
    run "$PULSAR" definitely-not-a-command
    [ "$status" -ne 0 ]
}

@test "unknown setup recipe fails" {
    run "$PULSAR" setup not-a-recipe
    [ "$status" -ne 0 ]
}

@test "manifest renders every key with its value on the same line" {
    run "$PULSAR" manifest
    [ "$status" -eq 0 ]
    [[ "$output" == *"44.20260805.0"* ]]
    [[ "$output" == *"scx_bpfland"* ]]
}

@test "manifest lists facts, not other commands to run" {
    # `sbom` and `attestation` were rows whose values were commands. The
    # attestation one was 82 characters wide to restate what --help says.
    run "$PULSAR" manifest
    [ "$status" -eq 0 ]
    [[ "$output" != *"pulsar sbom"* ]]
    [[ "$output" != *"pulsar attest"* ]]
    [[ "$output" != *"gh attestation"* ]]
}

@test "attest runs the verify command the manifest carries, not a baked one" {
    # The owner and registry are build-time facts: an image built from a fork
    # must verify against the fork, so the command comes from the manifest.
    # Naming a verifier that does not exist proves which one it reached for.
    cat > "$PULSAR_MANIFEST" <<'JSON'
{"image":"pulsar","attestation":"definitely-not-a-real-verifier verify oci://x"}
JSON
    run "$PULSAR" attest
    [ "$status" -ne 0 ]
    [[ "$output" == *"definitely-not-a-real-verifier"* ]]
}

@test "attest refuses an image whose manifest has no attestation" {
    echo '{"image":"pulsar"}' > "$PULSAR_MANIFEST"
    run "$PULSAR" attest
    [ "$status" -ne 0 ]
    [[ "$output" == *"no attestation"* ]]
}

@test "manifest --json is machine readable and unstyled" {
    run "$PULSAR" manifest --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.version == "44.20260805.0"'
}

@test "manifest --json carries the host facts the rows show" {
    run "$PULSAR" manifest --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.host | type == "object"'
    # /proc/uptime exists on anything this can run on, and it goes out as a
    # number: a machine should not have to parse "2h 14m".
    echo "$output" | jq -e '.host.uptime_s | type == "number"'
    echo "$output" | jq -e '.host.gpu == null or (.host.gpu | type == "array")'
}

@test "deleting the host key leaves exactly the baked manifest" {
    # The reason host is one key instead of merged fields: two machines on the
    # same build must still compare equal.
    run "$PULSAR" manifest --json
    [ "$status" -eq 0 ]
    echo "$output" | jq --slurpfile baked "$PULSAR_MANIFEST" -e 'del(.host) == $baked[0]'
}

@test "host facts never contain the hostname" {
    # The rows identify the hardware, not the machine or its owner -- this
    # output gets pasted into public bug reports.
    #
    # Read from /proc rather than calling hostname(1): the binary is absent
    # from a minimal container, and a test that silently errors instead of
    # checking is worse than no test.
    local host
    host=$(cat /proc/sys/kernel/hostname 2>/dev/null || true)
    [ -n "$host" ] || skip "no hostname to look for"
    run "$PULSAR" manifest
    [ "$status" -eq 0 ]
    [[ "$output" != *"$host"* ]]
}

@test "piped output carries no ANSI escapes" {
    run "$PULSAR" manifest
    [ "$status" -eq 0 ]
    # $'\033' must not appear when stdout is not a terminal
    [[ "$output" != *$'\033'* ]]
}

@test "a missing manifest is an error, not a crash" {
    PULSAR_MANIFEST="${BATS_TEST_TMPDIR}/nope.json" run "$PULSAR" manifest
    [ "$status" -eq 1 ]
    [[ "$output" == *"no manifest"* ]]
}

@test "changelog without a url in the manifest fails cleanly" {
    echo '{"image":"pulsar"}' > "$PULSAR_MANIFEST"
    run "$PULSAR" changelog
    [ "$status" -ne 0 ]
    [[ "$output" == *"changelog_url"* ]]
}

@test "root-only commands refuse to run as a normal user" {
    [ "$(id -u)" -eq 0 ] && skip "running as root"
    for c in update rollback pin unpin; do
        run "$PULSAR" "$c"
        [ "$status" -ne 0 ]
        [[ "$output" == *"root"* ]]
    done
}

@test "doctor produces valid json even off a Pulsar system" {
    run "$PULSAR" doctor --json
    # status may be 0 or 1 depending on the host; the contract is valid JSON
    echo "$output" | jq -e '.checks | type == "array"'
    echo "$output" | jq -e '.ok | type == "boolean"'
}

@test "doctor json marks every check with a known severity" {
    run "$PULSAR" doctor --json
    echo "$output" | jq -e 'all(.checks[]; .status == "ok" or .status == "warn" or .status == "fail")'
}

@test "doctor exit code agrees with the ok field" {
    run "$PULSAR" doctor --json
    local ok; ok=$(echo "$output" | jq -r '.ok')
    if [ "$ok" = "true" ]; then [ "$status" -eq 0 ]; else [ "$status" -ne 0 ]; fi
}

@test "doctor does not claim greenboot is healthy when it is absent" {
    # The original bug: `systemctl is-enabled` prints not-found AND exits
    # nonzero, so a `|| echo not-found` fallback produced "not-found\nnot-found",
    # matched nothing, and the check reported "health checks passed" on a
    # system with no greenboot at all.
    run "$PULSAR" doctor --json
    run_status=$(echo "$output" | jq -r '.checks[] | select(.id=="greenboot") | .status')
    summary=$(echo "$output" | jq -r '.checks[] | select(.id=="greenboot") | .summary')
    if [ "$run_status" = "ok" ]; then
        [[ "$summary" != *"not installed"* ]]
    fi
}

# --- manifest layout --------------------------------------------------------
# The key column was a hardcoded 11, which "attestation" (11) ran into and
# which "scheduler_btf" (13) overflowed entirely. It is measured now, so these
# pin the measuring rather than the number.

@test "manifest key column is measured from the longest key" {
    cat > "$PULSAR_MANIFEST" <<'JSON'
{"image":"pulsar","version":"1","components":{"a":"x","scheduler_btf":"malformed"}}
JSON
    run "$PULSAR" manifest
    [ "$status" -eq 0 ]
    # every value must start at the same column
    cols=$(printf '%s\n' "$output" | awk '{ i=index($0,$2); print i }' | sort -u | wc -l)
    [ "$cols" -eq 1 ]
}

@test "manifest survives a key longer than any built-in one" {
    cat > "$PULSAR_MANIFEST" <<'JSON'
{"image":"pulsar","components":{"an_absurdly_long_component_key":"v"}}
JSON
    run "$PULSAR" manifest
    [ "$status" -eq 0 ]
    # padded to the longest key + 2, so exactly two spaces here
    [[ "$output" == *"an_absurdly_long_component_key  v"* ]]
}

@test "a corrupt manifest fails loudly instead of printing nothing" {
    echo 'not json at all' > "$PULSAR_MANIFEST"
    run "$PULSAR" manifest
    [ "$status" -ne 0 ]
}

@test "every line of the shipped logo has the same visible width" {
    # The info column is pasted at a fixed offset, so one short line shears
    # the whole readout. The art is generated, so this guards the generator.
    art="${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar/logo.ansi"
    [ -r "$art" ]
    widths=$(sed $'s/\033\\[[0-9;]*m//g' "$art" | awk '{ print length($0) }' | sort -u | wc -l)
    [ "$widths" -eq 1 ]
}

@test "the logo is 7-bit ASCII, as a logo called ASCII should be" {
    art="${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar/logo.ansi"
    # strip the colour escapes, then assert nothing outside printable ASCII
    run bash -c "sed \$'s/\033\\[[0-9;]*m//g' '$art' | LC_ALL=C grep -qP '[^\\x20-\\x7e]'"
    [ "$status" -ne 0 ]
}

@test "manifest draws the logo when asked and omits it when told not to" {
    PULSAR_LOGO="${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar/logo.ansi"
    export PULSAR_LOGO
    # NOT a line count. That worked only while the art was taller than the
    # readout; once the host rows fill in, the readout is the longer column
    # and both forms come out the same height. The art is the only thing that
    # carries colour into a pipe, so that is the tell.
    run env LOGO=always "$PULSAR" manifest
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033'* ]]
    run env LOGO=never "$PULSAR" manifest
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\033'* ]]
}

@test "the logo never appears in piped output" {
    # bats captures through a pipe, so this is the not-a-terminal path
    PULSAR_LOGO="${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar/logo.ansi"
    export PULSAR_LOGO
    run "$PULSAR" manifest
    [[ "$output" != *$'\033'* ]]
    # every line must start with a manifest key, not with art
    while IFS= read -r line; do
        [[ "$line" =~ ^[a-z_]+[[:space:]] ]] || fail "not a key row: $line"
    done <<< "$output"
}

# --- audit pass: argument and input hygiene ---------------------------------

@test "commands that take no arguments reject them" {
    run "$PULSAR" doctor tomorrow
    [ "$status" -ne 0 ]
    [[ "$output" == *"takes no arguments"* ]]
    run "$PULSAR" manifest extra
    [ "$status" -ne 0 ]
}

@test "changelog renders a baseline as a baseline, not as zero changes" {
    cl="${BATS_TEST_TMPDIR}/cl.json"
    printf '{"baseline":true,"generated":"2026-08-05T00:00:00Z"}' > "$cl"
    jq --arg u "file://${cl}" '.changelog_url = $u' "$PULSAR_MANIFEST" > "${PULSAR_MANIFEST}.n" \
        && mv "${PULSAR_MANIFEST}.n" "$PULSAR_MANIFEST"
    run "$PULSAR" changelog
    [ "$status" -eq 0 ]
    [[ "$output" == *"first build"* ]]
    [[ "$output" != *"0 upgraded"* ]]
}

@test "changelog marks a downgrade instead of blending it into upgrades" {
    cl="${BATS_TEST_TMPDIR}/cl.json"
    cat > "$cl" <<'JSON'
{"generated":"2026-08-05T00:00:00Z",
 "summary":{"added":0,"removed":0,"upgraded":1,"downgraded":1,"changed":0},
 "changed":[{"name":"up","from":"1","to":"2","direction":"upgraded"},
            {"name":"down","from":"2","to":"1","direction":"downgraded"}],
 "added":[],"removed":[]}
JSON
    jq --arg u "file://${cl}" '.changelog_url = $u' "$PULSAR_MANIFEST" > "${PULSAR_MANIFEST}.n" \
        && mv "${PULSAR_MANIFEST}.n" "$PULSAR_MANIFEST"
    run "$PULSAR" changelog
    [ "$status" -eq 0 ]
    [[ "$output" == *"~ up"* ]]
    [[ "$output" == *"! down"* ]]
}

@test "changelog dies cleanly when the url serves something else" {
    cl="${BATS_TEST_TMPDIR}/cl.json"
    printf 'this is a captive portal, honest' > "$cl"
    jq --arg u "file://${cl}" '.changelog_url = $u' "$PULSAR_MANIFEST" > "${PULSAR_MANIFEST}.n" \
        && mv "${PULSAR_MANIFEST}.n" "$PULSAR_MANIFEST"
    run "$PULSAR" changelog
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a changelog"* ]]
}

@test "setup recipes refuse to run as root" {
    [ "$(id -u)" -eq 0 ] || skip "meaningful only as root"
    run "$PULSAR" setup quadlet
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not run as root"* ]]
}
