#!/usr/bin/env bash
# Build one installer ISO. The same way, everywhere.
#
# This is the pipeline the retired GitHub Actions iso workflow carried
# inline, moved here so the weekly build host and a workstation run the same
# code -- the same reasoning that moved the image pipeline into build.sh.
# What differs between callers is only flags and credentials.
#
#   sudo ./scripts/build-iso.sh --variant vanilla --image ghcr.io/arclight-digital/pulsar
#   sudo ./scripts/build-iso.sh --variant nvidia --image ... --push --keyless
#
# Options:
#   --variant V         vanilla | nvidia                    (required)
#   --image NAME        registry image to build from        (required)
#   --tag TAG           tag to resolve                      (default: latest)
#   --work DIR          scratch for /output, /store, /rpmmd; needs ~40GB
#   --push              upload ISO + sidecars to R2
#   --signer-url URL    signd, for the release-key signature on the manifest
#   --signer-token-file PATH
#   --signer-ca-file PATH
#   --keyless           sign with cosign keyless (Fulcio via ambient OIDC)
#                       instead of the signer -- an escape hatch for a run
#                       from CI-shaped infrastructure that cannot reach halo.
#                       Keyless runs publish DATED keys and never touch
#                       -latest, so such a run can never leave the site's
#                       verify instructions pointing at a
#                       certificate-signed file.
#
# The image is resolved to a DIGEST first and everything downstream uses it:
# the pull, the bib invocation, and the metadata sidecar. ":latest moved while
# the ISO was building" stops being a possible state, and the sidecar records
# exactly which image the installer installs.
#
# The version comes from the image's org.opencontainers.image.version label
# (stamped by build.sh), so the ISO inherits the collision-proof
# <fedora>.<date>.<n> serial instead of re-deriving a date that two same-day
# runs would collide on.
#
# Root, because bootc-image-builder runs a nested podman against this host's
# rootful store. And the store must live at the DEFAULT graphroot,
# /var/lib/containers/storage: podman records its static dir inside the
# database, so bib's nested podman refuses a relocated graphroot --
#   database static dir "/mnt/podman/libpod" does not match our static dir
#   "/var/lib/containers/storage/libpod"
# A host that wants the bytes elsewhere bind-mounts over the default path;
# it must NOT point storage.conf somewhere else. This is why the ISO droplet
# does not reuse the nightly's /var/mnt/podman relocation.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Pinned by digest, not :latest. The flag surface here is not stable -- the
# `--local` flag this pipeline was first written against no longer exists,
# because bib stopped pulling images itself and reads local storage only. A
# digest makes that kind of change a deliberate bump instead of a build that
# breaks on a morning nobody touched it.
BIB="${BIB:-quay.io/centos-bootc/bootc-image-builder@sha256:2b52843ea2bfda73b0a08d97e76b734393b1d3a804681b9fabb26723bd3a2f0b}"

# The image lineage declares no default root filesystem: /usr/lib/bootc/install
# is empty in fedora-silverblue, so bib exits with "no default root filesystem
# type specified in container". btrfs matches what Silverblue's own installer
# picks, so an ISO install lands on the same layout as a stock one.
ROOTFS="${ROOTFS:-btrfs}"

VARIANT=""
IMAGE=""
TAG=latest
WORK="${PULSAR_ISO_WORK:-/var/tmp/pulsar-iso}"
DO_PUSH=no
SIGNER_URL="${PULSAR_SIGNER_URL:-}"
SIGNER_TOKEN_FILE="${PULSAR_SIGNER_TOKEN_FILE:-}"
SIGNER_CA_FILE="${PULSAR_SIGNER_CA_FILE:-}"
KEYLESS=no

while [ $# -gt 0 ]; do
  case "$1" in
    --variant)           VARIANT="${2:?}"; shift ;;
    --image)             IMAGE="${2:?}"; shift ;;
    --tag)               TAG="${2:?}"; shift ;;
    --work)              WORK="${2:?}"; shift ;;
    --push)              DO_PUSH=yes ;;
    --signer-url)        SIGNER_URL="${2:?}"; shift ;;
    --signer-token-file) SIGNER_TOKEN_FILE="${2:?}"; shift ;;
    --signer-ca-file)    SIGNER_CA_FILE="${2:?}"; shift ;;
    --keyless)           KEYLESS=yes ;;
    -h|--help)           sed -n '2,47p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

