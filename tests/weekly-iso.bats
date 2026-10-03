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
