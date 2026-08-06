#!/usr/bin/env bash
# Publish what the build produced: SBOMs, the changelog, the site.
#
# scripts/build.sh makes and pushes the images. Everything downstream of that
# push lives here -- describing what is in them, diffing that against last
# night, and updating the page that tells people about it.
#
# This runs on the BUILDER, not on a control host, and that is a constraint
# rather than a preference: rpm-sbom.sh reads the RPM database out of the
# image, and the manifest card is a transcript of the image's own baked
# manifest. Both need the images in local podman storage. A host without them
# would have to pull ~17GB back down to do work the builder can do for free.
#
# One implementation, called from both places. build.yml calls this during the
# migration to DigitalOcean, and scripts/nightly.sh calls it after that -- the
# same code, so the site cannot say something the registry does not. The repo
# has already paid for the other arrangement once: the local build script and
# the inline CI pipeline drifted until a bug that shipped stale content for
# weeks could not reproduce locally at all.
#
#   scripts/publish.sh --version 44.20260806.3 --dry-run
#   scripts/publish.sh --version 44.20260806.3 --prev-digest sha256:... --branch main
#
# Options:
#   --version TAG        the build being published. Required.
#   --image NAME         vanilla image        (default: $IMAGE)
#   --image-nvidia NAME  nvidia image         (default: $IMAGE_NVIDIA)
#   --digest-vanilla D   published digest; defaults to what build.sh recorded
#   --digest-nvidia D    in --work, so the normal case passes neither
#   --prev-digest D      the :latest digest from BEFORE the push -- see below
#   --work DIR           where build.sh left its digest files and layouts
#   --branch NAME        branch to commit site/ to (default: $GITHUB_REF_NAME,
#                        else the current branch; refused when detached)
#   --git-token-file P   token for the site commit, if the checkout has no
#                        credentials of its own
#   --dry-run            generate everything, publish nothing
#
# --prev-digest CANNOT BE RECOVERED HERE. It is `oras resolve ${IMAGE}:latest`
# while :latest still points at last night's build; by the time this runs the
# push has moved it. Whoever calls this must read it BEFORE calling build.sh
# and hand it over. It is provenance metadata on the changelog rather than its
# contents -- the diff baseline is the SBOM in R2 -- so getting it wrong is a
# changelog that cannot say what it diffed against, not an empty one.
#
# Environment:
#   R2_BUCKET                  where SBOMs and changelogs go
#   R2_ENDPOINT or R2_ACCOUNT_ID
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   R2 credentials
#   REGISTRY_AUTH_FILE         optional; authenticates both podman and oras
#
# Requires: jq, podman, oras, aws, git. The aws CLI is the one dependency that
# is not already on a build host -- it stays because it is the client this
# bucket is known to work with, including the checksum quirk below, and a
# hand-rolled SigV4 in the one place that writes the diff baseline is not a
# trade worth making.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEDORA_VERSION="${FEDORA_VERSION:-44}"

VERSION=""
IMAGE="${IMAGE:-}"
IMAGE_NVIDIA="${IMAGE_NVIDIA:-}"
DIGEST_VANILLA=""
DIGEST_NVIDIA=""
PREV_DIGEST="${PREV_DIGEST:-}"
WORK="${PULSAR_BUILD_WORK:-${XDG_CACHE_HOME:-${HOME}/.cache}/pulsar-build}"
BRANCH="${GITHUB_REF_NAME:-}"
GIT_TOKEN_FILE="${PULSAR_GIT_TOKEN_FILE:-}"
DRY_RUN=no

while [ $# -gt 0 ]; do
  case "$1" in
    --version)        VERSION="${2:?}"; shift ;;
    --image)          IMAGE="${2:?}"; shift ;;
    --image-nvidia)   IMAGE_NVIDIA="${2:?}"; shift ;;
    --digest-vanilla) DIGEST_VANILLA="${2:?}"; shift ;;
    --digest-nvidia)  DIGEST_NVIDIA="${2:?}"; shift ;;
    --prev-digest)    PREV_DIGEST="${2:-}"; shift ;;
    --work)           WORK="${2:?}"; shift ;;
    --branch)         BRANCH="${2:?}"; shift ;;
    --git-token-file) GIT_TOKEN_FILE="${2:?}"; shift ;;
    --dry-run)        DRY_RUN=yes ;;
    -h|--help)        sed -n '2,55p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '\n==> %s\n' "$*"; }
