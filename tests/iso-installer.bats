#!/usr/bin/env bats
# The weekly ISO is Pulsar's own live installer, published exactly where and
# how the Anaconda ISO was.
#
# build-iso.sh swaps only its build step by --kind (PULSAR_ISO_KIND); naming,
# checksum, sidecar, signature and upload are shared. These tests hold down
# the installer side of that seam: the default, what build-installer-iso.sh is
# handed, and that its ISO comes out under the names the site links to.
# iso-kickstart.bats holds the Anaconda side.
#
# Stubs on PATH as in iso-kickstart.bats, and a copy of build-iso.sh in a bare
# repo beside a stand-in build-installer-iso.sh, since build-iso.sh finds that
# script from its own location. No podman, no image-builder, no ISO.

bats_require_minimum_version 1.5.0

DIGEST='sha256:2222222222222222222222222222222222222222222222222222222222222222'
VERSION='44.20261004.0'

setup() {
  for v in "${!PULSAR_@}"; do unset "${v}"; done

  REAL="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  FAKE="${BATS_TEST_TMPDIR}/repo"
  BIN="${BATS_TEST_TMPDIR}/bin"
  WORK="${BATS_TEST_TMPDIR}/work"
  LOG="${BATS_TEST_TMPDIR}/calls"
  mkdir -p "${FAKE}/scripts" "${BIN}" "${WORK}"
  cp "${REAL}/scripts/build-iso.sh" "${FAKE}/scripts/"
  cp "${REAL}/iso-config.toml" "${FAKE}/"
  ISO="${FAKE}/scripts/build-iso.sh"
  PATH="${BIN}:${PATH}"

  # The stand-in records its argv and leaves an ISO named the way the real
  # one names it, so build-iso.sh's rename is exercised too.
  cat > "${FAKE}/scripts/build-installer-iso.sh" <<EOF
#!/usr/bin/env bash
printf 'installer %s\n' "\$*" >> "${LOG}"
out=""; variant=""
while [ \$# -gt 0 ]; do
  case "\$1" in --out) out=\$2 ;; --variant) variant=\$2 ;; esac
  shift
done
mkdir -p "\${out}"
echo live > "\${out}/pulsar-\${variant}-installer-${VERSION}.iso"
EOF
  chmod +x "${FAKE}/scripts/build-installer-iso.sh"

  cat > "${BIN}/id" <<EOF
#!/usr/bin/env bash
[ "\$1" = -u ] && { echo 0; exit 0; }
exec /usr/bin/id "\$@"
EOF
  cat > "${BIN}/podman" <<EOF
#!/usr/bin/env bash
printf 'podman %s\n' "\$*" >> "${LOG}"
case "\$1" in
  info) echo /var/lib/containers/storage ;;
  run) mkdir -p "${WORK}/iso/bootiso"; echo anaconda > "${WORK}/iso/bootiso/install.iso" ;;
esac
exit 0
EOF
  cat > "${BIN}/skopeo" <<EOF
