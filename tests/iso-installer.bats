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
  ! grep -q '^podman run' "${LOG}" || false
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
  ! grep -q '^installer ' "${LOG}" || false
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

@test "the ISO's boot menu is Pulsar's: no Fedora version, nothing it can't do, each entry boots the live system" {
  local yaml="${REAL}/system_files.installer/usr/lib/image-builder/bootc/iso.yaml"
  # image-builder's own menu said "Install Pulsar 44" (os-release's
  # VERSION_ID, which is Fedora's) and offered Anaconda's rescue mode
  [ "$(grep -cE '^    - name: ' "${yaml}")" -eq 3 ]
  grep -Fxq '    - name: "Install Pulsar"' "${yaml}"
  grep -E '^    - name: ' "${yaml}" | grep -qE '[0-9]|[Rr]escue' && false
  # every entry boots the live kernel with the live arguments, plus its own
  [ "$(grep -cE '^      linux: "\$\{kernelpath\} \$\{root\}' "${yaml}")" -eq 3 ]
  [ "$(grep -cE '^      initrd: "\$\{initrdpath\}"$' "${yaml}")" -eq 3 ]
}

# live_shell_check VERSION: Containerfile.installer's check of the live
# extension's shell-version, run as written against the repo's metadata.json,
# with `gnome-shell --version` answering VERSION
live_shell_check() {
  local ext=/usr/share/gnome-shell/extensions/pulsar-live@arclight.digital body
  body=$(awk '/^RUN EXT=\/usr\/share\/gnome-shell\/extensions\/pulsar-live@/ { on = 1 }
              on { print; if ($0 !~ /\\$/) exit }' "${REAL}/Containerfile.installer")
  [ -n "${body}" ] || { echo "no shell-version check in Containerfile.installer"; return 3; }
  body=${body#RUN }
  body=${body//"${ext}"/"${REAL}/system_files.installer${ext}"}
  printf '#!/usr/bin/env bash\necho "GNOME Shell %s"\n' "$1" > "${BIN}/gnome-shell"
  chmod +x "${BIN}/gnome-shell"
  bash -c "${body}"
}

@test "the live session's extension declares the Shell the image carries, and the build checks it" {
  # the same versions as the theme extension, which the main image's build
  # checks against its Shell and the theme gate runs on
  local live="${REAL}/system_files.installer/usr/share/gnome-shell/extensions/pulsar-live@arclight.digital/metadata.json"
  local theme="${REAL}/system_files/usr/share/gnome-shell/extensions/pulsar-theme@arclight.digital/metadata.json"
  [ "$(jq -c '."shell-version"' "${live}")" = "$(jq -c '."shell-version"' "${theme}")" ]
  run -0 live_shell_check 51.1
  run -0 live_shell_check 50.2
  run -1 live_shell_check 52.0
  [ "${lines[0]}" = "FATAL: the pulsar-live extension does not declare GNOME Shell 52" ]
}

# ---------------------------------------------------------------------------
# The host must know every SELinux type the image labels with: osbuild relabels
# the live tree on the host, and the kernel refuses a label whose type the
# host's loaded policy lacks. The 2026-10-18 weekly died on add-on module types
# (flatpak_helper_exec_t), the 2026-11-15 one on F45 base-policy types on an
# F44 builder (systemd_clonesetup_generator_exec_t). These run the real
# build-installer-iso.sh with podman, skopeo, setenforce and image-builder
# stubbed, and a fake selinuxfs: its context file is /dev/full for a policy
# that rejects every label, a plain file for one that takes them all.
# ---------------------------------------------------------------------------

policy_setup() { # enforce: 1 | 0 | none;  policy: knows | lacks
  local fs="${BATS_TEST_TMPDIR}/selinuxfs"
  mkdir -p "${fs}"
  case "$1" in none) ;; *) echo "$1" > "${fs}/enforce" ;; esac
  case "$2" in lacks) ln -sf /dev/full "${fs}/context" ;; knows) : > "${fs}/context" ;; esac
  export PULSAR_SELINUXFS="${fs}"
  # the installer image's file_contexts, with a context repeated
  cat > "${BIN}/podman" <<EOF
#!/usr/bin/env bash
printf 'podman %s\n' "\$*" >> "${LOG}"
case "\$1" in
  run) printf '/usr/bin/a\tsystem_u:object_r:bin_t:s0\n/usr/lib/systemd/system-generators/systemd-clonesetup-generator\t--\tsystem_u:object_r:systemd_clonesetup_generator_exec_t:s0\n/usr/bin/b\tsystem_u:object_r:bin_t:s0\n/dev/x\t<<none>>\n' ;;
  image) [ "\$2" = inspect ] && echo 1000 ;;
