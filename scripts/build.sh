#!/usr/bin/env bash
# Build Pulsar. The same way, everywhere.
#
# This used to be a convenience wrapper for local testing while CI carried the
# real pipeline inline, and the two drifted in ways that mattered: CI stamped a
# version and rendered wallpapers, this did not; CI rechunked and verified,
# this had no path to either. The rechunk half was where every recent bug
# lived, and it was the half with no local path -- so each question cost a
# 30-minute CI round trip, and during a GitHub Actions incident could not be
# asked at all.
#
# So the pipeline lives here now and CI calls it. A build on a workstation, on
# a build host, and on a runner run the same code; what differs is only which
# flags get passed and which credentials exist.
#
#   ./scripts/build.sh                          both variants, no rechunk
#   ./scripts/build.sh --verify vanilla         rechunk + assert, no push
#   ./scripts/build.sh --version 44.20260806.3 --verify --push
#
# Options:
#   --variant V         vanilla | nvidia | all            (default: all)
#   --version TAG       stamp os-release and the version label. Required to
#                       push: an unstamped image cannot be verified, because
#                       the assertion works by reading the stamp back out.
#   --rechunk           re-slice into package-grouped layers
#   --verify            assert content and metadata after the rechunk; implies
#                       --rechunk, because there is nothing to assert without
#                       one
#   --push              push to the registry (implies --verify: nothing ships
#                       without having been checked)
#   --image NAME        vanilla image name    (default: localhost/pulsar)
#   --image-nvidia NAME nvidia image name     (default: localhost/pulsar-nvidia)
#   --signer-url URL    signing oracle, required for nvidia
#   --signer-token-file PATH
#   --signer-ca-file PATH
#                       the signer's TLS certificate. Required when the URL is
#                       https: it is self-signed on a VPC address, and the
#                       build container's CA bundle has never heard of it.
#   --work DIR          where OCI layouts go; needs several GB
#   --no-wallpapers     skip the shader render (they are gitignored 4K PNGs,
#                       so skipping means the image ships without them)
#   --allow-existing-version
#                       publish a version tag the guard would not clear. The
#                       push refuses by default, because that tag is the one
#                       thing here that promises not to move. Two cases want
#                       this flag, both human-initiated and neither of them
#                       the nightly: a deliberate replacement, and the FIRST
#                       push of a brand-new image name, which ghcr.io reports
#                       as 403 rather than 404 -- indistinguishable from a
#                       credential that has gone stale.
#
# The nvidia variant no longer needs root or a local key: the signing key
# lives on the signer host and this only needs a token. See
# scripts/sign-file-oracle.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEDORA_VERSION="${FEDORA_VERSION:-44}"

VARIANT=all
VERSION=""
DO_RECHUNK=no
DO_VERIFY=no
DO_PUSH=no
DO_WALLPAPERS=yes
ALLOW_EXISTING_VERSION=no
IMAGE="${IMAGE:-localhost/pulsar}"
IMAGE_NVIDIA="${IMAGE_NVIDIA:-localhost/pulsar-nvidia}"
SIGNER_URL="${PULSAR_SIGNER_URL:-}"
SIGNER_TOKEN_FILE="${PULSAR_SIGNER_TOKEN_FILE:-}"
SIGNER_CA_FILE="${PULSAR_SIGNER_CA_FILE:-}"
WORK="${PULSAR_BUILD_WORK:-${XDG_CACHE_HOME:-${HOME}/.cache}/pulsar-build}"

while [ $# -gt 0 ]; do
  case "$1" in
    --variant)           VARIANT="${2:?}"; shift ;;
    --version)           VERSION="${2:?}"; shift ;;
    --rechunk)           DO_RECHUNK=yes ;;
    --verify)            DO_VERIFY=yes; DO_RECHUNK=yes ;;
    --push)              DO_PUSH=yes; DO_VERIFY=yes; DO_RECHUNK=yes ;;
    --image)             IMAGE="${2:?}"; shift ;;
    --image-nvidia)      IMAGE_NVIDIA="${2:?}"; shift ;;
    --signer-url)        SIGNER_URL="${2:?}"; shift ;;
    --signer-token-file) SIGNER_TOKEN_FILE="${2:?}"; shift ;;
    --signer-ca-file)    SIGNER_CA_FILE="${2:?}"; shift ;;
    --work)              WORK="${2:?}"; shift ;;
    --no-wallpapers)     DO_WALLPAPERS=no ;;
    --allow-existing-version) ALLOW_EXISTING_VERSION=yes ;;
    vanilla|nvidia|all)  VARIANT="$1" ;;
    -h|--help)           sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