#!/usr/bin/env bash
echo '{"Digest": "${DIGEST}", "Labels": {"org.opencontainers.image.version": "${VERSION}"}}'
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "${BIN}/cosign"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${BIN}/image-builder"
  chmod +x "${BIN}"/*
}

build() { # extra args...
  run -0 "${ISO}" --image ghcr.io/arclight-digital/pulsar --work "${WORK}" --keyless "$@"
}

@test "the live installer is the default, and bib never runs" {
  build --variant vanilla
  grep -q '^installer ' "${LOG}"
  ! grep -q '^podman run' "${LOG}"
  [[ "${output}" == *"ISO for ${VERSION} (${DIGEST}, installer)"* ]]
}

@test "the installer is built from the resolved digest, tagged, and installs follow the tag" {
  build --variant vanilla
  grep -Fxq "podman pull --retry 5 ghcr.io/arclight-digital/pulsar@${DIGEST}" "${LOG}"
  grep -Fxq "podman tag ghcr.io/arclight-digital/pulsar@${DIGEST} ghcr.io/arclight-digital/pulsar:latest" "${LOG}"
  # The tag before the build, or the build would pull whatever :latest is now.
  [ "$(grep -n '^podman tag' "${LOG}" | cut -d: -f1)" -lt "$(grep -n '^installer' "${LOG}" | cut -d: -f1)" ]
  grep -Fxq "installer --variant vanilla --image ghcr.io/arclight-digital/pulsar:latest --target ghcr.io/arclight-digital/pulsar:latest --out ${WORK}/iso" "${LOG}"
}

@test "--track sets what installs follow" {
  build --variant vanilla --track testing
  grep -Fq -- "--target ghcr.io/arclight-digital/pulsar:testing" "${LOG}"
}

@test "the ISO lands under the name the site links to, with its sidecars" {
  build --variant vanilla
  local name="pulsar-${VERSION}-x86_64.iso"
  [ -f "${WORK}/iso/${name}" ]
  [ "$(cat "${WORK}/iso/${name}")" = live ]
  [ ! -e "${WORK}/iso/pulsar-vanilla-installer-${VERSION}.iso" ]
  (cd "${WORK}/iso" && sha256sum -c "${name}.sha256")
  [ "$(jq -r .installer "${WORK}/iso/${name}.json")" = installer ]
  [ "$(jq -r .digest "${WORK}/iso/${name}.json")" = "${DIGEST}" ]
  [ "$(jq -r .tracks "${WORK}/iso/${name}.json")" = ghcr.io/arclight-digital/pulsar:latest ]
}

@test "nvidia keeps its own name" {
  run -0 "${ISO}" --image ghcr.io/arclight-digital/pulsar-nvidia --work "${WORK}" --keyless --variant nvidia
  grep -Fq "installer --variant nvidia --image ghcr.io/arclight-digital/pulsar-nvidia:latest" "${LOG}"
  [ -f "${WORK}/iso/pulsar-nvidia-${VERSION}-x86_64.iso" ]
}

@test "PULSAR_ISO_KIND=anaconda falls back to bib, and the installer never runs" {
  PULSAR_ISO_KIND=anaconda build --variant vanilla
  grep -q '^podman run .*--type anaconda-iso' "${LOG}"
  ! grep -q '^installer ' "${LOG}"
  [ -f "${WORK}/iso/pulsar-${VERSION}-x86_64.iso" ]
  [ "$(jq -r .installer "${WORK}/iso/pulsar-${VERSION}-x86_64.iso.json")" = anaconda ]
}

@test "an unknown kind stops before anything is pulled" {
  run -2 "${ISO}" --image ghcr.io/arclight-digital/pulsar --work "${WORK}" --keyless --variant vanilla --kind live
  [[ "${output}" == *"installer or anaconda"* ]]
  [ ! -e "${LOG}" ]
}

@test "the installer kind refuses to start without image-builder" {
  rm "${BIN}/image-builder"
  # The real one, if this host has it, must not count.
  PATH="${BIN}:/usr/bin:/bin"
  command -v image-builder >/dev/null && skip "image-builder is installed on this host"
  run -2 "${ISO}" --image ghcr.io/arclight-digital/pulsar --work "${WORK}" --keyless --variant vanilla
  [[ "${output}" == *"missing: image-builder"* ]]
  [ ! -e "${LOG}" ]
}

# ---------------------------------------------------------------------------
# Nothing on the live ISO installs by itself. The Anaconda ISOs before
# e2fbff7 erased every disk unasked; the live installer has no kickstart, and
# the only thing that can run the backend is the app, after a person has
# picked a disk and confirmed.
# ---------------------------------------------------------------------------

@test "the live ISO starts the app, and nothing else starts the install backend" {
  local refs
  # Every file in the live overlay and its Containerfile that names the
  # backend: the polkit action that binds it, and the Containerfile that
  # installs it. No unit, no autostart, no script.
  refs="$(grep -rl 'pulsar-install-system\|pulsar-install-disk' \
            "${REAL}/system_files.installer" "${REAL}/Containerfile.installer" | sort)"
  [ "${refs}" = "$(printf '%s\n' "${REAL}/Containerfile.installer" \
      "${REAL}/system_files.installer/usr/share/polkit-1/actions/digital.arclight.pulsar.install.policy" | sort)" ]
  # What starts on login is the GUI, with no arguments.
  grep -Fxq 'Exec=pulsar-installer' \
    "${REAL}/system_files.installer/etc/xdg/autostart/digital.arclight.Pulsar.Installer.desktop"
  # No kickstart anywhere in the live build.
  ! grep -rqiE 'kickstart|inst\.ks|clearpart|autopart' \
      "${REAL}/system_files.installer" "${REAL}/Containerfile.installer" "${REAL}/scripts/build-installer-iso.sh"
}
