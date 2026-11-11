#!/usr/bin/env bats
# The morning driver check: does rpmfusion's nvidia-open, with every patch in
# patches/nvidia-open/series, compile against the base image's kernel?
#
# On 2026-11-11 the base moved to kernel 7.3.3 and nvidia-open 615.71.09 did
# not compile against it; a failed nightly was the first sign. These pin the
# check that finds that in the morning.
#
# The inner script runs here, not in a container. rpm, dnf5, rpm2cpio and
# make are stubs; patch, cpio and tar are real, against a small fixture tree,
# so fuzz, order and the series format are tested for what they do.

bats_require_minimum_version 1.5.0

KV=7.3.3-300.fc45.x86_64
V=615.71.09

setup() {
  REPO="${BATS_TEST_DIRNAME}/.."
  INNER="${REPO}/scripts/driver-check-inner.sh"
  OUTER="${REPO}/scripts/driver-check.sh"
  BIN="${BATS_TEST_TMPDIR}/bin"
  FIX="${BATS_TEST_TMPDIR}/fix"
  export DRIVER_CHECK_PATCHES="${BATS_TEST_TMPDIR}/patches"
  export DRIVER_CHECK_WORK="${BATS_TEST_TMPDIR}/work"
  export STUB_LOG="${BATS_TEST_TMPDIR}/stub.log" FIX KV
  mkdir -p "${BIN}" "${FIX}" "${DRIVER_CHECK_PATCHES}"
  : > "${STUB_LOG}"
  PATH="${BIN}:${PATH}"
  export MAKE_MODE=ok DNF_INSTALL_RC=0 DNF_DOWNLOAD_RC=0
  stub_tools
}

# The inner script's tests need the real patch and cpio. A bare build host may
# lack them; scripts/check.sh then runs this file again in a Fedora container
# that has them, and fails if they skip there too.
inner_setup() {
  local missing="" t
  for t in patch cpio; do command -v "${t}" >/dev/null || missing+=" ${t}"; done
  [ -z "${missing}" ] || skip "needs${missing}"
  make_fixture
}

# A driver tarball whose one file the patches below edit in turn, rpmfusion's
# patch first, then ours. Each patch's context is the line the one before it
# wrote, so a patch applied out of order does not apply.
make_fixture() {
  local t="${FIX}/tree/open-gpu-kernel-modules-${V}/kernel-open/nvidia"
  mkdir -p "${t}"
  printf '%s\n' one two three four five six seven eight nine > "${t}/os-interface.c"
  tar -C "${FIX}/tree" -czf "${FIX}/open-gpu-kernel-modules-${V}.tar.gz" "open-gpu-kernel-modules-${V}"

  mkdir -p "${FIX}/srpm"
  cp "${FIX}/open-gpu-kernel-modules-${V}.tar.gz" "${FIX}/srpm/"
  edit_patch four FOUR-rpmfusion > "${FIX}/srpm/set_driver_defaults.patch"
  echo 'Name: nvidia-open-kmod' > "${FIX}/srpm/nvidia-open-kmod.spec"
  ( cd "${FIX}/srpm" && find . -type f | cpio -o -H newc --quiet ) > "${FIX}/srpm.cpio"

  mkdir -p "${FIX}/akmod/usr/src/akmods"
  echo src.rpm > "${FIX}/akmod/usr/src/akmods/nvidia-open-kmod-${V}-1.fc45.src.rpm"
  ( cd "${FIX}/akmod" && find . -type f | cpio -o -H newc --quiet ) > "${FIX}/akmod.cpio"
  echo rpm > "${FIX}/akmod-nvidia-open-${V}-1.fc45.x86_64.rpm"

  # ours: a.diff needs rpmfusion's line, b.diff needs a.diff's.
  edit_patch FOUR-rpmfusion FOUR-a > "${DRIVER_CHECK_PATCHES}/a.diff"
  edit_patch FOUR-a FOUR-b > "${DRIVER_CHECK_PATCHES}/b.diff"
  printf '%s\n' '# carried patches' '' a.diff '   ' b.diff > "${DRIVER_CHECK_PATCHES}/series"
}

# A -p1 unified diff turning line 4 of os-interface.c from $1 into $2, with
# three lines of context either side.
edit_patch() {
  cat <<EOF
--- a/kernel-open/nvidia/os-interface.c
+++ b/kernel-open/nvidia/os-interface.c
@@ -1,7 +1,7 @@
 one
 two
 three
-$1
+$2
 five
 six
 seven
EOF
}

