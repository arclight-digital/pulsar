#!/usr/bin/env bats
# What the weekly hands build-iso.sh, run end to end with every step faked:
# a copy of weekly.sh in a scratch repo whose check.sh and build-iso.sh only
# record that they ran. The real build-iso.sh is iso-installer.bats's and
# iso-kickstart.bats's to test.

bats_require_minimum_version 1.5.0

setup() {
  for v in "${!PULSAR_@}"; do unset "${v}"; done
  REAL="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  FAKE="${BATS_TEST_TMPDIR}/repo"
  BIN="${BATS_TEST_TMPDIR}/bin"
  LOG="${BATS_TEST_TMPDIR}/calls"
  mkdir -p "${FAKE}/scripts" "${BIN}"
  cp "${REAL}/scripts/weekly.sh" "${FAKE}/scripts/"
  printf '#!/usr/bin/env bash\necho check >> "%s"\n' "${LOG}" > "${FAKE}/scripts/check.sh"
  printf '#!/usr/bin/env bash\necho "build-iso $*" >> "%s"\n' "${LOG}" > "${FAKE}/scripts/build-iso.sh"
  chmod +x "${FAKE}/scripts/"*.sh
  git -C "${FAKE}" init -q
  git -C "${FAKE}" -c user.name=t -c user.email=t@t -c commit.gpgsign=false \
    commit -q --allow-empty -m fixture

  printf '#!/usr/bin/env bash\necho "podman $*" >> "%s"\n' "${LOG}" > "${BIN}/podman"
  # dnf "installs" image-builder by creating it, as the real one would.
  cat > "${BIN}/dnf" <<EOF
#!/usr/bin/env bash
echo "dnf \$*" >> "${LOG}"
printf '#!/usr/bin/env bash\nexit 0\n' > "${BIN}/image-builder"
chmod +x "${BIN}/image-builder"
EOF
  chmod +x "${BIN}"/*
  # Only the stubs and the system: an image-builder on this host must not
  # hide whether the weekly would have installed one.
  PATH="${BIN}:/usr/bin:/bin"
  command -v image-builder >/dev/null && skip "image-builder is installed on this host"

  export IMAGE=ghcr.io/arclight-digital/pulsar IMAGE_NVIDIA=ghcr.io/arclight-digital/pulsar-nvidia
  export PULSAR_SIGNER_URL=https://signer.invalid PULSAR_SIGNER_TOKEN_FILE=/dev/null
  export PULSAR_SIGNER_CA_FILE=/dev/null PULSAR_CHANNEL=scheduled
  export PULSAR_ISO_WORK="${BATS_TEST_TMPDIR}/work"
  export PULSAR_IMAGE_BUILDER_STORE="${BATS_TEST_TMPDIR}/ib-store"
}

@test "a scheduled week builds and publishes the live installer for both variants" {
  mkdir -p "${PULSAR_IMAGE_BUILDER_STORE}"
  run -0 "${FAKE}/scripts/weekly.sh"
  [ "$(sed -n 1p "${LOG}")" = check ]
  grep -Fxq "dnf install -y image-builder" "${LOG}"
  grep -q -- "^build-iso --kind installer --variant vanilla --image ghcr.io/arclight-digital/pulsar .*--push$" "${LOG}"
  grep -q -- "^build-iso --kind installer --variant nvidia --image ghcr.io/arclight-digital/pulsar-nvidia .*--push$" "${LOG}"
  # image-builder's store goes between variants, like bib's.
  [ ! -e "${PULSAR_IMAGE_BUILDER_STORE}" ]
}

@test "PULSAR_ISO_KIND=anaconda is the fallback, and installs nothing" {
  PULSAR_ISO_KIND=anaconda run -0 "${FAKE}/scripts/weekly.sh"
  ! grep -q '^dnf' "${LOG}"
  [ "$(grep -c -- '^build-iso --kind anaconda ' "${LOG}")" = 2 ]
}

@test "an unknown PULSAR_ISO_KIND builds nothing" {
  PULSAR_ISO_KIND=live run -2 "${FAKE}/scripts/weekly.sh"
  ! grep -q '^build-iso' "${LOG}"
}

@test "a manual week still publishes nothing" {
  PULSAR_CHANNEL=manual run -0 "${FAKE}/scripts/weekly.sh"
  [ "$(grep -c -- '^build-iso --kind installer ' "${LOG}")" = 2 ]
  ! grep -q -- '--push' "${LOG}"
}

@test "each variant is handed its own image, the work dir and the signer" {
  mkdir -p "${PULSAR_IMAGE_BUILDER_STORE}"
  run -0 "${FAKE}/scripts/weekly.sh"
  local tail="--work ${PULSAR_ISO_WORK} --signer-url https://signer.invalid --signer-token-file /dev/null --signer-ca-file /dev/null --push"
  [ "$(grep '^build-iso' "${LOG}")" = "build-iso --kind installer --variant vanilla --image ghcr.io/arclight-digital/pulsar ${tail}
build-iso --kind installer --variant nvidia --image ghcr.io/arclight-digital/pulsar-nvidia ${tail}" ]
}

@test "the disk is reclaimed after each variant, before the next one builds" {
  # The ISO droplet holds one variant's image, osbuild store and ISO at a
  # time, not two. build-iso.sh here notes what the last variant left behind.
  cat > "${FAKE}/scripts/build-iso.sh" <<STUB
#!/usr/bin/env bash
echo "build-iso \$*" >> "${LOG}"
for d in iso store; do [ ! -e "${PULSAR_ISO_WORK}/\${d}" ] || echo "left behind: \${d}" >> "${LOG}"; done
mkdir -p "${PULSAR_ISO_WORK}/iso" "${PULSAR_ISO_WORK}/store"
STUB
  run -0 "${FAKE}/scripts/weekly.sh"
  [ "$(grep -E '^(build-iso|podman|left behind)' "${LOG}" | sed -E 's/^(build-iso).*--variant ([a-z]+).*/\1 \2/')" = "build-iso vanilla
podman image prune --all --force
build-iso nvidia
podman image prune --all --force" ]
  [ ! -e "${PULSAR_ISO_WORK}/iso" ]
  [ ! -e "${PULSAR_ISO_WORK}/store" ]
}