case "${VARIANT}" in vanilla|nvidia|all) ;; *) echo "bad --variant" >&2; exit 2 ;; esac
if [ "${DO_PUSH}" = yes ] && [ -z "${VERSION}" ]; then
  echo "--push requires --version: the content assertion reads the stamp back" >&2
  exit 2
fi

for tool in podman skopeo jq tar; do
  command -v "${tool}" >/dev/null || { echo "missing: ${tool}" >&2; exit 2; }
done
mkdir -p "${WORK}"

# ---------------------------------------------------------------------------
# The store, as podman has it rather than as a constant. CI puts it on a big
# temp disk, a workstation leaves it under $HOME. The tool has to see the same
# store the build wrote to, which means the same absolute path AFTER symlink
# resolution -- the library resolves the configured graphroot and refuses a
# store whose database recorded something else. Inside an ostree image /mnt is
# a symlink to var/mnt, so a /mnt graphroot has to be mounted at /var/mnt to
# land back on what storage.conf declares.
# ---------------------------------------------------------------------------
GRAPHROOT="$(podman info --format '{{.Store.GraphRoot}}')"
RUNROOT="$(podman info --format '{{.Store.RunRoot}}')"
DRIVER="$(podman info --format '{{.Store.GraphDriverName}}')"
[ -n "${GRAPHROOT}" ] || { echo "cannot read the podman store" >&2; exit 2; }