stub_tools() {
  cat > "${BIN}/rpm" <<'STUB'
#!/usr/bin/env bash
echo "rpm $*" >> "${STUB_LOG}"
case "$*" in
  *kernel-core*) echo "${KV}" ;;
  "-E %fedora")  echo 45 ;;
  *) exit 1 ;;
esac
STUB
  cat > "${BIN}/dnf5" <<'STUB'
#!/usr/bin/env bash
echo "dnf5 $*" >> "${STUB_LOG}"
case " $* " in
  *" install "*) exit "${DNF_INSTALL_RC}" ;;
  *" download "*)
    [ "${DNF_DOWNLOAD_RC}" = 0 ] || exit "${DNF_DOWNLOAD_RC}"
    dest=; while [ $# -gt 0 ]; do [ "$1" = --destdir ] && dest="$2"; shift; done
    cp "${FIX}"/akmod-nvidia-open-*.rpm "${dest}/" ;;
esac
STUB
  cat > "${BIN}/rpm2cpio" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  */akmod-nvidia-open-*.rpm)  cat "${FIX}/akmod.cpio" ;;
  */nvidia-open-kmod-*.src.rpm) cat "${FIX}/srpm.cpio" ;;
  *) exit 1 ;;
esac
STUB
  cat > "${BIN}/make" <<'STUB'
#!/usr/bin/env bash
echo "make $*" >> "${STUB_LOG}"
tree=; while [ $# -gt 0 ]; do [ "$1" = -C ] && tree="$2"; shift; done
case "${MAKE_MODE}" in
  ok)   mkdir -p "${tree}/kernel-open"; echo ko > "${tree}/kernel-open/nvidia.ko" ;;
  noko) ;;
  fail)
    echo "  CC [M]  nvidia/os-interface.o"
    echo "nvidia/os-interface.c:3031:48: error: passing argument 1 of 'dmem_cgroup_register_region' makes pointer from integer"
    echo "make[1]: *** [Makefile:115: modules] Error 2"
    exit 2 ;;
esac
STUB
  chmod +x "${BIN}"/*
}

tree_line4() {
  sed -n 4p "${DRIVER_CHECK_WORK}/src/open-gpu-kernel-modules-${V}/kernel-open/nvidia/os-interface.c"
}

# --- the inner script: what it builds and what it says ---------------------

@test "it builds: rpmfusion's patch, then the series in order, against the base's own kernel" {
  inner_setup
  run "${INNER}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"base kernel ${KV}, Fedora 45"* ]]
  [[ "${output}" == *"nvidia-open ${V} from akmod-nvidia-open-${V}-1.fc45.x86_64.rpm"* ]]
  [[ "${output}" == *"2 carried patch(es) apply: a.diff b.diff"* ]]
  [[ "${output}" == *"nvidia-open ${V} builds against kernel ${KV}"* ]]
  [ "$(tree_line4)" = FOUR-b ]
  grep -qx "dnf5 -y -q install --enablerepo=updates-archive kernel-devel-${KV} gcc gcc-c++ elfutils-libelf-devel make patch cpio" "${STUB_LOG}"
  grep -q -- "--enablerepo=rpmfusion-nonfree-nvidia-driver .*akmod-nvidia-open" "${STUB_LOG}"
  grep -q "^make -C .*/open-gpu-kernel-modules-${V} modules -j[0-9]* SYSSRC=/usr/src/kernels/${KV}$" "${STUB_LOG}"
}

@test "a compile that fails is a 1, with the compiler's own error and the kernel it failed on" {
  inner_setup
  MAKE_MODE=fail run "${INNER}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"error: passing argument 1 of 'dmem_cgroup_register_region'"* ]]
  [[ "${output}" == *"nvidia-open ${V} does NOT build against kernel ${KV}"* ]]
  [[ "${output}" != *"builds against kernel"* ]]
}

@test "make that exits 0 with no nvidia.ko is not a build" {
  inner_setup
  MAKE_MODE=noko run "${INNER}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"left no kernel-open/nvidia.ko"* ]]
}

@test "a carried patch that no longer applies is a 1 that names it and phase 2b, and nothing compiles" {
  inner_setup
  edit_patch FOUR-zzz FOUR-a > "${DRIVER_CHECK_PATCHES}/a.diff"
  run "${INNER}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"a.diff no longer applies to nvidia-open ${V}"* ]]
  [[ "${output}" == *"phase 2b"* ]]
  ! grep -q '^make ' "${STUB_LOG}" || false
}

@test "fuzz 0, as rpm's %patch: a patch whose outer context moved does not apply" {
  inner_setup
  # Line 1's context is wrong: plain patch would apply this with fuzz 1.
  edit_patch FOUR-rpmfusion FOUR-a | sed 's/^ one$/ ONE/' > "${DRIVER_CHECK_PATCHES}/a.diff"
  run "${INNER}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"a.diff no longer applies"* ]]
}

