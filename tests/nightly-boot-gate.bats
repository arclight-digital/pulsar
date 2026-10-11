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
  # and the handoff, which tells the builder it may leave, comes just before
  [ "$(tail -2 <<<"$output" | head -1)" = "gate: handoff ${VERSION}" ]
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

@test "a staged publish that fails is not pending, and hands nothing off" {
  FAIL_PUBLISH=1 PULSAR_GATE=1 night
  [ "$status" -ne 0 ]
  if grep -qE '^gate: (pending|handoff)' <<<"$output"; then false; fi
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
  PULSAR_CHANNEL=manual PULSAR_HEALTHCHECK_URL=https://hc.example/x night
  [ "$status" -eq 0 ]
  called '^publish ' | grep -q -- '--no-promote'
  not_called '^publish .*--stage'
  # the dead-man's switch watches the timer, not people
  not_called '^curl'
}

@test "an ungated night hands build.sh and publish.sh exactly what they need" {
  # Every argument, in order. A dropped --version builds an image that does
  # not know what it is; a dropped --work publishes from the wrong layouts.
  night
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$(called '^build ')" = "build --variant all --version ${VERSION} \
--image ghcr.io/arclight-digital/pulsar --image-nvidia ghcr.io/arclight-digital/pulsar-nvidia \
--signer-url http://10.0.0.5:8443 --signer-token-file ${BATS_TEST_TMPDIR}/no-token --signer-ca-file /dev/null \
--work ${PULSAR_BUILD_WORK} --push" ]
  [ "$(called '^publish ')" = "publish --version ${VERSION} \
--image ghcr.io/arclight-digital/pulsar --image-nvidia ghcr.io/arclight-digital/pulsar-nvidia \
--prev-digest ${PREV} --work ${PULSAR_BUILD_WORK} --branch main \
--site-repo https://github.com/arclight-digital/pulsar-site.git" ]
}

@test "a failing check.sh builds nothing" {
  # Lint and tests are the only gate left since the repo left hosted CI.
  FAIL_CHECK=1 night
  [ "$status" -ne 0 ]
  called '^check'
  not_called '^(build|publish) '
  [[ "$output" != *"this build is"* ]]
}

@test "a credential that fails the preflight builds nothing and takes no number" {
  # The signer, configured and not answering: the nvidia build would have
  # died on it twenty-five minutes in, after the vanilla half was pushed.
  echo sekrit-signer > "${PULSAR_SIGNER_TOKEN_FILE}"
  printf '#!/usr/bin/env bash\necho "curl $*" >> "%s"\nexit 22\n' "${CALLS}" > "${BIN}/curl"
  printf '#!/usr/bin/env bash\necho next-version >> "%s"\necho %s\n' "${CALLS}" "${VERSION}" \
    > "${TREE}/scripts/next-version.sh"
  night
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"preflight failed"* ]]
  called '^curl .*/cert'
  not_called '^(next-version|build |publish )'
}

@test "IMAGE and IMAGE_NVIDIA are required before anything runs" {
  unset IMAGE_NVIDIA
  night
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"IMAGE_NVIDIA is not set"* ]]
  unset IMAGE
  night
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"IMAGE is not set"* ]]
  [ ! -s "${CALLS}" ]
}

@test "with no \$HOME the night takes it from the passwd entry, and hands it on" {
  # cloud-init runs this as root with no $HOME, and oras -- which answers the
  # version lookup -- hard-fails without one.
  printf '#!/usr/bin/env bash\necho "next-version HOME=${HOME:-<unset>}" >> "%s"\necho %s\n' \
    "${CALLS}" "${VERSION}" > "${TREE}/scripts/next-version.sh"
  run --separate-stderr env -u HOME "${TREE}/scripts/nightly.sh"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  called '^next-version ' | grep -qx "next-version HOME=$(getent passwd "$(id -u)" | cut -d: -f6)"
}

@test "with no \$HOME and no passwd entry the night stops before anything runs, and says why" {
  # getent's answer for a key it does not have: nothing, and exit 2. Under
  # pipefail that exit used to end the night on the assignment itself, in
  # silence, so the message below was never printed for the case it names.
  printf '#!/usr/bin/env bash\nexit 2\n' > "${BIN}/getent"; chmod +x "${BIN}/getent"
  run --separate-stderr env -u HOME "${TREE}/scripts/nightly.sh"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"no \$HOME and no passwd entry for uid $(id -u)"* ]]
  [ ! -s "${CALLS}" ]
}

# The tree as a git repository, one commit deep, for what the night says
# about the commit it builds.
tree_repo() {
  git -C "${TREE}" init -q
  git -C "${TREE}" add -A
  git -C "${TREE}" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "the tree under test"
}

