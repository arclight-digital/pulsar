#!/usr/bin/env bats
# The boot gate, nightly.sh's half.
#
# With PULSAR_GATE=1 a night pushes its version tags and stops, printing
# `gate: pending <version>` for the build host, which boots each image on a
# throwaway VM. When both pass, the host runs `nightly.sh --promote`, which
# moves :latest and describes the night -- changelog, SBOM baseline, site --
# so none of those ever describe a build that was held back.
#
# The harness is nightly.sh from a copy of the tree, with build.sh,
# publish.sh, next-version.sh and check.sh as stubs that write down how they
# were called. Stubs of the real thing are what is being asserted against: the
# order and the arguments are the contract.

bats_require_minimum_version 1.5.0

VERSION=44.20260927.0

setup() {
  for v in "${!PULSAR_@}"; do unset "${v}"; done
  unset REGISTRY_AUTH_FILE
  BIN="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${BIN}"; PATH="${BIN}:${PATH}"
  TREE="${BATS_TEST_TMPDIR}/tree"; mkdir -p "${TREE}/scripts"
  cp "${BATS_TEST_DIRNAME}/../scripts/nightly.sh" "${TREE}/scripts/"
  export CALLS="${BATS_TEST_TMPDIR}/calls"; : > "${CALLS}"
  for s in build publish check; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\nexit "${FAIL_%s:-0}"\n' \
      "$s" "${CALLS}" "$(echo "$s" | tr a-z A-Z)" > "${TREE}/scripts/${s}.sh"
  done
  printf '#!/usr/bin/env bash\necho %s\n' "${VERSION}" > "${TREE}/scripts/next-version.sh"
  chmod +x "${TREE}/scripts/"*.sh
  # (the signer token deliberately does not exist, so preflight skips the
  # signer rather than dialling one; build.sh is a stub and never needs it)
  # the outgoing :latest, as oras resolves it; a test changes it to prove
  # --promote uses the one recorded before the build, not the one now
  export PREV=sha256:1111111111111111111111111111111111111111111111111111111111111111
  printf '#!/usr/bin/env bash\necho "${PREV}"\n' > "${BIN}/oras"; chmod +x "${BIN}/oras"
  export IMAGE=ghcr.io/arclight-digital/pulsar IMAGE_NVIDIA=ghcr.io/arclight-digital/pulsar-nvidia
  export PULSAR_CHANNEL=scheduled PULSAR_FORCE_BUILD=yes
  export PULSAR_SIGNER_URL=http://10.0.0.5:8443 PULSAR_SIGNER_TOKEN_FILE="${BATS_TEST_TMPDIR}/no-token" PULSAR_SIGNER_CA_FILE=/dev/null
  export PULSAR_BUILD_WORK="${BATS_TEST_TMPDIR}/work"; mkdir -p "${PULSAR_BUILD_WORK}"
  PENDING="${PULSAR_BUILD_WORK}/gate-pending.json"
}

night()   { run --separate-stderr "${TREE}/scripts/nightly.sh"; }
promote() { run --separate-stderr "${TREE}/scripts/nightly.sh" --promote; }
called()  { grep -E "$1" "${CALLS}"; }
not_called() {
  if grep -qE "$1" "${CALLS}"; then echo "unexpected call: $(grep -E "$1" "${CALLS}")" >&2; return 1; fi
}

@test "a gated night pushes version tags only, says it is pending, and stops" {
  PULSAR_GATE=1 night
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  grep -qx "gate: pending ${VERSION}" <<<"$output"
  grep -qx "this build is ${VERSION}" <<<"$output"
  called '^build .*--push' | grep -q -- '--no-floating-tags'
  not_called '^publish'
  [ "$(jq -r .version "${PENDING}")" = "${VERSION}" ]
  [ "$(jq -r .channel "${PENDING}")" = scheduled ]
  [ "$(jq -r .prev_digest "${PENDING}")" = "${PREV}" ]
}

@test "an ungated night is what it always was" {
  night
  [ "$status" -eq 0 ]
  if grep -q '^gate: pending' <<<"$output"; then false; fi
  not_called '^build .*--no-floating-tags'
  called '^publish'
  [ ! -e "${PENDING}" ]
}

@test "--promote finishes the gated night: promote, then describe against the recorded baseline" {
  PULSAR_GATE=1 night
  : > "${CALLS}"
  # :latest has not moved, but prove the baseline comes from the record
  PREV=sha256:2222222222222222222222222222222222222222222222222222222222222222
  promote
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  called '^build ' | grep -q -- "--promote-only .*--version ${VERSION}"
  not_called '^build .*--no-floating-tags'
  not_called '^build .*--push'
  called '^publish ' | grep -q -- "--prev-digest sha256:1111"
  # promote before publish: the changelog describes what :latest now is
  [ "$(grep -n '^build ' "${CALLS}" | cut -d: -f1)" -lt "$(grep -n '^publish ' "${CALLS}" | cut -d: -f1)" ]
  [ ! -e "${PENDING}" ]
}

@test "--promote with nothing pending refuses, and builds nothing" {
  promote
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"nothing here is waiting on the boot gate"* ]]
  [ ! -s "${CALLS}" ]
}

@test "--promote refuses a record from the other channel" {
  PULSAR_GATE=1 night
  : > "${CALLS}"
  PULSAR_CHANNEL=manual promote
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"is a scheduled build; this is manual"* ]]
  [ ! -s "${CALLS}" ]
}

@test "a promotion that fails describes nothing and keeps the record" {
  PULSAR_GATE=1 night
  : > "${CALLS}"
  FAIL_BUILD=1 promote
  [ "$status" -ne 0 ]
  not_called '^publish'
  [ -e "${PENDING}" ]
}

@test "a gated manual build promotes nothing floating and describes itself as manual" {
  PULSAR_CHANNEL=manual PULSAR_GATE=1 night
  [ "$status" -eq 0 ]
  grep -qx "gate: pending ${VERSION}" <<<"$output"
  : > "${CALLS}"
  PULSAR_CHANNEL=manual promote
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  called '^build ' | grep -q -- '--promote-only.*--no-floating-tags'
  called '^publish ' | grep -q -- '--no-promote'
}
