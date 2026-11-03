#!/usr/bin/env bats
# sbom-changelog.sh: the package diff between two nightlies, from the SBOMs
# attached to the images. publish.sh runs it before every release, so a crash
# here holds the night's images back.
#
# 45.20261103.0 died here: diffed against a Fedora 44 build, nearly every
# package changed, and the diff went to jq as one command-line argument, past
# Linux's 128 KiB limit for one ("Argument list too long"). The big-diff test
# below is that night's shape.
#
# rpmdev-vercmp is a stub with the real one's exit codes (12 when the second
# version is newer, 11 when older), comparing only the number after the last
# dot, so thousands of comparisons run in a moment.

bats_require_minimum_version 1.5.0

setup() {
  DIFF="${BATS_TEST_DIRNAME}/../scripts/sbom-changelog.sh"
  BIN="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${BIN}"; PATH="${BIN}:${PATH}"
  cat > "${BIN}/rpmdev-vercmp" <<'EOF'
#!/bin/sh
a=${1##*.}; b=${2##*.}
[ "$a" = "$b" ] && exit 0
[ "$a" -lt "$b" ] && exit 12
exit 11
EOF
  chmod +x "${BIN}/rpmdev-vercmp"
  export GENERATED=2026-11-03T04:00:00Z
}

# sbom FILE NAME=VERSION... : a minimal SPDX document with those packages
sbom() {
  local out=$1; shift
  printf '%s\n' "$@" | jq -R -s '{spdxVersion: "SPDX-2.3",
    packages: (split("\n") | map(select(length > 0) | split("=") | {name: .[0], versionInfo: .[1]}))}' > "${out}"
}

@test "a small diff: added, removed, upgraded and downgraded, each where it belongs" {
  sbom "${BATS_TEST_TMPDIR}/old.json" bash=5.3-1.1 gone=1.0-1.1 up=2.0-1.1 down=3.0-1.5
  sbom "${BATS_TEST_TMPDIR}/new.json" bash=5.3-1.1 new=0.1-1.1 up=2.0-1.2 down=3.0-1.4

  run --separate-stderr "${DIFF}" "${BATS_TEST_TMPDIR}/old.json" "${BATS_TEST_TMPDIR}/new.json"
  [ "$status" -eq 0 ]
  jq -e '.generated == "2026-11-03T04:00:00Z"' <<<"$output"
  jq -e '.added == [{name: "new", version: "0.1-1.1"}]' <<<"$output"
  jq -e '.removed == [{name: "gone", version: "1.0-1.1"}]' <<<"$output"
  jq -e '.changed == [
    {name: "down", from: "3.0-1.5", to: "3.0-1.4", direction: "downgraded"},
    {name: "up", from: "2.0-1.1", to: "2.0-1.2", direction: "upgraded"}]' <<<"$output"
  jq -e '.summary == {added: 1, removed: 1, upgraded: 1, downgraded: 1, changed: 0}' <<<"$output"
}

@test "REGRESSION: a new Fedora release's diff, thousands of packages, is not one argument" {
  local n=4000 i
  {
    for ((i = 0; i < n; i++)); do printf 'package-with-a-long-enough-name-%04d=1.0.0-1.fc44.1\n' "$i"; done
  } > "${BATS_TEST_TMPDIR}/old.list"
  sed 's/fc44\.1$/fc45.2/' "${BATS_TEST_TMPDIR}/old.list" > "${BATS_TEST_TMPDIR}/new.list"
  mapfile -t old < "${BATS_TEST_TMPDIR}/old.list"
  mapfile -t new < "${BATS_TEST_TMPDIR}/new.list"
  sbom "${BATS_TEST_TMPDIR}/old.json" "${old[@]}"
  sbom "${BATS_TEST_TMPDIR}/new.json" "${new[@]}"

  run --separate-stderr "${DIFF}" "${BATS_TEST_TMPDIR}/old.json" "${BATS_TEST_TMPDIR}/new.json"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  # the diff really is past the per-argument limit, or this proves nothing
  [ "$(jq -c .changed <<<"$output" | wc -c)" -gt 131072 ]
  jq -e --argjson n "$n" '.summary == {added: 0, removed: 0, upgraded: $n, downgraded: 0, changed: 0}' <<<"$output"
  jq -e '.changed[0] == {name: "package-with-a-long-enough-name-0000",
    from: "1.0.0-1.fc44.1", to: "1.0.0-1.fc45.2", direction: "upgraded"}' <<<"$output"
}