die()  { echo "publish: $*" >&2; exit 1; }

[ -n "${VERSION}" ]      || die "--version is required"
[ -n "${IMAGE}" ]        || die "--image (or \$IMAGE) is required"
[ -n "${IMAGE_NVIDIA}" ] || die "--image-nvidia (or \$IMAGE_NVIDIA) is required"

for tool in jq podman git; do
  command -v "${tool}" >/dev/null || die "missing: ${tool}"
done
# Only the publishing half needs these, so a dry run works on a workstation
# that has neither -- which is the point of having a dry run.
if [ "${DRY_RUN}" != yes ]; then
  command -v oras >/dev/null || die "missing: oras (attaches the SBOMs to the images)"
  command -v aws  >/dev/null || die "missing: aws (the R2 client; install awscli or pass --dry-run)"
fi

# build.sh writes these next to its OCI layouts. Reading them rather than
# taking them as arguments keeps the normal call short, and keeps the digest
# that was PUSHED as the one thing anything downstream refers to.
[ -n "${DIGEST_VANILLA}" ] || DIGEST_VANILLA="$(cat "${WORK}/digest-vanilla" 2>/dev/null || true)"
[ -n "${DIGEST_NVIDIA}" ]  || DIGEST_NVIDIA="$(cat "${WORK}/digest-nvidia" 2>/dev/null || true)"
[ -n "${DIGEST_VANILLA}" ] || die "no vanilla digest: pass --digest-vanilla or point --work at the build"
[ -n "${DIGEST_NVIDIA}" ]  || die "no nvidia digest: pass --digest-nvidia or point --work at the build"

# oras and podman disagree about where credentials live -- podman writes
# $XDG_RUNTIME_DIR/containers/auth.json, oras reads ~/.docker/config.json.
# REGISTRY_AUTH_FILE is the one variable that can point both at the same file.
ORAS_AUTH=()
[ -n "${REGISTRY_AUTH_FILE:-}" ] && ORAS_AUTH=(--registry-config "${REGISTRY_AUTH_FILE}")

R2_ENDPOINT="${R2_ENDPOINT:-${R2_ACCOUNT_ID:+https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com}}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
# AWS CLI v2 sends checksum headers R2 has historically rejected.
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"

have_r2() { [ -n "${R2_ENDPOINT}" ] && [ -n "${R2_BUCKET:-}" ] && [ -n "${AWS_ACCESS_KEY_ID:-}" ]; }

# Staging lives outside the repo on purpose: publish_site does a hard reset,
# and generated inputs sitting in the worktree would be a reset away from
# being lost or, worse, committed.
STAGE="${WORK}/publish"
rm -rf "${STAGE:?}"
mkdir -p "${STAGE}"

