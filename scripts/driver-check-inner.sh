#!/usr/bin/env bash
# The half of scripts/driver-check.sh that runs inside the Fedora base image.
# Read that script first; this one is only meant to run where it puts it.
#
# What it does is what Containerfile.nvidia does up to the module build, minus
# the signing: install kernel-devel for the base's own kernel, take the
# akmod-nvidia-open rpmfusion ships today, apply rpmfusion's own patch and
# then each patch in patches/nvidia-open/series with fuzz 0 (rpm's %patch
# allows none), and compile the modules against that kernel.
#
# Prints what it checked and the answer, and exits:
#   0  the modules build
#   1  they do not: a carried patch no longer applies, or the compile fails
#   2  could not tell: a package that would not install or download, which
#      is a mirror or a network, not the driver
#
# DRIVER_CHECK_PATCHES   the series directory (default /patches)
# DRIVER_CHECK_WORK      scratch (default /tmp/driver-check)
set -euo pipefail

PATCH_DIR="${DRIVER_CHECK_PATCHES:-/patches}"
W="${DRIVER_CHECK_WORK:-/tmp/driver-check}"

say()     { echo "driver-check: $*"; }
fail()    { say "$*"; exit 1; }
unknown() { say "could not tell: $*"; exit 2; }

[ -r "${PATCH_DIR}/series" ] || unknown "no series file in ${PATCH_DIR}"
mapfile -t PATCHES < <(grep -v '^[[:space:]]*\(#\|$\)' "${PATCH_DIR}/series")
for p in "${PATCHES[@]}"; do
  [ -r "${PATCH_DIR}/${p}" ] || unknown "series lists ${p}, which is not in ${PATCH_DIR}"
done

KV="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)" \
  || unknown "the base image has no kernel-core"
FV="$(rpm -E %fedora)"
say "base kernel ${KV}, Fedora ${FV}"

rm -rf "${W}"
mkdir -p "${W}/rpm" "${W}/akmod" "${W}/src"
# dnf's progress goes to a log; its last lines are printed when it fails.
dnf() {
  dnf5 "$@" >> "${W}/dnf.log" 2>&1 || { tail -n 15 "${W}/dnf.log"; return 1; }
}
dnf -y -q install --enablerepo=updates-archive "kernel-devel-${KV}" \
    gcc gcc-c++ elfutils-libelf-devel make patch cpio \
  || unknown "kernel-devel-${KV} or the compilers would not install"
dnf -y -q install \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FV}.noarch.rpm" \
  || unknown "rpmfusion-nonfree-release-${FV} would not install"
dnf -q download --enablerepo=rpmfusion-nonfree-nvidia-driver --destdir "${W}/rpm" akmod-nvidia-open \
  || unknown "akmod-nvidia-open would not download from rpmfusion"
akmod="$(find "${W}/rpm" -name 'akmod-nvidia-open-*.rpm' | head -n1)"
[ -n "${akmod}" ] || unknown "the akmod-nvidia-open download left no rpm"

( cd "${W}/akmod" && rpm2cpio "${akmod}" | cpio -idm --quiet ) \
  || unknown "could not unpack $(basename "${akmod}")"
srpm="$(find "${W}/akmod/usr/src/akmods" -name 'nvidia-open-kmod-*.src.rpm' | head -n1)"
[ -n "${srpm}" ] || unknown "$(basename "${akmod}") carries no nvidia-open-kmod src.rpm"
( cd "${W}/src" && rpm2cpio "${srpm}" | cpio -idm --quiet ) \
  || unknown "could not unpack $(basename "${srpm}")"

tarball="$(find "${W}/src" -maxdepth 1 -name 'open-gpu-kernel-modules-*.tar.gz' | head -n1)"
[ -n "${tarball}" ] || unknown "$(basename "${srpm}") has no open-gpu-kernel-modules tarball"
V="$(basename "${tarball}" .tar.gz)"
V="${V#open-gpu-kernel-modules-}"
say "nvidia-open ${V} from $(basename "${akmod}")"
tar -C "${W}/src" -xzf "${tarball}"
TREE="${W}/src/open-gpu-kernel-modules-${V}"
[ -d "${TREE}" ] || unknown "the tarball did not unpack to open-gpu-kernel-modules-${V}"

if [ -r "${W}/src/set_driver_defaults.patch" ]; then
  patch -s -F0 -p1 -d "${TREE}" < "${W}/src/set_driver_defaults.patch" \
    || fail "rpmfusion's own set_driver_defaults.patch does not apply to ${V}; the build will fail the same way"
fi
for p in "${PATCHES[@]}"; do
  patch -s -F0 -p1 -d "${TREE}" < "${PATCH_DIR}/${p}" \
    || fail "${p} no longer applies to nvidia-open ${V}. The comment above phase 2b in Containerfile.nvidia says when to drop it and when to rebase it."
done
say "${#PATCHES[@]} carried patch(es) apply: ${PATCHES[*]}"

if ! make -C "${TREE}" modules -j"$(nproc)" SYSSRC="/usr/src/kernels/${KV}" > "${W}/build.log" 2>&1; then
  say "the first errors:"
  grep -E -m 20 -A 3 'error:' "${W}/build.log" || tail -n 30 "${W}/build.log"
  fail "nvidia-open ${V} does NOT build against kernel ${KV}"
fi
[ -s "${TREE}/kernel-open/nvidia.ko" ] \
  || fail "make exited 0 against kernel ${KV} but left no kernel-open/nvidia.ko"
say "nvidia-open ${V} builds against kernel ${KV}"
