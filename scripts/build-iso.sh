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
# Two installers can come out of it, and everything after the build step --
# naming, checksum, sidecar, signature, Rekor, upload, -latest -- is the same
# code for both, so the files people download keep their names and their
# verify instructions whichever one is inside:
#
#   installer  Pulsar's own live installer (Containerfile.installer, built by
#              scripts/build-installer-iso.sh with image-builder). The default
#              since 2026-10-04. Nothing on it installs until a person picks a
#              disk and confirms: no kickstart, no unattended path.
#   anaconda   bootc-image-builder's Anaconda ISO with iso-config.toml, the
#              weekly until then. Kept as the fallback: --kind anaconda, or
#              PULSAR_ISO_KIND=anaconda in the environment.
#
# Options:
#   --kind K            installer | anaconda  (default: $PULSAR_ISO_KIND, else installer)
#   --variant V         vanilla | nvidia                    (required)
#   --image NAME        registry image to build from        (required)
#   --tag TAG           tag to resolve                      (default: latest)
#   --track TAG         tag the INSTALLED system follows    (default: latest)
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
# The installer kind tags that digest locally as ${IMAGE}:${TAG} and builds
# from the tag: image-builder embeds the payload under the name it is given,
# and the live installer installs it by that name, which is the shape the VM
# runs proved. The local tag is the resolved digest, so nothing can move it.
#
# The digest must NOT follow the image onto the machine, though. bib's own
# %post runs `bootc switch` onto the exact ref it was given, so every ISO
# before 2026-09-25 installed a system whose origin was
# ghcr.io/...@sha256:<digest>: `pulsar update` re-pulled the same digest
# forever, and `update --check` compared it to itself and said "up to date".
# The installer therefore gets a second %post (iso-config.toml) that points
# the origin back at ${IMAGE}:${TRACK}, filled in here -- --track rather than
# --tag, because an ISO built from an older tag should still follow latest.
# The live installer gets the same ref as its --target, which it writes into
# payload.json and hands to `bootc install --target-imgref`.
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

KIND="${PULSAR_ISO_KIND:-installer}"
VARIANT=""
IMAGE=""
TAG=latest
TRACK=latest
WORK="${PULSAR_ISO_WORK:-/var/tmp/pulsar-iso}"
DO_PUSH=no
SIGNER_URL="${PULSAR_SIGNER_URL:-}"
SIGNER_TOKEN_FILE="${PULSAR_SIGNER_TOKEN_FILE:-}"
# The transparency log the signer's signatures are recorded in. halo cannot
# reach it, so this builder does. REKOR_TRUSTED_ROOT is empty in production
# (Sigstore's public TUF root) and set only against a staging log.
REKOR_URL="${PULSAR_REKOR_URL:-https://rekor.sigstore.dev}"
REKOR_TRUSTED_ROOT="${PULSAR_REKOR_TRUSTED_ROOT:-}"
SIGNER_CA_FILE="${PULSAR_SIGNER_CA_FILE:-}"
KEYLESS=no

while [ $# -gt 0 ]; do
  case "$1" in
    --kind)              KIND="${2:?}"; shift ;;
    --variant)           VARIANT="${2:?}"; shift ;;
    --image)             IMAGE="${2:?}"; shift ;;
    --tag)               TAG="${2:?}"; shift ;;
    --track)             TRACK="${2:?}"; shift ;;
    --work)              WORK="${2:?}"; shift ;;
    --push)              DO_PUSH=yes ;;
    --signer-url)        SIGNER_URL="${2:?}"; shift ;;
    --signer-token-file) SIGNER_TOKEN_FILE="${2:?}"; shift ;;
    --signer-ca-file)    SIGNER_CA_FILE="${2:?}"; shift ;;
    --keyless)           KEYLESS=yes ;;
    -h|--help)           sed -n '2,/^set -euo/{/^set -euo/!p}' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

case "${KIND}" in
  installer|anaconda) ;;
  *) echo "--kind (or PULSAR_ISO_KIND) must be installer or anaconda, not '${KIND}'" >&2; exit 2 ;;
esac
case "${VARIANT}" in
  vanilla) ARTIFACT=pulsar ;;
  nvidia)  ARTIFACT=pulsar-nvidia ;;
  *) echo "--variant must be vanilla or nvidia" >&2; exit 2 ;;