CRED=""
cleanup() { [ -n "${CRED}" ] && rm -f "${CRED}"; return 0; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# What is in the images.
#
# The attestation on the push proves WHERE an image came from. An SBOM proves
# WHAT IS IN IT. Provenance without contents just tells you who built the blob
# you still cannot see into.
#
# Scanned from LOCAL STORAGE, not by pulling the published digest back down.
# The two are the same package set: the rechunk only re-slices layers, and
# build.sh asserts the chunked image carries this build's os-release and that
# no mode or owner moved across the round trip before it pushes anything. So
# the local RPM database is the pushed image's RPM database, and re-fetching
# 17GB to learn that again is work with no product.
#
# Not syft, which is the obvious tool: it scans an image by squashing and
# indexing every layer, which on this image needs more than 16GB. Measured --
# the OOM killer logged 16.7GB against a 16GB cap with every cataloger but the
# RPM one disabled, because the cost is the layer indexing that happens before
# any cataloger runs. rpm-sbom.sh reads the database the image already carries
# and produces the same 1790 packages in half a second.
# ---------------------------------------------------------------------------
generate_sboms() {
  say "generating SBOMs"
  "${REPO}/scripts/rpm-sbom.sh" "${IMAGE}:${FEDORA_VERSION}"        > "${STAGE}/sbom-vanilla.spdx.json"
  "${REPO}/scripts/rpm-sbom.sh" "${IMAGE_NVIDIA}:${FEDORA_VERSION}" > "${STAGE}/sbom-nvidia.spdx.json"

  local f n
  for f in sbom-vanilla sbom-nvidia; do
    n=$(jq '[.packages[] | select(.versionInfo)] | length' "${STAGE}/${f}.spdx.json")
    echo "${f}: ${n} packages"
    [ "${n}" -gt 100 ] || die "${f} has only ${n} packages; the SBOM is not usable"
  done

  # The nvidia image derives from vanilla, so it can never legitimately carry
  # fewer packages. If it does, the wrong image was inspected.
  local v
  v=$(jq '.packages | length' "${STAGE}/sbom-vanilla.spdx.json")
  n=$(jq '.packages | length' "${STAGE}/sbom-nvidia.spdx.json")
  [ "${n}" -ge "${v}" ] || die "nvidia (${n}) has fewer packages than vanilla (${v})"
}

# Attached to the images themselves, so an SBOM travels with the thing it
# describes and anyone can fetch it with `oras discover`. R2 gets a copy too,
# but the registry copy is the authoritative one.
attach_sboms() {
  if [ "${DRY_RUN}" = yes ]; then
    echo "dry run: would attach both SBOMs as OCI referrers"
    return 0
  fi
  say "attaching SBOMs as OCI referrers"
  oras attach "${ORAS_AUTH[@]}" --artifact-type application/spdx+json \
    "${IMAGE}@${DIGEST_VANILLA}" \
    "${STAGE}/sbom-vanilla.spdx.json:application/spdx+json"
  oras attach "${ORAS_AUTH[@]}" --artifact-type application/spdx+json \
    "${IMAGE_NVIDIA}@${DIGEST_NVIDIA}" \
    "${STAGE}/sbom-nvidia.spdx.json:application/spdx+json"
}

# ---------------------------------------------------------------------------
# What changed since last night.
#
# The baseline comes from R2's stable key, NOT from discovering the previous
# image's SBOM referrer. `oras discover` has changed its JSON shape between
# releases (manifests[] vs referrers[], --output vs --format), and a changelog
# that silently empties itself when a tool updates is worse than none.
# ---------------------------------------------------------------------------
build_changelog() {
  say "diffing against last night"
  local baseline=false

  if have_r2; then
    aws s3 cp "s3://${R2_BUCKET}/pulsar/sbom/vanilla-latest.spdx.json" "${STAGE}/prev.spdx.json" \
      --endpoint-url "${R2_ENDPOINT}" 2>/dev/null || baseline=true
  else
    echo "no R2 credentials; there is nothing to diff against" >&2
    baseline=true
  fi

  if [ "${baseline}" = true ]; then
    echo "emitting a baseline changelog"
    jq -n --arg g "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --arg to "${IMAGE}@${DIGEST_VANILLA}" '{
      generated: $g, baseline: true,
      from: {ref: "", digest: ""}, to: {ref: $to, digest: ""},
      summary: {added:0, removed:0, upgraded:0, downgraded:0, changed:0},
      added: [], removed: [], changed: []
    }' > "${STAGE}/changelog.json"
  else
    # Runs inside Fedora on purpose: the direction of a version change is
    # decided by rpmdev-vercmp, which implements real RPM ordering (epochs,
    # tildes, carets). GNU sort -V gets those wrong, and an "upgraded" label
    # that is actually a downgrade is a lie.
    #
    # The script is COPIED into the stage rather than the repo being mounted:
    # a :z relabel on somebody's checkout to run one diff is more than this
    # needs to touch.
    cp "${REPO}/scripts/sbom-changelog.sh" "${STAGE}/sbom-changelog.sh"
    podman run --rm -v "${STAGE}:/w:z" -w /w \
      -e FROM_REF="${PREV_DIGEST:+${IMAGE}@${PREV_DIGEST}}" \
      -e TO_REF="${IMAGE}@${DIGEST_VANILLA}" \
      -e FROM_DIGEST="${PREV_DIGEST}" \
      -e TO_DIGEST="${DIGEST_VANILLA}" \
      "registry.fedoraproject.org/fedora:${FEDORA_VERSION}" \
      bash -c 'dnf5 -y install jq rpmdevtools >/dev/null 2>&1 &&
               ./sbom-changelog.sh prev.spdx.json sbom-vanilla.spdx.json' \
      > "${STAGE}/changelog.json"
  fi

  jq '.summary' "${STAGE}/changelog.json"
  [ -n "${PREV_DIGEST}" ] || [ "${baseline}" = true ] \
    || echo "NOTE: no --prev-digest, so this changelog cannot name what it diffed against" >&2
}

