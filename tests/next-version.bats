#!/usr/bin/env bats
# The version scheme, which is the one thing in this repo with an incident
# history: two builds computed the same tag on 2026-08-05 and again on
# 2026-08-07, and a hand-run build spent a number in the published series on
# 2026-08-08. next-version.sh's header is the argument; these are the assertions.
#
# The first behavioural tests of any build script here. They are cheap because
# the script's only external facts are `command -v oras`, `oras repo tags` and
# `date -u`, so a stub on PATH is the whole harness -- the idiom greenboot.bats
# already uses for loginctl.

# For `run --separate-stderr` below. Stating it turns "this bats is too old" from
# a warning printed beside passing tests into a refusal to run them.
bats_require_minimum_version 1.5.0

setup() {
  NV="${BATS_TEST_DIRNAME}/../scripts/next-version.sh"
  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${BIN}"
  PATH="${BIN}:${PATH}"
  DAY="$(date -u +%Y%m%d)"
}

# `oras repo tags <image>` prints one tag per line. $1 is that listing, $2 the
# exit status -- a failing lookup is a case with its own required behaviour.
stub_oras() {
  local listing="$1" status="${2:-0}"
  {
    echo '#!/usr/bin/env bash'
    echo 'if [ "$1" = "repo" ]; then'
    echo "cat <<'TAGS'"
    printf '%s\n' "${listing}"
    echo 'TAGS'
    echo "exit ${status}"
    echo 'fi'
    echo 'exit 0'
  } > "${BIN}/oras"
  chmod +x "${BIN}/oras"
}

# The version goes to stdout and the commentary to stderr, and that split is
# itself part of the contract -- nightly.sh captures stdout and would embed any
# stray narration into the tag. Tests that assert the version therefore run with
# the streams separated, so a new stderr line can never make one pass or fail.
nv() {
  run --separate-stderr "${NV}" "$@"
}

# Every expectation below is built from the day the test computed at setup. A
# run that straddles UTC midnight would compare against the wrong prefix.
same_day() {
  [ "${DAY}" = "$(date -u +%Y%m%d)" ] || skip "the run crossed UTC midnight"
}

# A registry holding both series plus the floating tags, another day and
# another Fedora release -- everything that must NOT be counted.
mixed_tags() {
  printf '%s\n' latest 44 "44.${DAY}.0" "44.${DAY}.7" "44.${DAY}.3-dev" \
    44.20260101.9 "45.${DAY}.4"
}

@test "scheduled counts only its own series and takes max+1" {
  stub_oras "$(mixed_tags)"
  nv ghcr.io/example/pulsar
  same_day
  [ "$status" -eq 0 ]
  [ "$output" = "44.${DAY}.8" ]
}

@test "manual counts its own series and increments" {
  # The regression test for the arithmetic: extracting "3-dev" and handing it
  # to $((n + 1)) dies with "dev: unbound variable" under set -u, and silently
  # evaluates to 3 without it -- which is the tag collision, again.
  stub_oras "$(mixed_tags)"
  nv --channel manual ghcr.io/example/pulsar
  same_day
  [ "$status" -eq 0 ]
  [ "$output" = "44.${DAY}.4-dev" ]
}

@test "the two series cannot collide" {
  stub_oras "$(mixed_tags)"
  nv ghcr.io/example/pulsar
  local scheduled="$output"
  nv --channel manual ghcr.io/example/pulsar
  local manual="$output"
  same_day
  [ "${scheduled}" != "${manual}" ]
  [[ "${scheduled}" =~ ^44\.[0-9]{8}\.[0-9]+$ ]]
  [[ "${manual}" =~ ^44\.[0-9]{8}\.[0-9]+-dev$ ]]
}

@test "manual starts at .0-dev rather than inheriting the scheduled number" {
  stub_oras "$(printf '%s\n' latest "44.${DAY}.0" "44.${DAY}.6")"
  nv --channel manual ghcr.io/example/pulsar
  same_day
  [ "$status" -eq 0 ]
  [ "$output" = "44.${DAY}.0-dev" ]
}

@test "a -dev tag does not raise the scheduled number" {
  stub_oras "$(printf '%s\n' "44.${DAY}.1" "44.${DAY}.9-dev")"
  nv ghcr.io/example/pulsar
  same_day
  [ "$output" = "44.${DAY}.2" ]
}

@test "a lookup that fails is fatal and prints no version" {
  # The invariant the header spends twenty lines on: the old .0 fallback here
  # is what let two runs claim one tag.
  stub_oras 'Error: unexpected status: 500 Internal Server Error' 1
  run "${NV}" ghcr.io/example/pulsar
  [ "$status" -eq 3 ]
  [[ "$output" == *"refusing to guess"* ]]
  [[ ! "$output" =~ ^44\. ]]
}

@test "a repository that does not exist yet is the one narrow exception" {
  stub_oras 'Error: ghcr.io/example/pulsar: NAME_UNKNOWN: repository not found' 1
  nv ghcr.io/example/pulsar
  same_day
  [ "$status" -eq 0 ]
  # Announced rather than assumed: the version on stdout, the reason on stderr.
  [ "$output" = "44.${DAY}.0" ]
  [[ "$stderr" == *"first build"* ]]
}

@test "an unknown channel is a config error, not a default" {
  stub_oras "$(mixed_tags)"
  run "${NV}" --channel nightly ghcr.io/example/pulsar
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown channel"* ]]
}

@test "PULSAR_CHANNEL is honoured with no flag" {
  stub_oras "$(mixed_tags)"
  PULSAR_CHANNEL=manual nv ghcr.io/example/pulsar
  same_day
  [ "$status" -eq 0 ]
  [ "$output" = "44.${DAY}.4-dev" ]
}

@test "--fedora selects the release and its own series" {
  stub_oras "$(mixed_tags)"
  nv --fedora 45 ghcr.io/example/pulsar
  same_day
  [ "$output" = "45.${DAY}.5" ]
}

@test "--help prints the whole header, examples included" {
  # It used to print a line range that the header had outgrown, so the last
  # sentence and both examples were missing.
  run "${NV}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--channel manual"* ]]
  [[ "$output" == *"Fedora's own shape"* ]]
}