case "${VARIANT}" in
  vanilla) ARTIFACT=pulsar ;;
  nvidia)  ARTIFACT=pulsar-nvidia ;;
  *) echo "--variant must be vanilla or nvidia" >&2; exit 2 ;;
esac
[ -n "${IMAGE}" ] || { echo "--image is required" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run as root: bib needs the rootful store" >&2; exit 2; }

if [ "${KEYLESS}" = no ] && { [ -z "${SIGNER_URL}" ] || [ -z "${SIGNER_TOKEN_FILE}" ]; }; then
  echo "no signer configured: pass --signer-url/--signer-token-file, or --keyless" >&2
  echo "an unsigned ISO is not a thing this pipeline produces" >&2
  exit 2
fi

for tool in podman skopeo jq sha256sum cosign; do
  command -v "${tool}" >/dev/null || { echo "missing: ${tool}" >&2; exit 2; }
done

PUBKEY="${REPO}/keys/cosign.pub"
if [ "${KEYLESS}" = no ] && [ ! -r "${PUBKEY}" ]; then
  echo "missing ${PUBKEY}: cannot verify what the signer returns" >&2
  exit 2
fi

# Not optional, and checked before anything expensive for the same reason the
# signer arguments are. Without a config, bib writes a kickstart that runs
# `clearpart --all` and `autopart` against every disk the installer can see --
# see iso-config.toml for the whole story. A missing file has to stop the build
# here rather than quietly produce that ISO a second time.
ISO_CONFIG="${REPO}/iso-config.toml"
if [ ! -r "${ISO_CONFIG}" ]; then
  echo "missing ${ISO_CONFIG}: without it bib builds an installer that" >&2
  echo "erases every attached disk without asking. refusing to build." >&2
  exit 2
fi

# See the header: a relocated graphroot is the one storage layout bib cannot
# use, and finding out from bib's nested podman mid-build is a worse error
# message than this one.
GRAPHROOT="$(podman info --format '{{.Store.GraphRoot}}')"
if [ "${GRAPHROOT}" != /var/lib/containers/storage ]; then
  echo "graphroot is ${GRAPHROOT}, not /var/lib/containers/storage" >&2
  echo "bib's nested podman refuses a relocated store; bind-mount instead" >&2
  exit 2
fi

mkdir -p "${WORK}/iso" "${WORK}/store" "${WORK}/rpmmd"

say() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Resolve, then forget the tag existed
# ---------------------------------------------------------------------------
say "resolving ${IMAGE}:${TAG}"
inspect="$(skopeo inspect "docker://${IMAGE}:${TAG}")"
DIGEST="$(jq -r '.Digest' <<<"${inspect}")"
VERSION="$(jq -r '.Labels["org.opencontainers.image.version"] // empty' <<<"${inspect}")"
[ -n "${DIGEST}" ] || { echo "cannot resolve ${IMAGE}:${TAG}" >&2; exit 1; }
if [ -z "${VERSION}" ]; then
  echo "${IMAGE}:${TAG} carries no org.opencontainers.image.version label" >&2
  echo "an ISO with no version cannot be named; build.sh stamps this on push" >&2
  exit 1
fi
say "building ${ARTIFACT} ISO for ${VERSION} (${DIGEST})"

podman pull --retry 5 "${IMAGE}@${DIGEST}"

# ---------------------------------------------------------------------------
# bootc-image-builder
#
# --privileged and the unconfined label are what upstream documents: the
# builder makes loopback devices and mounts filesystems to lay the ISO out,
# none of which works from a confined container. The storage mount is
# read-WRITE and has to be: bib runs a nested podman against this graphroot;
# mounted :ro it dies on `mkdir .../l: read-only file system` before it does
# any work. /store and /rpmmd are mounted for space, not correctness -- left
# unmounted they land in the container's overlay on the root disk.
#
# The config lands at /config.toml because bib picks its decoder off the file
# EXTENSION -- mounted under any other name it is parsed as JSON and the build
# dies on the first line. It is passed explicitly rather than relying on bib's
# "/config.json will be used if present" fallback, so that a mount that failed
# to land is a bib error about a missing file rather than a silent return to
# the unattended kickstart.
# ---------------------------------------------------------------------------
say "running bootc-image-builder"
podman run --rm --privileged \
  --security-opt label=type:unconfined_t \
  -v "${WORK}/iso:/output" \
  -v "${ISO_CONFIG}:/config.toml:ro" \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "${WORK}/store:/store" \
  -v "${WORK}/rpmmd:/rpmmd" \
  "${BIB}" \
    build \
    --type anaconda-iso \
    --config /config.toml \
    --rootfs "${ROOTFS}" \
    --progress verbose \
    "${IMAGE}@${DIGEST}"

src="$(find "${WORK}/iso" -name '*.iso' | head -1)"
[ -n "${src}" ] || { echo "no ISO was produced" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Name, checksum, describe
# ---------------------------------------------------------------------------
NAME="${ARTIFACT}-${VERSION}-x86_64.iso"
mv "${src}" "${WORK}/iso/${NAME}"
cd "${WORK}/iso"

# The checksum manifest is what a human verifies by hand; the signature on the
# manifest is what proves the manifest itself was not swapped. The signature
# covers the MANIFEST, not the ISO: signd caps its body in kilobytes, and a
# verified manifest checks the ISO's bytes transitively via sha256sum -c.
sha256sum "${NAME}" > "${NAME}.sha256"
ISO_SHA256="$(cut -d' ' -f1 "${NAME}.sha256")"

# Which image this installer installs, written down at the only moment it is
# knowable for free. The dated filename alone cannot answer it: the image was
# resolved from a tag that has since moved on.
jq -n \
  --arg variant "${ARTIFACT}" \
  --arg version "${VERSION}" \
  --arg image "${IMAGE}" \
  --arg digest "${DIGEST}" \
  --arg built "$(date -u -Iseconds)" \
  --arg iso_sha256 "${ISO_SHA256}" \
  '{variant: $variant, version: $version, image: $image, digest: $digest,
    built: $built, iso_sha256: $iso_sha256}' > "${NAME}.json"

# ---------------------------------------------------------------------------
# Sign the manifest
# ---------------------------------------------------------------------------
sign_manifest() { # <manifest-file> -> writes <manifest-file>.sig
  local f="$1"
  if [ "${KEYLESS}" = yes ]; then
    cosign sign-blob --yes \
      --output-signature "${f}.sig" \
      --output-certificate "${f}.pem" \
      "${f}"
    return
  fi

  # The release key lives on halo and stays there; this sends manifest bytes
  # and gets base64 back. Then the signature is verified against the COMMITTED
  # public key before anything is published -- if halo's key were ever swapped
  # this build fails here, the same fail-closed shape as the MOK.der check in
  # Containerfile.nvidia. --insecure-ignore-tlog because halo cannot reach
  # Rekor (its unit allows only VPC addresses); the trust anchor is the
  # committed key, not a transparency log.
  local curl_args=(-sS --fail-with-body -X POST --data-binary "@${f}"
    -H "Authorization: Bearer $(cat "${SIGNER_TOKEN_FILE}")"
    -H "X-Pulsar-Name: $(basename "${f}")")
  [ -n "${SIGNER_CA_FILE}" ] && curl_args+=(--cacert "${SIGNER_CA_FILE}")
  curl "${curl_args[@]}" "${SIGNER_URL}/sign-blob" \
    | jq -r '.signature // empty' > "${f}.sig"
  [ -s "${f}.sig" ] || { echo "signer returned no signature for ${f}" >&2; exit 1; }

  cosign verify-blob \
    --key "${PUBKEY}" \
    --signature "${f}.sig" \
    --insecure-ignore-tlog=true \
    "${f}" \
    || { echo "signature on ${f} does not verify against keys/cosign.pub" >&2
         echo "halo is signing with a key this repo has never heard of" >&2
         exit 1; }
}

say "signing ${NAME}.sha256"
sign_manifest "${NAME}.sha256"
cat "${NAME}.sha256"

# ---------------------------------------------------------------------------
# Publish
# ---------------------------------------------------------------------------
[ "${DO_PUSH}" = yes ] || { say "built ${WORK}/iso/${NAME} (no --push)"; exit 0; }

# Same idiom as publish.sh: credentials either in the environment or in a file
# the build host hands over, which spells them R2_* -- see publish.sh for why
# the mapping to AWS_* happens here and not in the file.
if [ -n "${R2_CREDENTIALS_FILE:-}" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  [ -r "${R2_CREDENTIALS_FILE}" ] || { echo "cannot read ${R2_CREDENTIALS_FILE}" >&2; exit 2; }
  set -a
  # shellcheck disable=SC1090
  . "${R2_CREDENTIALS_FILE}"
  set +a
  export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${R2_ACCESS_KEY_ID:-}}"
  export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-${R2_SECRET_ACCESS_KEY:-}}"