esac
exit 0
EOF
  cat > "${BIN}/setenforce" <<EOF
#!/usr/bin/env bash
printf 'setenforce %s\n' "\$*" >> "${LOG}"
EOF
  cat > "${BIN}/image-builder" <<EOF
#!/usr/bin/env bash
printf 'image-builder %s\n' "\$*" >> "${LOG}"
[ -z "\${IB_FAIL:-}" ] || exit 1
while [ \$# -gt 0 ]; do [ "\$1" = --output-dir ] && touch "\$2/out.iso"; shift; done
EOF
  chmod +x "${BIN}"/*
}

installer_build() { # expected status
  run "-$1" "${REAL}/scripts/build-installer-iso.sh" --out "${BATS_TEST_TMPDIR}/out"
}

@test "a tree without the installer app (or its backend) builds no ISO: no placeholder window stands in" {
  # the real script, in a bare repo with everything the build copies but one
  # piece of the installer; podman and the rest are setup()'s stubs
  local f repo="${BATS_TEST_TMPDIR}/bare"
  for f in pulsar-installer pulsar-install-system pulsar-install-disk; do
    rm -rf "${repo}"; mkdir -p "${repo}/scripts" "${repo}/system_files.installer" \
      "${repo}/system_files/usr/share/pulsar/installer/repart"
    cp "${REAL}/Containerfile.installer" "${repo}/"
    cp "${REAL}/scripts/build-installer-iso.sh" "${REAL}/scripts/pulsar-installer" \
      "${REAL}/scripts/pulsar-install-system" "${REAL}/scripts/pulsar-install-disk" "${repo}/scripts/"
    rm "${repo}/scripts/${f}"
    : > "${LOG}"
    run -1 "${repo}/scripts/build-installer-iso.sh" --out "${BATS_TEST_TMPDIR}/out"
    [ "${output}" = "scripts/${f} is missing: an ISO without it can't install Pulsar" ]
    # stopped before anything was pulled or built
    [ ! -s "${LOG}" ]
  done
}

@test "a host whose policy lacks the image's types is refused before image-builder, and told which" {
  policy_setup 1 lacks
  installer_build 1
  [[ "${output}" == *"lacks 2 type(s) the image labels with: bin_t systemd_clonesetup_generator_exec_t"* ]]
  [[ "${output}" == *"PULSAR_ISO_PERMISSIVE=1"* ]]
  ! grep -q '^image-builder' "${LOG}" || false
  ! grep -q '^setenforce' "${LOG}"
}

@test "PULSAR_ISO_PERMISSIVE=1: permissive for the whole image-builder run, enforcing again after" {
  policy_setup 1 lacks
  PULSAR_ISO_PERMISSIVE=1 installer_build 0
  [ "$(grep -E '^(setenforce|image-builder)' "${LOG}" | cut -d' ' -f1-2)" = "$(printf 'setenforce 0\nimage-builder build\nsetenforce 1')" ]
  [ -f "${BATS_TEST_TMPDIR}/out/pulsar-vanilla-installer-${VERSION}.iso" ]
}

@test "an image-builder that fails still leaves the host enforcing" {
  policy_setup 1 lacks
  IB_FAIL=1 PULSAR_ISO_PERMISSIVE=1 installer_build 1
  [ "$(grep '^setenforce' "${LOG}" | tail -1)" = "setenforce 1" ]
}

@test "the labels are read from the installer image, not the base" {
  policy_setup 1 lacks
  installer_build 1
  grep -q '^podman run --rm --pull=never .* localhost/pulsar-installer:build .*file_contexts' "${LOG}"
}

@test "a host that knows every type builds enforcing, whatever PULSAR_ISO_PERMISSIVE says" {
  policy_setup 1 knows
  PULSAR_ISO_PERMISSIVE=1 installer_build 0
  ! grep -q '^setenforce' "${LOG}" || false
  grep -q '^image-builder build ' "${LOG}"
}

@test "a host already permissive, or without SELinux, builds without checking or switching" {
  local e
  for e in 0 none; do
    : > "${LOG}"; rm -rf "${BATS_TEST_TMPDIR}/out"
    policy_setup "$e" lacks
    installer_build 0
    ! grep -q '^setenforce' "${LOG}" || false
    ! grep -q 'file_contexts' "${LOG}" || false
    grep -q '^image-builder build ' "${LOG}"
  done
}

@test "an installer image whose file_contexts can't be read stops the build" {
  policy_setup 1 knows
  sed -i 's/^  run) printf .*/  run) exit 1 ;;/' "${BIN}/podman"
  PULSAR_ISO_PERMISSIVE=1 installer_build 1
  [[ "${output}" == *"could not read the installer image's file_contexts"* ]]
  ! grep -q '^image-builder' "${LOG}"
}