esac
[ -n "${IMAGE}" ] || { echo "--image is required" >&2; exit 2; }
case "${TRACK}" in
  *[@:/]*|"") echo "--track takes a bare tag, not a reference: ${TRACK}" >&2; exit 2 ;;
esac
[ "$(id -u)" = 0 ] || { echo "run as root: bib and image-builder need the rootful store" >&2; exit 2; }

if [ "${KEYLESS}" = no ] && { [ -z "${SIGNER_URL}" ] || [ -z "${SIGNER_TOKEN_FILE}" ]; }; then
  echo "no signer configured: pass --signer-url/--signer-token-file, or --keyless" >&2
  echo "an unsigned ISO is not a thing this pipeline produces" >&2
  exit 2
fi

tools=(podman skopeo jq sha256sum cosign curl basenc)
[ "${KIND}" = installer ] && tools+=(image-builder python3)
for tool in "${tools[@]}"; do
  command -v "${tool}" >/dev/null || { echo "missing: ${tool}" >&2; exit 2; }
done
INSTALLER_BUILD="${REPO}/scripts/build-installer-iso.sh"
if [ "${KIND}" = installer ] && [ ! -x "${INSTALLER_BUILD}" ]; then
  echo "missing ${INSTALLER_BUILD}: cannot build the live installer" >&2
  exit 2
fi

PUBKEY="${REPO}/keys/cosign.pub"
if [ "${KEYLESS}" = no ] && [ ! -r "${PUBKEY}" ]; then
  echo "missing ${PUBKEY}: cannot verify what the signer returns" >&2
  exit 2
fi

# Not optional, and checked before anything expensive for the same reason the
# signer arguments are. Without a config, bib writes a kickstart that runs
# `clearpart --all` and `autopart` against every disk the installer can see --
# see iso-config.toml for the whole story. A missing file has to stop the build
# here rather than quietly produce that ISO a second time. Anaconda only: the
# live installer has no kickstart to supply.
ISO_CONFIG="${REPO}/iso-config.toml"
if [ "${KIND}" = anaconda ] && [ ! -r "${ISO_CONFIG}" ]; then
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
# run-iso.sh on the build host reads the version back out of this line
# ('ISO for <version>') for its sentinel. Keep that shape.
say "building ${ARTIFACT} ISO for ${VERSION} (${DIGEST}, ${KIND})"

podman pull --retry 5 "${IMAGE}@${DIGEST}"

# The ref the installed system follows (see the header), for both kinds.
TRACK_REF="${IMAGE}:${TRACK}"

# ---------------------------------------------------------------------------
# The build step: one function per kind, each leaving one .iso under
# ${WORK}/iso. Everything after it is shared.
# ---------------------------------------------------------------------------

# bootc-image-builder's Anaconda ISO, with iso-config.toml as its kickstart.
build_anaconda() {
  # Fill in the ref the installed system follows. Checked for the exact
  # command rather than just for the placeholder going away: a config edited
  # so the line no longer exists would pass that check and ship the
  # digest-pinned installs again, and there is no symptom until the first
  # update that never comes.
  local rendered="${WORK}/iso-config.toml"
  sed "s|@PULSAR_TRACK_IMGREF@|${TRACK_REF}|g" "${ISO_CONFIG}" > "${rendered}"
  if grep -q '@PULSAR_TRACK_IMGREF@' "${rendered}" || \
     ! grep -qxF "bootc switch --mutate-in-place --transport registry ${TRACK_REF}" "${rendered}"; then
    echo "iso-config.toml no longer carries the %post that points installs at ${TRACK_REF}" >&2
    echo "without it every install stays on ${DIGEST} and never updates. refusing to build." >&2
    exit 1
  fi
  say "installed systems will track ${TRACK_REF}"

  # --privileged and the unconfined label are what upstream documents: the
  # builder makes loopback devices and mounts filesystems to lay the ISO out,
  # none of which works from a confined container. The storage mount is
  # read-WRITE and has to be: bib runs a nested podman against this graphroot;
  # mounted :ro it dies on `mkdir .../l: read-only file system` before it does
  # any work. /store and /rpmmd are mounted for space, not correctness -- left
  # unmounted they land in the container's overlay on the root disk.
  #
  # The config lands at /config.toml because bib picks its decoder off the
  # file EXTENSION -- mounted under any other name it is parsed as JSON and the
  # build dies on the first line. It is passed explicitly rather than relying
  # on bib's "/config.json will be used if present" fallback, so that a mount
  # that failed to land is a bib error about a missing file rather than a
  # silent return to the unattended kickstart.
  say "running bootc-image-builder"
  podman run --rm --privileged \
    --security-opt label=type:unconfined_t \
    -v "${WORK}/iso:/output" \
    -v "${rendered}:/config.toml:ro" \
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
}