publish_r2() {
  if [ "${DRY_RUN}" = yes ]; then
    echo "dry run: would publish SBOMs and changelog for ${VERSION} to R2"
    return 0
  fi
  have_r2 || die "R2 is not configured (R2_BUCKET, R2_ACCOUNT_ID/R2_ENDPOINT, AWS_ACCESS_KEY_ID)"

  say "publishing to R2"
  up() { aws s3 cp "${STAGE}/$1" "s3://${R2_BUCKET}/$2" --endpoint-url "${R2_ENDPOINT}"; }
  # Immutable, per-build copies first...
  up sbom-vanilla.spdx.json "pulsar/sbom/${VERSION}-vanilla.spdx.json"
  up sbom-nvidia.spdx.json  "pulsar/sbom/${VERSION}-nvidia.spdx.json"
  up changelog.json         "pulsar/changelog/${VERSION}.json"
  # ...then the moving pointers. vanilla-latest.spdx.json is the key the NEXT
  # nightly diffs against, so it is written last: if anything above failed,
  # the baseline still describes a real published image.
  up changelog.json         "pulsar/changelog/latest.json"
  up sbom-nvidia.spdx.json  "pulsar/sbom/nvidia-latest.spdx.json"
  up sbom-vanilla.spdx.json "pulsar/sbom/vanilla-latest.spdx.json"
}

# ---------------------------------------------------------------------------
# The page.
#
# Rendered here, where jq exists -- NOT in site/build.sh, which Cloudflare
# runs and which stays dependency-free on purpose. The commit touches only
# site/, which build.yml's paths-ignore excludes, so it cannot retrigger an
# image build. It does wake Cloudflare's git integration, which is the point.
# ---------------------------------------------------------------------------
publish_site() {
  # The manifest card is a transcript of the image's own baked manifest, never
  # hand-written HTML wearing terminal chrome. Extracted once, out here,
  # because the render below may run more than once and this is the slow part.
  say "extracting the shipped manifest"
  podman run --rm "${IMAGE_NVIDIA}:${FEDORA_VERSION}" \
    cat /usr/share/pulsar/manifest.json > "${STAGE}/manifest.json"
  jq -e '.version' "${STAGE}/manifest.json" >/dev/null \
    || die "the image's manifest.json has no version; refusing to render it"

  if [ "${DRY_RUN}" = yes ]; then
    "${REPO}/scripts/render-changelog.sh" "${STAGE}/changelog.json" > "${STAGE}/changelog.html"
    "${REPO}/scripts/render-manifest.sh"  "${STAGE}/manifest.json"  > "${STAGE}/manifest.html"
    echo "dry run: rendered to ${STAGE}, committed nothing"
    return 0
  fi

  # An ephemeral builder's checkout has no credentials of its own. The token
  # goes into a 0600 file rather than into the remote URL, which git prints
  # back in error messages, or an http.extraheader, which is visible in ps.
  local -a cfg=(-C "${REPO}" -c user.name=pulsar-ci -c user.email=ci@arclight.build)
  if [ -n "${GIT_TOKEN_FILE}" ]; then
    CRED="${STAGE}/git-credentials"
    ( umask 077
      printf 'https://x-access-token:%s@github.com\n' "$(cat "${GIT_TOKEN_FILE}")" > "${CRED}" )
    cfg+=(-c "credential.helper=store --file=${CRED}")
  fi

  # SYNC FIRST, THEN RENDER. This used to render against the checkout and
  # reconcile afterwards with `git pull --rebase`, which was wrong twice over.
  #
  # The quiet failure: an image build takes fifteen minutes, so by the time
  # this runs the checkout can be several commits stale -- INCLUDING the
  # renderers themselves. Rendering with the stale copy and rebasing silently
  # reverts whatever changed about the output. A commit that dropped a row
  # from render-manifest.sh was undone exactly this way, without complaint.
  #
  # The loud one: these five files are wholly REGENERATED each run, so a
  # rebase is two full-file rewrites with no common hunk. It conflicts
  # whenever anything else has touched them. There is nothing to rebase if the
  # commit is built on the tip to begin with.
  publish() {
    git "${cfg[@]}" fetch -q --depth=1 origin "${BRANCH}" || return 1
    git "${cfg[@]}" reset -q --hard FETCH_HEAD           || return 1

    cp "${STAGE}/changelog.json" "${REPO}/site/changelog.json" || return 1
    cp "${STAGE}/manifest.json"  "${REPO}/site/manifest.json"  || return 1
    "${REPO}/scripts/render-changelog.sh" "${STAGE}/changelog.json" > "${REPO}/site/changelog.html" || return 1
    "${REPO}/scripts/render-manifest.sh"  "${STAGE}/manifest.json"  > "${REPO}/site/manifest.html"  || return 1
    jq -r '.version // "nightly"' "${STAGE}/manifest.json" > "${REPO}/site/version.txt" || return 1

    # Compare CONTENT, not the file. Every build stamps fresh timestamps and
    # digests, so a byte comparison always differs and would commit every
    # single night even when nothing in the image moved -- daily bot noise in
    # a hand-written history.
    local norm mnorm new old new_mf old_mf
    norm='del(.generated, .from, .to)'
    new=$(jq -S "${norm}" "${STAGE}/changelog.json")
    old=$(git -C "${REPO}" show "HEAD:site/changelog.json" 2>/dev/null | jq -S "${norm}" 2>/dev/null || echo "__none__")
    mnorm='del(.version, .built)'
    new_mf=$(jq -S "${mnorm}" "${STAGE}/manifest.json")
    old_mf=$(git -C "${REPO}" show "HEAD:site/manifest.json" 2>/dev/null | jq -S "${mnorm}" 2>/dev/null || echo "__none__")
    if [ "${new}" = "${old}" ] && [ "${new_mf}" = "${old_mf}" ]; then
      echo "no package or manifest changes since the last commit; nothing to commit"
      return 2
    fi

    # Stage BEFORE testing. `git diff` ignores untracked files, so on the
    # first run -- when these files are not in the repo yet -- it reported
    # "unchanged" and skipped the commit, which is precisely the run that had
    # to make it. That is why site/changelog.json was never committed.
    git "${cfg[@]}" add site/changelog.json site/changelog.html \
                        site/manifest.json site/manifest.html site/version.txt || return 1
    git "${cfg[@]}" commit -q -m "site: package changelog for ${VERSION}" || return 1
    git "${cfg[@]}" push -q origin "HEAD:${BRANCH}"
  }

  say "rendering and committing the site"
  # A push can still lose a race with a commit that landed in the last second.
  # That is a retry, not a merge: resync and render again.
  local attempt rc
  for attempt in 1 2 3; do
    set +e; publish; rc=$?; set -e
    case "${rc}" in
      0) echo "site commit published (attempt ${attempt})"; return 0 ;;
      2) return 0 ;;
    esac
    echo "could not publish (attempt ${attempt}); resyncing" >&2
    sleep $((attempt * 5))
  done
  die "gave up publishing the site commit after 3 attempts"
}

