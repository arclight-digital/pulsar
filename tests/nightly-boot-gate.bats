#!/usr/bin/env bats
# The boot gate, nightly.sh's half.
#
# With PULSAR_GATE=1 a night pushes its version tags, describes itself STAGED
# (publish.sh --stage: SBOMs, changelog, the site commit on release/<version>,
# none of the moving pointers), prints `gate: pending <version>` and stops.
# The builder is deleted then. The build host boots each image on a throwaway
# VM and, when both pass, moves the floating tags, the R2 pointers and the
# site itself -- so none of those ever describe a build that was held back.
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
  # the outgoing :latest, as oras resolves it: the changelog's baseline
  export PREV=sha256:1111111111111111111111111111111111111111111111111111111111111111
  printf '#!/usr/bin/env bash\necho "${PREV}"\n' > "${BIN}/oras"; chmod +x "${BIN}/oras"
  # the healthcheck: a stub curl that records the ping
  printf '#!/usr/bin/env bash\necho "curl $*" >> "%s"\n' "${CALLS}" > "${BIN}/curl"; chmod +x "${BIN}/curl"
  export IMAGE=ghcr.io/arclight-digital/pulsar IMAGE_NVIDIA=ghcr.io/arclight-digital/pulsar-nvidia
  export PULSAR_CHANNEL=scheduled PULSAR_FORCE_BUILD=yes
  export PULSAR_SIGNER_URL=http://10.0.0.5:8443 PULSAR_SIGNER_TOKEN_FILE="${BATS_TEST_TMPDIR}/no-token" PULSAR_SIGNER_CA_FILE=/dev/null
  export PULSAR_BUILD_WORK="${BATS_TEST_TMPDIR}/work"; mkdir -p "${PULSAR_BUILD_WORK}"
}

night()   { run --separate-stderr "${TREE}/scripts/nightly.sh"; }
called()  { grep -E "$1" "${CALLS}"; }
not_called() {
  if grep -qE "$1" "${CALLS}"; then echo "unexpected call: $(grep -E "$1" "${CALLS}")" >&2; return 1; fi
}

@test "a gated night pushes version tags, stages its description, says it is pending, and stops" {
  PULSAR_GATE=1 PULSAR_HEALTHCHECK_URL=https://hc.example/x night
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  grep -qx "this build is ${VERSION}" <<<"$output"
  called '^build .*--push' | grep -q -- '--no-floating-tags'
  called '^publish ' | grep -q -- '--stage'
  called '^publish ' | grep -q -- "--prev-digest ${PREV}"
  not_called '^publish .*--no-promote'
  # pending is the LAST thing said: the builder is deleted when it appears,
  # so everything that needs the images has to be done by then
  [ "$(tail -1 <<<"$output")" = "gate: pending ${VERSION}" ]
  # the night is not done until the host releases it, and the host pings then
  not_called '^curl'
}

@test "a gated manual build stages too, so it can be promoted later" {
  PULSAR_CHANNEL=manual PULSAR_GATE=1 night
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  called '^build .*--push' | grep -q -- '--no-floating-tags'
  called '^publish ' | grep -q -- '--stage'
  not_called '^publish .*--no-promote'
  [ "$(tail -1 <<<"$output")" = "gate: pending ${VERSION}" ]
}

@test "a staged publish that fails is not pending" {
  FAIL_PUBLISH=1 PULSAR_GATE=1 night
  [ "$status" -ne 0 ]
  if grep -q '^gate: pending' <<<"$output"; then false; fi
}

@test "an ungated night is what it always was" {
  PULSAR_HEALTHCHECK_URL=https://hc.example/x night
  [ "$status" -eq 0 ]
  if grep -q '^gate: pending' <<<"$output"; then false; fi
  not_called '^build .*--no-floating-tags'
  called '^publish '
  not_called '^publish .*--stage'
  called '^curl'
}

@test "an ungated manual build describes itself without becoming the release" {
  PULSAR_CHANNEL=manual night
  [ "$status" -eq 0 ]
  called '^publish ' | grep -q -- '--no-promote'
  not_called '^publish .*--stage'
}

@test "--promote is gone: the build host releases a gated night" {
  run --separate-stderr "${TREE}/scripts/nightly.sh" --promote
  [ "$status" -eq 2 ]
  [ ! -s "${CALLS}" ]
}