@test "the night names the commit it builds, wherever it was started from" {
  tree_repo
  cd "${BATS_TEST_TMPDIR}"
  night
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  grep -qx "building $(git -C "${TREE}" rev-parse --short HEAD): the tree under test" <<<"$output"
}

@test "a manual build from a dirty tree says the commit does not describe the image" {
  tree_repo
  PULSAR_CHANNEL=manual night
  [[ "$stderr" != *"worktree is dirty"* ]]
  echo "# an edit" >> "${TREE}/scripts/check.sh"
  cd "${BATS_TEST_TMPDIR}"
  PULSAR_CHANNEL=manual night
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"WARNING: the worktree is dirty, so the commit above does not describe"* ]]
}

@test "build.sh is handed the add-on hash the gate compared, to record on the image" {
  # dnf5 as the add-on repos, every package answering
  cat > "${BIN}/dnf5" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'akmod-nvidia-open 3:615.71.09-1.fc44' 'ffmpeg 8.1.3-1.fc44' \
  'mesa-va-drivers-freeworld 26.2.3-1.fc44' 'mise 2026.9.14-1' 'nvidia-container-toolkit-base 1.20.1-1' \
  'nvidia-settings 3:615.71.09-1.fc44' 'scx-scheds 1.1.3-3.fc44' 'xorg-x11-drv-nvidia 3:615.71.09-3.fc44'
EOF
  chmod +x "${BIN}/dnf5"
  printf '#!/usr/bin/env bash\necho "build PULSAR_ADDONS_HASH=${PULSAR_ADDONS_HASH:-}" >> "%s"\n' \
    "${CALLS}" > "${TREE}/scripts/build.sh"
  local want; want="$(sha256sum <<<"$("${BIN}/dnf5" | sort -u)" | cut -d' ' -f1)"
  night
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$(called '^build ')" = "build PULSAR_ADDONS_HASH=${want}" ]
}

@test "the night's tokens are off the disk before the build starts, and its scratch after it ends" {
  export TMPDIR="${BATS_TEST_TMPDIR}/tmp"; mkdir -p "${TMPDIR}"
  export PULSAR_GIT_TOKEN_FILE="${BATS_TEST_TMPDIR}/git.token"
  echo sekrit-git > "${PULSAR_GIT_TOKEN_FILE}"
  # build.sh runs for an hour; nothing holding a token may sit in /tmp for it
  printf '#!/usr/bin/env bash\necho "build $*" >> "%s"\nfind "%s" -type f >> "%s"\n' \
    "${CALLS}" "${TMPDIR}" "${BATS_TEST_TMPDIR}/during-build" > "${TREE}/scripts/build.sh"
  night
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  called '^curl .*api.github.com'
  [ -e "${BATS_TEST_TMPDIR}/during-build" ]
  if [ -s "${BATS_TEST_TMPDIR}/during-build" ]; then cat "${BATS_TEST_TMPDIR}/during-build"; false; fi
  [ -z "$(ls -A "${TMPDIR}")" ]
}

@test "a credential near its expiry rides along on the healthcheck ping" {
  # The ping that says tonight was fine also says what will stop being fine.
  export PULSAR_GIT_TOKEN_FILE="${BATS_TEST_TMPDIR}/git.token" PULSAR_HEALTHCHECK_URL=https://hc.example/x
  echo sekrit-git > "${PULSAR_GIT_TOKEN_FILE}"
  GH_EXPIRY="$(date -u -d '+5 days' '+%Y-%m-%d %H:%M:%S UTC')"; export GH_EXPIRY
  # curl as api.github.com (headers as preflight's tests serve them) and as
  # the healthcheck, whose request body is written down
  cat > "${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
out=/dev/null hdr=/dev/null url= data=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -D) hdr="$2"; shift ;;
    --data-binary) data="$2"; shift ;;
    -w|-H|--max-time|--retry|--cacert) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
case "${url}" in
  https://api.github.com/*)
    printf 'HTTP/2 200\r\ngithub-authentication-token-expiration: %s\r\n' "${GH_EXPIRY}" > "${hdr}"
    printf '{"permissions":{"push":true}}' > "${out}"
    printf 200 ;;
  *) printf 'ping %s %s\n' "${url}" "${data}" >> "${CALLS}" ;;
esac
EOF
  chmod +x "${BIN}/curl"
  night
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  called '^ping ' | grep -qE "^ping https://hc.example/x ${VERSION} ok in [0-9]+s -- WARNING: the site commit token expires in [0-9]+ days \(${GH_EXPIRY}\); renew it$"
}

@test "--promote is gone: the build host releases a gated night" {
  run --separate-stderr "${TREE}/scripts/nightly.sh" --promote
  [ "$status" -eq 2 ]
  [ ! -s "${CALLS}" ]
}