resolve_mount() { case "$1" in /mnt/*) printf '/var%s' "$1" ;; *) printf '%s' "$1" ;; esac; }
GRAPHROOT_TARGET="$(resolve_mount "${GRAPHROOT}")"
WORK_TARGET="$(resolve_mount "${WORK}")"

STORAGE_CONF="${WORK}/storage.conf"
printf '[storage]\ndriver = "%s"\ngraphroot = "%s"\nrunroot = "%s"\n' \
  "${DRIVER}" "${GRAPHROOT}" "${RUNROOT}" > "${STORAGE_CONF}"

say() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Wallpapers are rendered from assets/shaders/pulsar.frag rather than
# committed -- they are 4K PNGs, fully reproducible from the shader, and
# gitignored. This has to happen BEFORE the build, because the Containerfile
# only COPYs system_files/ and the build container has no GL stack.
# ---------------------------------------------------------------------------
render_wallpapers() {
  [ "${DO_WALLPAPERS}" = yes ] || { echo "skipping wallpapers (--no-wallpapers)"; return 0; }
  if ! python3 -c 'import moderngl, numpy, PIL' 2>/dev/null; then
    echo "wallpaper render needs moderngl, numpy and pillow." >&2
    echo "install them, or pass --no-wallpapers to ship without them." >&2
    exit 2
  fi
  say "rendering wallpapers"
  python3 "${REPO}/scripts/render-wallpapers.py"
}

build_vanilla() {
  say "building ${IMAGE}:${FEDORA_VERSION}"
  # --pull=newer or this rebuilds the same bytes forever: podman's default
  # pull policy is "missing", so a cached silverblue:44 is reused and every
  # RUN then cache-hits. No new kernel, no security updates.
  local -a tags=(-t "${IMAGE}:${FEDORA_VERSION}" -t "${IMAGE}:latest")
  [ -n "${VERSION}" ] && tags+=(-t "${IMAGE}:${VERSION}")
  podman build --pull=newer \
    --file "${REPO}/Containerfile" \
    --build-arg FEDORA_VERSION="${FEDORA_VERSION}" \
    --build-arg PULSAR_VERSION="${VERSION}" \
    "${tags[@]}" \
    "${REPO}"
}

build_nvidia() {
  [ -n "${SIGNER_URL}" ] \
    || { echo "nvidia needs --signer-url: the kmod cannot be signed without it" >&2; exit 2; }
  if [ -z "${SIGNER_TOKEN_FILE}" ] || [ ! -r "${SIGNER_TOKEN_FILE}" ]; then
    echo "nvidia needs --signer-token-file pointing at a readable token" >&2
    exit 2
  fi

  # Checked HERE, not at the curl in phase 3. The signer's certificate is
  # self-signed on a VPC address and the build container carries the base
  # image's CA bundle, so an https signer with no cert to pin fails with
  # curl exit 60 -- roughly forty minutes in, after the kernel-devel fetch
  # and the akmod download. Two seconds is a better place to find out.
  case "${SIGNER_URL}" in
    https://*)
      if [ -z "${SIGNER_CA_FILE}" ] || [ ! -r "${SIGNER_CA_FILE}" ]; then
        echo "an https signer needs --signer-ca-file pointing at its TLS certificate;" >&2
        echo "it is self-signed, so no public CA vouches for it and the build" >&2
        echo "container cannot verify it without being handed the cert." >&2
        echo "(a plain-http test signer needs none)" >&2
        exit 2
      fi ;;
  esac
  podman image exists "${IMAGE}:${FEDORA_VERSION}" \
    || { echo "no ${IMAGE}:${FEDORA_VERSION}; build vanilla first" >&2; exit 2; }

  # Advisory only, and only meaningful on a machine that boots this image: a
  # cert that is not enrolled still builds, it just will not load at boot.
  if command -v mokutil >/dev/null && enrolled="$(mokutil --list-enrolled 2>/dev/null)"; then
    if [ -n "${enrolled}" ] && [ -r "${REPO}/system_files/etc/pki/pulsar/MOK.der" ]; then
      fp="$(openssl x509 -inform der -in "${REPO}/system_files/etc/pki/pulsar/MOK.der" \
              -noout -fingerprint -sha1 2>/dev/null | tr '[:upper:]' '[:lower:]' \
            | grep -oE '([0-9a-f]{2}:){19}[0-9a-f]{2}' || true)"
      if [ -n "${fp}" ] && ! grep -qiF "${fp}" <<<"${enrolled}"; then
        echo "NOTE: the shipped MOK.der is not enrolled here; the module will" >&2
        echo "      build and sign, but will not load under Secure Boot." >&2
      fi
    fi
  fi

  say "building ${IMAGE_NVIDIA}:${FEDORA_VERSION}"
  local -a tags=(-t "${IMAGE_NVIDIA}:${FEDORA_VERSION}" -t "${IMAGE_NVIDIA}:latest")
  [ -n "${VERSION}" ] && tags+=(-t "${IMAGE_NVIDIA}:${VERSION}")

  # The CA is always mounted, empty when there is none, so the Containerfile
  # tests one condition (is the file non-empty) rather than the build having
  # two shapes. It is a public certificate; the secret mount is only how a
  # host path gets in without joining the build context or a layer.
  local ca_src="${SIGNER_CA_FILE}"
  if [ -z "${ca_src}" ]; then ca_src="${WORK}/no-signer-ca"; : > "${ca_src}"; fi

  podman build \
    --file "${REPO}/Containerfile.nvidia" \
    --build-arg FEDORA_VERSION="${FEDORA_VERSION}" \
    --build-arg BASE_IMAGE="${IMAGE}" \
    --build-arg PULSAR_VERSION="${VERSION}" \
    --build-arg PULSAR_SIGNER_URL="${SIGNER_URL}" \
    --secret id=signer_token,src="${SIGNER_TOKEN_FILE}" \
    --secret id=signer_ca,src="${ca_src}" \
    "${tags[@]}" \
    "${REPO}"
}

# ---------------------------------------------------------------------------
# Rechunk. Without it every nightly costs clients ~2GB: podman build slices
# along Containerfile boundaries, --pull=newer moves the base most nights, and
# that cache-busts every derived layer. build-chunked-oci re-slices the FINAL
# filesystem into package-grouped chunks with stable boundaries, so identical
# content yields identical layers and a night where only the kernel moved
# costs roughly the kernel.
#
# --from names an image in containers-storage and takes NO transport prefix:
# the tool adds one itself, and writing it out double-prefixes into a parse
# error. When it cannot find the image there it pulls the name from a registry
# rather than failing -- which is why assert_content exists.
#
# The tool writes a plain OCI directory rather than back into
# containers-storage: a host podman older than the tool image's containers
# libraries cannot see what the newer one wrote, and the digest lands but the
# tag does not.
# ---------------------------------------------------------------------------
rechunk() {
  local name="$1" image="$2" layout="${WORK}/$3"
  say "rechunking ${image}"

  rm -rf "${layout:?}"
  mkdir -p "${layout}/blobs/sha256"
  printf '{"imageLayoutVersion":"1.0.0"}' > "${layout}/oci-layout"
  printf '{"schemaVersion":2,"manifests":[]}' > "${layout}/index.json"

  local -a run=(
    podman run --rm --privileged
    -v "${GRAPHROOT}:${GRAPHROOT_TARGET}"
    -v "${WORK}:${WORK_TARGET}"
    -v "${STORAGE_CONF}:/etc/containers/storage.conf:ro"
    "${image}:${FEDORA_VERSION}"
    rpm-ostree compose build-chunked-oci --bootc --format-version 1
    --max-layers 200
    --from "${image}:${FEDORA_VERSION}"
    --output "oci:${WORK_TARGET}/$3:build"
  )
  [ -n "${VERSION}" ] && run+=(--label "org.opencontainers.image.version=${VERSION}")

  # --previous-build pins the layer plan to what clients already run. The
  # first chunked build has no previous, and a registry that does not answer
  # is not a build failure -- it costs one full download, once.
  "${run[@]}" --previous-build "docker://${image}:latest" \
    || { echo "no usable previous build; chunking from a fresh plan" >&2; "${run[@]}"; }

  jq -r '"chunked '"${name}"': \(.Layers | length) layers"' \
    <(skopeo inspect "oci:${layout}:build")
}

# ---------------------------------------------------------------------------
# The version LABEL proves nothing about the CONTENT: it is written here, onto
# whatever the tool read, so it matched even on nights --from was pulling the
# published image instead of this build. /usr/lib/os-release carries what the
# Containerfile baked in, so it is the source speaking for itself. Read out of
# the layout's own blobs, which are already on disk.
# ---------------------------------------------------------------------------
#
# Reading it back is not a plain tar extract. In a bootc chunked layer every
# file under /usr is a tar HARDLINK to the ostree object that holds the bytes:
#
#   hrw-r--r-- 0/0  0  usr/lib/os-release link to sysroot/ostree/repo/objects/20/bfc2...file
#
# The named entry is zero-length, so extracting the path yields nothing at all.
# The content lives at the object path, and tar requires a hardlink's target to
# appear earlier in the SAME archive -- so the object is always in the same
# blob, and resolving it costs no extra pass.
assert_content() {
  local name="$1" layout="${WORK}/$2" osr="" b line
  [ -n "${VERSION}" ] || { echo "no --version; skipping the content assertion" >&2; return 0; }

  for b in "${layout}/blobs/sha256/"*; do
    line="$(tar -tvf "${b}" 2>/dev/null | grep -Em1 ' usr/lib/os-release( link to .*)?$' || true)"
    [ -n "${line}" ] || continue
    case "${line}" in
      # bootc/ostree: follow the hardlink to the object holding the bytes
      *' link to '*) osr="$(tar -xOf "${b}" "${line#* link to }" 2>/dev/null || true)" ;;
      # a plain layer, where the path is the content
      *)             osr="$(tar -xOf "${b}" --wildcards '*usr/lib/os-release' 2>/dev/null || true)" ;;
    esac
    [ -n "${osr}" ] && break
  done

  # "the check could not run" and "the image is wrong" are different failures
  # and must not share a message. Conflating them is how a broken assertion
  # reports itself as stale content and sends you looking at the rechunk.
  if [ -z "${osr}" ]; then
    echo "could not read /usr/lib/os-release out of the chunked ${name} layout." >&2
    echo "That is this CHECK failing rather than the image; nothing is pushed" >&2
    echo "either way, but fix the check, not the build." >&2
    exit 1
  fi
  if ! printf '%s' "${osr}" | grep -q "^VERSION=\"${VERSION}\""; then
    echo "chunked ${name} holds $(printf '%s' "${osr}" | grep '^VERSION=' || echo '<none>')," >&2
    echo "not ${VERSION} -- the rechunk did not read this build" >&2
    exit 1
  fi
  echo "chunked ${name} content confirmed: ${VERSION}"
}

# Is the version tag still free?
#
# 44 and latest are MEANT to move; the version tag is the one that promises it
# will not. That promise was broken on 2026-08-07: two runs computed the same
# tag and the second overwrote the first, which is only discoverable afterwards
# by noticing two deployments carrying one version string. The image someone
# already booted is then reachable only by a digest nobody wrote down.
#
# "Could not check" counts as NOT free. A guard that passes when it cannot see
# is the same silent fallback that caused this, one layer up.
version_tag_is_free() {
  local ref="$1" probe rc=0
  probe="$(skopeo inspect --raw "docker://${ref}" 2>&1)" || rc=$?
  if [ "${rc}" -eq 0 ]; then
    echo "${ref} already exists in the registry" >&2
    return 1
  fi
  printf '%s' "${probe}" \
    | grep -qiE 'manifest unknown|MANIFEST_UNKNOWN|NAME_UNKNOWN|repository name not known' \
    && return 0
  echo "could not tell whether ${ref} exists:" >&2
  printf '%s\n' "${probe}" >&2
  return 1
}

push() {
  local image="$1" layout="${WORK}/$2" t
  say "pushing ${image}"
  local -a tags=("${FEDORA_VERSION}" latest)
  # Checked before ANY tag is written: aborting after latest has already moved
  # would leave the registry advertising a build that was refused.
  if [ -n "${VERSION}" ]; then
    if [ "${ALLOW_EXISTING_VERSION}" = yes ]; then
      say "--allow-existing-version: not checking ${image}:${VERSION}"
    elif ! version_tag_is_free "${image}:${VERSION}"; then
      echo "refusing to publish ${image}:${VERSION}" >&2
      echo "re-run to get the next number, or pass --allow-existing-version" >&2
      echo "if replacing it is genuinely what you want" >&2
      exit 1
    fi
    tags+=("${VERSION}")
  fi
  # skopeo copies the already-compressed blobs verbatim; a podman pull/push
  # round trip recompressed ~200 layers for nothing. After the first copy the
  # registry holds every blob and the rest are manifest writes.
  for t in "${tags[@]}"; do
    skopeo copy --digestfile "${WORK}/digest-$2" \
      "oci:${layout}:build" "docker://${image}:${t}"
  done
  echo "${image} digest: $(cat "${WORK}/digest-$2")"
}

# one variant, all the way through
process() {
  local name="$1" image="$2" slot="$3"
  [ "${DO_RECHUNK}" = yes ] || return 0
  rechunk "${name}" "${image}" "${slot}"
  if [ "${DO_VERIFY}" = yes ]; then
    assert_content "${name}" "${slot}"
    say "checking modes and ownership across the ${name} rechunk"
    "${REPO}/scripts/diff-chunk-metadata.sh" "${image}:${FEDORA_VERSION}" "${WORK}/${slot}" build
  fi
  [ "${DO_PUSH}" = yes ] && push "${image}" "${slot}"
  return 0
}

render_wallpapers
if [ "${VARIANT}" = vanilla ] || [ "${VARIANT}" = all ]; then
  build_vanilla
  process vanilla "${IMAGE}" vanilla
fi
if [ "${VARIANT}" = nvidia ] || [ "${VARIANT}" = all ]; then
  build_nvidia
  process nvidia "${IMAGE_NVIDIA}" nvidia
fi

echo
echo "built:"
podman images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' \
  --filter reference="${IMAGE}*" --filter reference="${IMAGE_NVIDIA}*" | sort -u
if [ "${DO_PUSH}" != yes ]; then
  echo
  echo "Not pushed. To boot one of these locally:"
  echo "  bootc switch --transport containers-storage ${IMAGE_NVIDIA}:latest"
fi