# Everything the site commit needs, asked BEFORE anything is published. These
# are all cheap and all fatal, and finding out about a detached HEAD after the
# SBOMs are already in R2 means a half-published build to clean up by hand.
site_preflight() {
  [ "${DRY_RUN}" = yes ] && return 0

  # publish() resets the worktree hard. On a builder that is a fresh clone and
  # costs nothing; on a workstation it would take uncommitted work with it, so
  # it is refused up front rather than explained afterwards.
  if ! git -C "${REPO}" diff --quiet || ! git -C "${REPO}" diff --cached --quiet; then
    die "the worktree is dirty and the site commit resets it; commit, stash, or --dry-run"
  fi

  if [ -z "${BRANCH}" ]; then
    BRANCH="$(git -C "${REPO}" symbolic-ref --quiet --short HEAD || true)"
    [ -n "${BRANCH}" ] || die "detached HEAD and no --branch: nothing says where the site commit goes"
  fi

  [ -z "${GIT_TOKEN_FILE}" ] || [ -r "${GIT_TOKEN_FILE}" ] \
    || die "cannot read ${GIT_TOKEN_FILE}"
  return 0
}

# publish_site resets the worktree, which replaces this file underneath the
# running shell. Everything therefore lives in functions -- bash parses a
# function whole -- and the only top-level statement after them is this call,
# by which point there is nothing left to re-read.
main() {
  site_preflight
  generate_sboms
  attach_sboms
  build_changelog
  publish_r2
  publish_site
  echo
  echo "published ${VERSION}"
}

main
