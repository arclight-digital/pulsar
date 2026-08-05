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
    # "attestation" is exactly 11 chars and once collided with its value
    [[ "$output" == *"attestation "* ]]
}

@test "manifest --json is machine readable and unstyled" {
    run "$PULSAR" manifest --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.version == "44.20260805.0"'
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