@test "the week names the commit it builds, wherever it was started from" {
  cd "${BATS_TEST_TMPDIR}"
  run -0 "${FAKE}/scripts/weekly.sh"
  grep -qx "building from $(git -C "${FAKE}" rev-parse --short HEAD): fixture" <<<"$output"
}

@test "IMAGE and IMAGE_NVIDIA are required before anything runs" {
  unset IMAGE_NVIDIA
  run --separate-stderr "${FAKE}/scripts/weekly.sh"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"IMAGE_NVIDIA is not set"* ]]
  unset IMAGE
  run --separate-stderr "${FAKE}/scripts/weekly.sh"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"IMAGE is not set"* ]]
  [ ! -e "${LOG}" ]
}

@test "an unset or unknown channel builds nothing, and says what to set" {
  # Publishing an ISO is signing something; nothing may guess whether this
  # run is entitled to sign over what is already published.
  unset PULSAR_CHANNEL
  run --separate-stderr "${FAKE}/scripts/weekly.sh"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"set PULSAR_CHANNEL=scheduled|manual in /etc/pulsar/build.env."* ]]
  PULSAR_CHANNEL=weekly run --separate-stderr "${FAKE}/scripts/weekly.sh"
  [ "$status" -eq 2 ]
  [ "$stderr" = "PULSAR_CHANNEL=weekly is not scheduled or manual" ]
  [ ! -e "${LOG}" ]
}

@test "with no \$HOME the week takes it from the passwd entry, and hands it on" {
  # cloud-init sets none, and the aws CLI build-iso.sh publishes through
  # expands ~ for its config.
  printf '#!/usr/bin/env bash\necho "build-iso HOME=${HOME:-<unset>}" >> "%s"\n' "${LOG}" \
    > "${FAKE}/scripts/build-iso.sh"
  run --separate-stderr env -u HOME "${FAKE}/scripts/weekly.sh"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$(grep -c "^build-iso HOME=$(getent passwd "$(id -u)" | cut -d: -f6)\$" "${LOG}")" = 2 ]
}

@test "with no \$HOME and no passwd entry the week stops, and says why" {
  # getent for a key it does not have: nothing, and exit 2. Under pipefail
  # that exit used to end the run on the assignment, before the message.
  printf '#!/usr/bin/env bash\nexit 2\n' > "${BIN}/getent"; chmod +x "${BIN}/getent"
  run --separate-stderr env -u HOME "${FAKE}/scripts/weekly.sh"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"no \$HOME and no passwd entry for uid $(id -u)"* ]]
  [ ! -e "${LOG}" ]
}