fi
R2_ENDPOINT="${R2_ENDPOINT:-${R2_ACCOUNT_ID:+https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com}}"
if [ -z "${R2_ENDPOINT}" ] || [ -z "${R2_BUCKET:-}" ] || [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  echo "--push needs R2_BUCKET, R2_ENDPOINT (or R2_ACCOUNT_ID), and credentials" >&2; exit 2
fi
command -v aws >/dev/null || { echo "missing: aws" >&2; exit 2; }
# AWS CLI v2 sends checksum headers R2 has historically rejected.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"

put() { aws s3 cp "$1" "s3://${R2_BUCKET}/pulsar/iso/$2" --endpoint-url "${R2_ENDPOINT}"; }

say "uploading dated artifacts"
put "${NAME}"        "${NAME}"
put "${NAME}.sha256" "${NAME}.sha256"
put "${NAME}.sha256.sig" "${NAME}.sha256.sig"
[ -f "${NAME}.sha256.pem" ] && put "${NAME}.sha256.pem" "${NAME}.sha256.pem"
put "${NAME}.json"   "${NAME}.json"

# The stable keys the site links to are written AFTER the immutable copies
# (same order as the SBOM flow) so a failed upload cannot leave "latest"
# pointing at nothing. Keyless runs stop here: the fallback publishes evidence,
# it does not move what the site serves.
if [ "${KEYLESS}" = yes ]; then
  say "keyless build: dated keys only, -latest untouched"
  exit 0
fi

LATEST="${ARTIFACT}-latest-x86_64.iso"

# The -latest checksum manifest is REGENERATED with the latest filename, not
# copied: sha256sum -c matches on the name in the file, and a manifest naming
# the dated ISO fails against the bytes saved as -latest. A different file
# means a different signature, so the manifest goes back to the signer.
sed "s|  ${NAME}\$|  ${LATEST}|" "${NAME}.sha256" > "${LATEST}.sha256"
say "signing ${LATEST}.sha256"
sign_manifest "${LATEST}.sha256"

say "uploading -latest artifacts"
put "${NAME}"            "${LATEST}"
put "${LATEST}.sha256"     "${LATEST}.sha256"
put "${LATEST}.sha256.sig" "${LATEST}.sha256.sig"
put "${NAME}.json"       "${LATEST}.json"

# The public half of the release key, next to what it verifies. Idempotent,
# and R2 rather than only the repo because the verify instructions on the site
# hand out this URL.
put "${PUBKEY}" "cosign.pub"

# The keyless era left <latest>.sig/.pem signing the ISO bytes under a Fulcio
# certificate. Anyone following the OLD instructions against the NEW uploads
# would get a confusing failure; remove them so the failure is "file not
# found". Best-effort: they are already gone on every run after the first.
aws s3 rm "s3://${R2_BUCKET}/pulsar/iso/${LATEST}.sig" --endpoint-url "${R2_ENDPOINT}" 2>/dev/null || true
aws s3 rm "s3://${R2_BUCKET}/pulsar/iso/${LATEST}.pem" --endpoint-url "${R2_ENDPOINT}" 2>/dev/null || true

say "published ${NAME} and ${LATEST}"