# Pulsar's live installer. build-installer-iso.sh reads both of its refs from
# local storage and pulls only what is missing, so tagging the resolved digest
# first makes ${IMAGE}:${TAG} mean that digest for the whole build: the live
# system is built FROM it and the same image is embedded as the payload.
# --target is what installs follow, as for Anaconda.
build_installer() {
  podman tag "${IMAGE}@${DIGEST}" "${IMAGE}:${TAG}"
  say "running build-installer-iso.sh; installed systems will track ${TRACK_REF}"
  "${INSTALLER_BUILD}" \
    --variant "${VARIANT}" \
    --image "${IMAGE}:${TAG}" \
    --target "${TRACK_REF}" \
    --out "${WORK}/iso"
}

"build_${KIND}"

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
  --arg tracks "${TRACK_REF}" \
  --arg built "$(date -u -Iseconds)" \
  --arg iso_sha256 "${ISO_SHA256}" \
  --arg installer "${KIND}" \
  '{variant: $variant, version: $version, image: $image, digest: $digest,
    tracks: $tracks, built: $built, iso_sha256: $iso_sha256,
    installer: $installer}' > "${NAME}.json"

# ---------------------------------------------------------------------------
# Rekor
# ---------------------------------------------------------------------------
# Rekor answers in hex; Sigstore bundles want base64. coreutils only.
hex_b64() { printf '%s' "$1" | tr 'a-f' 'A-F' | basenc --base16 -d | base64 -w0; }

# Record a signature halo made offline as a hashedrekord (the file's hash, the
# signature, the public key -- nothing secret) and write Rekor's entry to $3.
# Retried, then fatal: the published instructions verify against the log, so
# a signature with no entry would fail for every user. A 409 means an earlier
# try landed and only its answer was lost; Rekor names that entry.
rekor_log() { # <file> <signature, no trailing newline> <entry-out>
  local file="$1" sig="$2" out="$3" code location attempt
  jq -n --rawfile sig "${sig}" --arg pub "$(base64 -w0 "${PUBKEY}")" \
        --arg h "$(sha256sum "${file}" | cut -d' ' -f1)" \
    '{apiVersion: "0.0.1", kind: "hashedrekord", spec: {
        signature: {content: $sig, publicKey: {content: $pub}},
        data: {hash: {algorithm: "sha256", value: $h}}}}' > "${out}.req"
  for attempt in 1 2 3 4 5; do
    code="$(curl -sS --max-time 30 -o "${out}" -D "${out}.headers" -w '%{http_code}' \
      -H 'Content-Type: application/json' --data-binary "@${out}.req" \
      "${REKOR_URL}/api/v1/log/entries")" || code=000
    case "${code}" in
      201) rm -f "${out}.req" "${out}.headers"; return 0 ;;
      409)
        location="$(tr -d '\r' < "${out}.headers" | sed -n 's/^[Ll]ocation: *//p' | tail -1)"
        if [ -n "${location}" ] && curl -fsS --max-time 30 -o "${out}" "${REKOR_URL}${location#"${REKOR_URL}"}"; then
          rm -f "${out}.req" "${out}.headers"; return 0
        fi ;;
      4??)
        echo "rekor refused the entry (HTTP ${code}): $(head -c 300 "${out}" 2>/dev/null)" >&2
        return 1 ;;
    esac
    echo "rekor upload attempt ${attempt} failed (HTTP ${code})" >&2
    [ "${attempt}" = 5 ] || sleep $((attempt * 15))
  done
  return 1
}