@test "the series order is the order applied: swapped, b.diff finds nothing to patch" {
  inner_setup
  printf '%s\n' b.diff a.diff > "${DRIVER_CHECK_PATCHES}/series"
  run "${INNER}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"b.diff no longer applies"* ]]
}

@test "rpmfusion's own patch goes first, and failing it says so, not that ours broke" {
  inner_setup
  edit_patch nope FOUR-rpmfusion > "${FIX}/srpm/set_driver_defaults.patch"
  ( cd "${FIX}/srpm" && find . -type f | cpio -o -H newc --quiet ) > "${FIX}/srpm.cpio"
  run "${INNER}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"set_driver_defaults.patch does not apply"* ]]
}

@test "a series naming a file that is not there is could-not-tell, before anything installs" {
  inner_setup
  printf '%s\n' a.diff missing.diff > "${DRIVER_CHECK_PATCHES}/series"
  run "${INNER}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"series lists missing.diff"* ]]
  ! grep -q '^dnf5 ' "${STUB_LOG}" || false
}

@test "a package that will not install or download is could-not-tell, not a broken driver" {
  inner_setup
  DNF_INSTALL_RC=1 run "${INNER}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"could not tell: kernel-devel-${KV}"* ]]
  : > "${STUB_LOG}"
  DNF_DOWNLOAD_RC=1 run "${INNER}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"could not tell: akmod-nvidia-open would not download"* ]]
  ! grep -q '^make ' "${STUB_LOG}" || false
}

# --- the outer script: the base, what goes in, what comes out --------------

stub_podman() {
  export PULL_RC="${1:-0}" RUN_RC="${2:-0}" GOT="${BATS_TEST_TMPDIR}/got"
  cat > "${BIN}/podman" <<'STUB'
#!/usr/bin/env bash
echo "podman $*" >> "${STUB_LOG}"
case "$1" in
  pull) exit "${PULL_RC}" ;;
  run)  mkdir -p "${GOT}" && tar -C "${GOT}" -xf - && exit "${RUN_RC}" ;;
esac
exit 99
STUB
  chmod +x "${BIN}/podman"
}

@test "outer: the base nightly.sh builds on, the repo's series, patches and inner script, and the answer" {
  stub_podman 0 0
  run "${OUTER}"
  [ "${status}" -eq 0 ]
  grep -qx "podman pull -q quay.io/fedora-ostree-desktops/silverblue:45" "${STUB_LOG}"
  grep -q "^podman run --rm -i --pull=never quay.io/fedora-ostree-desktops/silverblue:45 bash -c " "${STUB_LOG}"
  # every file, byte for byte, and nothing else
  sums() { ( cd "$1" && find . -type f ! -name .driver-check-inner.sh | sort | xargs sha256sum ); }
  [ "$(sums "${REPO}/patches/nvidia-open")" = "$(sums "${GOT}")" ]
  [ "$(sha256sum < "${REPO}/scripts/driver-check-inner.sh")" = "$(sha256sum < "${GOT}/.driver-check-inner.sh")" ]
}

@test "outer: --base and FEDORA_VERSION choose the base" {
  stub_podman 0 0
  FEDORA_VERSION=46 run "${OUTER}"
  grep -qx "podman pull -q quay.io/fedora-ostree-desktops/silverblue:46" "${STUB_LOG}"
  : > "${STUB_LOG}"
  run "${OUTER}" --base localhost/base:test
  grep -qx "podman pull -q localhost/base:test" "${STUB_LOG}"
}

@test "outer: the container's 1 and 2 come back as they are; anything else is could-not-tell" {
  stub_podman 0 1
  run "${OUTER}"
  [ "${status}" -eq 1 ]
  stub_podman 0 2
  run "${OUTER}"
  [ "${status}" -eq 2 ]
  stub_podman 0 125
  run "${OUTER}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"the container exited 125"* ]]
}

@test "outer: a base that will not pull is could-not-tell, and nothing runs" {
  stub_podman 1 0
  run "${OUTER}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"would not pull"* ]]
  ! grep -q '^podman run' "${STUB_LOG}" || false
}

@test "nightly.sh --driver-check is the driver check, with no channel work and its exit" {
  stub_podman 0 1
  IMAGE=x IMAGE_NVIDIA=y PULSAR_CHANNEL=scheduled run "${REPO}/scripts/nightly.sh" --driver-check
  [ "${status}" -eq 1 ]
  grep -q '^podman run' "${STUB_LOG}"
}