# A Sigstore v0.3 bundle for $1 from its signature and Rekor entry: what
# `cosign verify-blob --bundle` reads without --insecure-ignore-tlog. The
# promise and the inclusion proof are the log's own; nothing here is trusted
# on this builder's say-so.
rekor_bundle() { # <file> <signature> <entry> <bundle-out>
  local file="$1" sig="$2" entry="$3" out="$4" e hashes
  e="$(jq -c 'to_entries[0].value' "${entry}")"
  hashes="$(jq -r '.verification.inclusionProof.hashes[]' <<<"${e}" \
    | while read -r h; do hex_b64 "${h}"; echo; done | jq -R . | jq -s -c .)"
  jq -n --argjson e "${e}" --argjson hashes "${hashes}" --rawfile sig "${sig}" \
        --arg logid "$(hex_b64 "$(jq -r .logID <<<"${e}")")" \
        --arg root "$(hex_b64 "$(jq -r .verification.inclusionProof.rootHash <<<"${e}")")" \
        --arg dig "$(hex_b64 "$(sha256sum "${file}" | cut -d' ' -f1)")" '{
    mediaType: "application/vnd.dev.sigstore.bundle.v0.3+json",
    verificationMaterial: {
      publicKey: {hint: ""},
      tlogEntries: [{
        logIndex: ($e.logIndex | tostring), logId: {keyId: $logid},
        kindVersion: {kind: "hashedrekord", version: "0.0.1"},
        integratedTime: ($e.integratedTime | tostring),
        inclusionPromise: {signedEntryTimestamp: $e.verification.signedEntryTimestamp},
        inclusionProof: {
          logIndex: ($e.verification.inclusionProof.logIndex | tostring),
          rootHash: $root, treeSize: ($e.verification.inclusionProof.treeSize | tostring),
          hashes: $hashes, checkpoint: {envelope: $e.verification.inclusionProof.checkpoint}},
        canonicalizedBody: $e.body}]},
    messageSignature: {messageDigest: {algorithm: "SHA2_256", digest: $dig}, signature: $sig}}' > "${out}"
}

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
  # Containerfile.nvidia. halo cannot reach Rekor (its unit allows only VPC
  # addresses), so this builder records the signature there itself.
  local curl_args=(-sS --fail-with-body -X POST --data-binary "@${f}"
    -H "Authorization: Bearer $(cat "${SIGNER_TOKEN_FILE}")"
    -H "X-Pulsar-Name: $(basename "${f}")")
  [ -n "${SIGNER_CA_FILE}" ] && curl_args+=(--cacert "${SIGNER_CA_FILE}")
  curl "${curl_args[@]}" "${SIGNER_URL}/sign-blob" \
    | jq -r '.signature // empty' > "${f}.sig"
  [ -s "${f}.sig" ] || { echo "signer returned no signature for ${f}" >&2; exit 1; }

  # Recorded in Rekor from here, then checked the way the site tells users to:
  # the committed key and the log's proof, no --insecure-ignore-tlog. A
  # signature from a key this repo has never heard of fails here too -- Rekor
  # itself refuses a signature that does not match the key it is given.
  tr -d '\n' < "${f}.sig" > "${f}.sig.raw"
  rekor_log "${f}" "${f}.sig.raw" "${f}.rekor.json" \
    || { echo "could not record the signature on ${f} in Rekor (${REKOR_URL})" >&2; exit 1; }
  rekor_bundle "${f}" "${f}.sig.raw" "${f}.rekor.json" "${f}.sigstore.json"
  rm -f "${f}.sig.raw" "${f}.rekor.json"

  local root=()
  [ -n "${REKOR_TRUSTED_ROOT}" ] && root=(--trusted-root "${REKOR_TRUSTED_ROOT}")
  cosign verify-blob \
    --key "${PUBKEY}" \
    --bundle "${f}.sigstore.json" \
    "${root[@]}" \
    "${f}" \
    || { echo "signature on ${f} does not verify against keys/cosign.pub and its Rekor entry" >&2
         echo "halo is signing with a key this repo has never heard of, or the log answer is bad" >&2
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
[ -f "${NAME}.sha256.sigstore.json" ] && put "${NAME}.sha256.sigstore.json" "${NAME}.sha256.sigstore.json"
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
put "${LATEST}.sha256.sigstore.json" "${LATEST}.sha256.sigstore.json"
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
