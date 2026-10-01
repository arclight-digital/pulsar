#!/usr/bin/env bash
# The nightly, as an ephemeral builder runs it.
#
# This is the entry point the builder's cloud-init calls: compute the version,
# call the pipeline, tell the dead-man's switch it finished. It lives here
# rather than in arclight-infra because it is build logic, and the repo that
# knows how Pulsar is built should own it -- the infra repo spawns a droplet
# and hands it a ref, and everything after that is this.
#
# Deliberately thin, and it stays a scheduler. The pipeline is
# scripts/build.sh and everything downstream of the push is
# scripts/publish.sh -- the same code a workstation runs. This adds
# versioning, ordering and alerting, nothing else.
#
# A timer that silently stops firing is the classic failure of moving off
# hosted CI: GitHub emails when a workflow fails, a systemd timer does not,
# and an ephemeral droplet that dies early leaves nothing behind to notice.
# PULSAR_HEALTHCHECK_URL is pinged only on success, so a missed or failed run
# raises an alert by omission. If it is unset this still runs -- it just runs
# unwatched, and says so.
#
# Fail-closed throughout. In particular the nvidia variant cannot build
# without the signer, and a night with no signer publishes nothing at all
# rather than publishing half a release.
#
# Configuration comes from the environment, normally /etc/pulsar/build.env:
#   IMAGE, IMAGE_NVIDIA         registry names
#   PULSAR_SIGNER_URL           the signing oracle, on the private VPC
#   PULSAR_SIGNER_TOKEN_FILE    bearer token, root-owned, 0400
#   PULSAR_SIGNER_CA_FILE       the signer's TLS certificate. Public, not a
#                               secret, and NOT the module-signing cert --
#                               this one secures the channel, /cert returns
#                               the other. Required: the build cannot verify
#                               a self-signed VPC certificate without it.
#   PULSAR_BUILD_WORK           OCI layouts; wants the big volume
#   PULSAR_HEALTHCHECK_URL      pinged on success (optional)
#   R2_BUCKET, R2_ACCOUNT_ID    where SBOMs and changelogs are published
#   R2_CREDENTIALS_FILE         file setting AWS_ACCESS_KEY_ID/SECRET, or set
#                               those directly. Required unless PULSAR_PUBLISH
#                               is no -- see the note in publish.sh for why it
#                               is not allowed to degrade quietly.
#   PULSAR_GIT_TOKEN_FILE       token for the site commit
#   PULSAR_PUBLISH_BRANCH       branch the site commit lands on (default main)
#   PULSAR_PUBLISH              yes (default) | dry-run | no
#   PULSAR_CHANNEL              scheduled | manual. REQUIRED -- see below.
#   PULSAR_FORCE_BUILD          yes to build even when nothing the image is
#                               made from has changed -- see anything_moved()
#   PULSAR_GATE                 1 to stop after the version tags and a staged
#                               publish, for the boot gate; the build host
#                               releases the night once it passes. Anything
#                               else: ungated, as ever.
#   PULSAR_MIN_FREE_GB          floor build.sh refuses to start under, in GB
#                               (default 10, 0 disables). A full build cache
#                               reports itself as whichever mirror the build
#                               was talking to when the disk ran out.
#
# One argument, optional: --base-check answers the anything_moved() question and
# exits without building anything. 0 it would build, 3 it would skip.
# --preflight checks the credentials a build will need (see preflight()) and
# exits: 0 usable, 1 not. Anything
# else is refused with 2 rather than ignored -- a swallowed --manual builds and
# publishes as scheduled, which is the one outcome this script is written to
# prevent.
#
# THE CHANNEL IS THE ONE THING THIS SCRIPT WILL NOT GUESS. A scheduled build is
# the one users pull; a manual build is one a person kicked off while working.
# Conflating them costs real things -- a hand-run build used to consume a number
# in the published series, move :latest onto a debugging image, and overwrite
# the SBOM baseline the next night diffs against.
#
# So an unset PULSAR_CHANNEL is a hard stop rather than a default. Both possible
# defaults are wrong in a way somebody pays for: guessing scheduled hands a
# debugging build every user's next bootc upgrade, and guessing manual leaves a
# nightly that quietly publishes nothing while looking like it worked. This is
# next-version.sh's "a version scheme that guesses when it does not know is not
# a version scheme", one level up.
#
# A manual build still builds, signs, verifies and pushes -- it is a real image
# anyone can pull, which is the point of running it. What it does not do is
# define anything: no floating tags, no baseline, no site commit, and no
# healthcheck ping.
set -euo pipefail

# cloud-init's runcmd is not a login shell: it runs as root with no $HOME.
# oras resolves the running user's home for its registry config and
# hard-fails without it -- and oras answers the version lookup, so no $HOME
# means no version. The old .0 fallback was almost certainly masking exactly
# this failure on every host run, which is how two builds computed .0 on
# 2026-08-07. Derived from the passwd entry rather than assumed to be /root:
# the directory exists, only the variable is missing.
if [ -z "${HOME:-}" ]; then
  HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
  [ -n "${HOME}" ] || { echo "no \$HOME and no passwd entry for uid $(id -u)" >&2; exit 2; }
  export HOME
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

IMAGE="${IMAGE:?IMAGE is not set}"
IMAGE_NVIDIA="${IMAGE_NVIDIA:?IMAGE_NVIDIA is not set}"
FEDORA_VERSION="${FEDORA_VERSION:-44}"
WORK="${PULSAR_BUILD_WORK:-/var/mnt/pulsar-build}"
# Scratch for this script itself, which is a manifest or two -- not ${WORK},
# which is OCI layouts and wants the big volume, and which the gate below runs
# before anything has created.
WORK_TMP="$(mktemp -d -t pulsar-nightly-XXXXXX)"
trap 'rm -rf "${WORK_TMP}"' EXIT
# Kept in step with build.sh, which records which digest of this a build used.
BASE_IMAGE="${BASE_IMAGE:-quay.io/fedora-ostree-desktops/silverblue}"

# All of it in one function, because publish.sh syncs the checkout to origin
# before it commits and that rewrites this file underneath the running shell.
# Bash parses a function whole; it re-reads the file by offset between
# top-level statements, and there are none left after the call below.
main() {

# ---------------------------------------------------------------------------
# Is there anything to build tonight?
#
# Neither Containerfile ever runs `dnf5 upgrade`. Every OS package in the image
# comes from quay's silverblue:${FEDORA_VERSION}; this build only INSTALLS on
# top of it. So when that tag has not moved since the last published build, the
# image tonight would produce carries the same package set as the one users are
# already running. That is not a hypothetical -- it is 2026-08-14, whose
# changelog came out zero across the board.
#
# Shipping it anyway is not free. The version label and the os-release stamp
# move on every build by construction, so the digest moves too, and `pulsar
# update --check` compares digests: every machine gets a notification and a
# multi-gigabyte pull for a package set it already has.
#
# "That tag has not moved" is the question this asks second, because it is
# free. It is not the question it means. quay rebuilds and re-pushes
# silverblue:${FEDORA_VERSION} nightly whether or not a package in it moved,
# so the tag's digest is new most mornings, its ostree commit is new with it,
# and a handful of its layers are new around an otherwise identical package
# set. See base_moved() for what is asked instead.
#
# THE BASE IS ONE OF THREE THINGS THE IMAGE IS MADE FROM, and for its first
# six weeks this gate asked about it alone. The other two moved under it
# unseen, and a night where only they moved was skipped until quay next
# happened to publish a different package set:
#
#   this repo     a fix merged here -- 2026-09-26's ffcd17f, which takes a
#                 false claim off the published manifest -- waited for Fedora.
#                 See tree_moved(): the published image records the commit it
#                 was built from, and any change since to a path that goes
#                 into the image builds.
#   the add-ons   the packages installed ON TOP of the base: rpmfusion's
#                 ffmpeg and NVIDIA driver, scx-scheds from the copr, mise,
#                 the NVIDIA container toolkit. A driver or security update
#                 there sat unshipped. See addons_moved(): their current
#                 versions are hashed, and the hash rides on the image.
#
# A night is skipped only when all three are where the published build left
# them. To ship regardless, run with PULSAR_FORCE_BUILD=yes.
#
# FAILS OPEN, everywhere. Every path that cannot get a straight answer builds.
# A gate that skips when it cannot see would stop shipping updates in silence,
# and silence is exactly what this pipeline reserves for "the timer did not
# fire" -- a wasted build hour is the cheaper mistake by a wide margin.
# ---------------------------------------------------------------------------
# THE TAG HAS TWO DIGESTS AND THE GATE HAS TO ASK FOR THE RIGHT ONE.
# silverblue:44 is a multi-arch index. `skopeo inspect` reports the digest of
# that INDEX; the `.Digest` podman keeps for the image it pulled -- which is
# what build.sh reads out of local storage and writes into the label -- is the
# per-arch MANIFEST inside it. Neither tool is wrong and the two are never
# equal, so the comparison below was false on every night the gate has ever
# run: 2026-08-15 and 2026-08-16 both recorded base 78399a1d and shipped
# anyway, a full changelog of zeros and a multi-gigabyte pull for everyone.
#
# So resolve the index here rather than take its digest. That is also the more
# precise question: an arm64-only respin moves the index without changing a
# byte of what this build pulls, and comparing instances sits that night out.
#
# Prints one digest per line, the arch instance first and the index second --
# either is a legitimate answer to "which digest is this tag", and a label
# carrying either one means the base is where it was. No output means the
# question could not be answered, which the caller reads as "build".
base_tag_digests() {
  local raw arch
  raw="${WORK_TMP}/base-manifest.json"
  skopeo inspect --raw "docker://${BASE_IMAGE}:${FEDORA_VERSION}" > "${raw}" 2>/dev/null || return 0
  [ -s "${raw}" ] || return 0

  # An index is a document with manifests in it. Asking that rather than
  # matching mediaType, which OCI allows an index to omit entirely -- and the
  # cost of misreading an index as a manifest here is this whole bug again.
  if jq -e '.manifests | type == "array"' "${raw}" >/dev/null 2>&1; then
    # podman's Host.Arch is already GOARCH, which is what OCI platforms use.
    arch="$(podman info --format '{{.Host.Arch}}' 2>/dev/null || true)"
    jq -r --arg a "${arch:-amd64}" '
      .manifests[]
      | select(.platform.architecture == $a)
      | select((.platform.os // "linux") == "linux")
      | select((.platform.variant // "") == "")
      | .digest' "${raw}" 2>/dev/null
  fi

  # A registry digest is the sha256 of the manifest bytes exactly as served, so
  # this is the index's own digest without asking the network twice -- and the
  # tag's whole answer when it is not an index at all.
  echo "sha256:$(sha256sum < "${raw}" | cut -d' ' -f1)"
}

# The labels on a registry reference, as JSON. One fetch answers every label
# on it, which is what the published image is asked for below -- and jq reads
# a label that is not there as null, where a Go template prints the string
# `<no value>` and every caller has to know that.
image_labels() {
  skopeo inspect --no-tags "docker://$1" 2>/dev/null || true
}

# One label out of that JSON, empty when it is absent or the fetch failed.
label_of() {
  [ -n "$1" ] || return 0
  jq -r --arg k "$2" '.Labels[$k] // ""' <<<"$1" 2>/dev/null || true
}

base_moved() {
  # A manual build is somebody asking for this exact tree to be built. It is
  # never about the base, and refusing it because quay is quiet would be
  # refusing the one build a person is standing there waiting for.
  [ "${CHANNEL}" = scheduled ] || { echo "manual build: not gated on the base image"; return 0; }
  if [ "${PULSAR_FORCE_BUILD:-no}" = yes ]; then
    echo "PULSAR_FORCE_BUILD=yes: building regardless of the base"
    return 0
  fi
  command -v skopeo >/dev/null || { echo "no skopeo; cannot check the base, so building" >&2; return 0; }
  command -v jq >/dev/null || { echo "no jq; cannot read the base index, so building" >&2; return 0; }

  local published last last_input
  # Absent on anything built before build.sh started writing these labels, and
  # on the first push of a new image name. Both mean there is no comparison to
  # be made, which is not the same as the base being unchanged.
  published="$(image_labels "${IMAGE}:latest")"
  last="$(label_of "${published}" digital.arclight.pulsar.base-digest)"
  last_input="$(label_of "${published}" digital.arclight.pulsar.base-inputhash)"
  [ -n "${last}" ] \
    || { echo "the published build records no base digest; building" >&2; return 0; }

  # A SPLIT RELEASE IS NOT AN UNCHANGED BASE. build.sh used to push vanilla
  # to :latest before it built nvidia, so a night whose nvidia half failed
  # left the two :latest tags on different versions -- and every label above
  # is read off vanilla, which said the base was already built. build.sh now
  # moves both :latest tags together after both variants are pushed, so a
  # split takes a failure in the seconds between the two promotions; this
  # stays as the belt for that. Fails open with the rest: an nvidia tag that
  # cannot be read is a mismatch, and builds.
  #
  # THE COST of moving them together, accepted with open eyes: an nvidia half
  # that fails EVERY night (an akmod that will not build against a new
  # kernel) now holds vanilla back too. Each of those nights fails loudly,
  # and nobody is left a build ahead of anybody else.
  local version nv_version
  version="$(label_of "${published}" org.opencontainers.image.version)"
  if [ -n "${version}" ]; then
    nv_version="$(label_of "$(image_labels "${IMAGE_NVIDIA}:latest")" org.opencontainers.image.version)"
    if [ "${nv_version}" != "${version}" ]; then
      echo "${IMAGE}:latest is ${version} but ${IMAGE_NVIDIA}:latest is ${nv_version:-unreadable}; building" >&2
      return 0
    fi
  fi

  local -a now=()
  local d
  while IFS= read -r d; do
    [ -n "${d}" ] || continue
    now+=("${d}")
  done < <(base_tag_digests)
  [ "${#now[@]}" -gt 0 ] \
    || { echo "could not resolve ${BASE_IMAGE}:${FEDORA_VERSION}; building" >&2; return 0; }

  for d in "${now[@]}"; do
    if [ "${d}" = "${last}" ]; then
      echo "base ${BASE_IMAGE}:${FEDORA_VERSION} is still ${d}"
      return 1
    fi
  done
  # THE DIGEST MOVED. THAT IS STILL NOT A REASON TO BUILD.
  #
  # quay rebuilds this tag every night at about 02:10 UTC and pushes the
  # result whether or not the compose resolved a single different package. A
  # rebuild of an unchanged package set is a new manifest, a new config, a new
  # ostree commit and seven new layers out of two hundred and fifty-seven, so
  # nothing hashed above can tell it apart from a real one. 2026-08-18 and
  # 2026-08-19 were exactly that pair, and the second was built and published
  # with a changelog of zeros -- the failure the gate exists to stop, arrived
  # at through a comparison that was working correctly.
  #
  # rpm-ostree writes what the digest cannot say: rpmostree.inputhash is a
  # hash of the compose's INPUTS, the treefile and the resolved NEVRAs. Two
  # base images with one input hash have one package set, however far apart
  # their digests are. Read off the arch instance resolved above, which is the
  # image this build would pull, and compared against what build.sh recorded
  # off the image the published build did pull.
  #
  # Second, not first, because it costs a fetch the digest comparison does not
  # -- and only reached on the nights the digest moved, which is most of them.
  # Fails open with the rest of this function: no recorded hash, no readable
  # hash, or two hashes that differ all build.
  local now_input=""
  if [ -n "${last_input}" ]; then
    now_input="$(label_of "$(image_labels "${BASE_IMAGE}@${now[0]}")" rpmostree.inputhash)"
    if [ -n "${now_input}" ] && [ "${now_input}" = "${last_input}" ]; then
      echo "base ${BASE_IMAGE}:${FEDORA_VERSION} was rebuilt, ${last} -> ${now[0]},"
      echo "and composed the same packages: rpmostree.inputhash ${now_input}"
      return 1
    fi
  fi

  # Both digests, always, and the input hashes under them: the pairs are what
  # make a wrong answer here legible the next time somebody reads this log
  # wondering why the night was noisy.
  echo "base moved: ${last} -> ${now[*]}"
  if [ -n "${last_input}" ] || [ -n "${now_input}" ]; then
    echo "  inputhash: ${last_input:-<none recorded>} -> ${now_input:-<unreadable>}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The repo. Paths that do not go into the image, for tree_moved(). Everything
# else counts -- scripts/ included, since build.sh and the wallpaper renderer
# shape the image without being copied into it. Wrong in the safe direction:
# a path missing from this list costs a build, never a skipped fix.
#
# `glob` so `*.md` is the top-level documents only. Markdown under
# system_files/ ships in the image, and a plain pathspec would exclude it too.
# ---------------------------------------------------------------------------
NOT_IMAGE=(
  ':(exclude)site' ':(exclude)docs' ':(exclude)tests'
  ':(exclude).impeccable' ':(exclude).preview' ':(exclude).claude'
  ':(exclude)iso-config.toml' ':(exclude,glob)*.md'
)

tree_moved() {
  local published rev changed n
  published="$(image_labels "${IMAGE}:latest")"
  rev="$(label_of "${published}" org.opencontainers.image.revision)"
  [ -n "${rev}" ] \
    || { echo "the published build records no commit; building" >&2; return 0; }
  # A manual build from a dirty tree records <sha>-dirty, which is not a
  # commit, and a commit this checkout has never seen cannot be diffed. Both
  # are "cannot tell", which builds.
  git -C "${REPO}" cat-file -e "${rev}^{commit}" 2>/dev/null \
    || { echo "the published commit ${rev} is not in this checkout; building" >&2; return 0; }
  changed="$(git -C "${REPO}" diff --name-only "${rev}" HEAD -- . "${NOT_IMAGE[@]}" 2>/dev/null)" \
    || { echo "could not diff ${rev} against HEAD; building" >&2; return 0; }
  if [ -z "${changed}" ]; then
    echo "no image input changed since ${rev:0:12}"
    return 1
  fi
  n="$(wc -l <<<"${changed}")"
  echo "image inputs changed since ${rev:0:12} (${n}):"
  head -n 10 <<<"${changed}" | sed 's/^/  /'
  [ "${n}" -le 10 ] || echo "  ... and $((n - 10)) more"
  return 0
}

# ---------------------------------------------------------------------------
# The add-ons. What the images install from outside Fedora, by name, and the
# repos in scripts/addon-repos/ that serve them. A package added to a
# Containerfile from one of those repos belongs here too.
# ---------------------------------------------------------------------------
ADDON_PACKAGES=(
  ffmpeg mesa-va-drivers-freeworld                  # rpmfusion free
  akmod-nvidia-open xorg-x11-drv-nvidia nvidia-settings  # rpmfusion nonfree
  scx-scheds                                        # copr kernel-cachyos-addons
  mise                                              # mise.jdx.dev
  nvidia-container-toolkit-base                     # nvidia.github.io
)

# One hash of the newest version of each add-on, or nothing when the repos
# cannot be read -- which the gate treats as moved, and which build.sh then
# records as no label at all, so the next night asks again rather than
# comparing against a guess. A second or two of metadata, not a build.
addons_fingerprint() {
  command -v dnf5 >/dev/null || return 0
  local list
  list="$(dnf5 -q \
      --setopt=reposdir="${REPO}/scripts/addon-repos" \
      --setopt=cachedir="${WORK_TMP}/dnf" \
      --setopt=gpgcheck=0 --setopt=repo_gpgcheck=0 \
      --releasever="${FEDORA_VERSION}" \
      repoquery --latest-limit=1 --arch="$(uname -m),noarch" \
      --qf '%{name} %{evr}\n' "${ADDON_PACKAGES[@]}" 2>/dev/null | sort -u)" || return 0
  # Every package must answer. A repo that failed to load drops its packages
  # silently, and a hash over the survivors would be a change that is not one.
  local p
  for p in "${ADDON_PACKAGES[@]}"; do
    grep -q "^${p} " <<<"${list}" || return 0
  done
  printf '%s\n' "${list}" > "${WORK_TMP}/addons.txt"
  sha256sum <<<"${list}" | cut -d' ' -f1
}

addons_moved() {
  local last
  last="$(label_of "$(image_labels "${IMAGE}:latest")" digital.arclight.pulsar.addons-hash)"
  [ -n "${PULSAR_ADDONS_HASH:-}" ] \
    || { echo "could not read the add-on repos; building" >&2; return 0; }
  [ -n "${last}" ] \
    || { echo "the published build records no add-on versions; building" >&2; return 0; }
  if [ "${last}" = "${PULSAR_ADDONS_HASH}" ]; then
    echo "add-ons unchanged: ${PULSAR_ADDONS_HASH:0:12}"
    return 1
  fi
  echo "add-ons moved: ${last:0:12} -> ${PULSAR_ADDONS_HASH:0:12}"
  sed 's/^/  /' "${WORK_TMP}/addons.txt" 2>/dev/null || true
  return 0
}

# The whole question. base_moved() answers for manual and forced builds too,
# so those never reach the other two.
anything_moved() {
  base_moved && return 0
  tree_moved && return 0
  addons_moved && return 0
  return 1
}

# ---------------------------------------------------------------------------
# PREFLIGHT: the credentials a night will need, asked for in its first minute.
#
# Each was first used late. The signer is first called about twenty-five
# minutes in, from inside the nvidia build; the git token not until the site
# commit, an hour in, after the images are already public. On 2026-09-05 that
# token expired and the site stalled silently for four days. So each is tried
# here, where a dead one costs a minute, and a token that is merely close to
# its expiry is named in the log and in the healthcheck ping while there is
# still time to renew it.
#
# Run EVERY night, skipped ones included: a token dies on its own schedule,
# not on nights with something to build. Each check needs its input and is
# skipped without it, so a workstation run with none of this configured
# checks nothing and says so.
#
# Tokens reach curl through a 0600 header file, never an argument, which
# every other user on the box could read out of ps.
# ---------------------------------------------------------------------------
PULSAR_GITHUB_REPO="${PULSAR_GITHUB_REPO:-arclight-digital/pulsar}"
# The site commit goes to the site's own repo (publish.sh --site-repo), so that
# is the repo the site token must be able to push to. One value, used by both
# the check below and publish.sh, so the two cannot drift apart.
PULSAR_SITE_REPO="${PULSAR_SITE_REPO:-https://github.com/arclight-digital/pulsar-site.git}"
SITE_REPO_SLUG="${PULSAR_SITE_REPO#https://github.com/}"
SITE_REPO_SLUG="${SITE_REPO_SLUG%.git}"
PREFLIGHT_WARNINGS=""
EXPIRY_WARN_DAYS=14

preflight_warn() {
  echo "WARNING: $*" >&2
  PREFLIGHT_WARNINGS+="${PREFLIGHT_WARNINGS:+; }$*"
}

auth_header() {
  local f="${WORK_TMP}/auth-header"
  ( umask 077; printf '%s\n' "$1" > "${f}" )
  printf '%s' "${f}"
}

# $1 what it is, $2 the token, $3 the API path to ask, $4 what it must allow:
# push (to PULSAR_GITHUB_REPO) or packages (write:packages). 1 = unusable.
check_github_token() {
  local what="$1" hdr="${WORK_TMP}/gh-headers" body="${WORK_TMP}/gh-body" code exp days scopes
  code="$(curl -sS --max-time 20 -o "${body}" -D "${hdr}" -w '%{http_code}' \
            -H @"$(auth_header "Authorization: token $2")" \
            "https://api.github.com/$3" 2>/dev/null)" \
    || { preflight_warn "could not reach api.github.com to check the ${what}"; return 0; }
  case "${code}" in
    200) ;;
    401) echo "FATAL: GitHub rejects the ${what} (401): expired or revoked" >&2; return 1 ;;
    *)   preflight_warn "checking the ${what} got HTTP ${code} from GitHub; not checked"; return 0 ;;
  esac
  case "$4" in
    push)
      jq -e '.permissions.push == true' "${body}" >/dev/null 2>&1 \
        || { echo "FATAL: the ${what} cannot push to ${3#repos/}" >&2; return 1; } ;;
    packages)
      # Classic tokens list their scopes; fine-grained ones do not, and are
      # given the benefit of the doubt rather than refused on a missing header.
      scopes="$(grep -i '^x-oauth-scopes:' "${hdr}" | cut -d: -f2- | tr -d '\r')"
      if [ -n "${scopes}" ] && ! grep -q 'write:packages' <<<"${scopes}"; then
        echo "FATAL: the ${what} lacks write:packages (has:${scopes})" >&2
        return 1
      fi ;;
  esac
  exp="$(grep -i '^github-authentication-token-expiration:' "${hdr}" | cut -d: -f2- | tr -d '\r' | sed 's/^ *//')"
  if [ -z "${exp}" ]; then
    echo "${what}: usable, no expiry"
    return 0
  fi
  days=$(( ( $(date -d "${exp}" +%s 2>/dev/null || date +%s) - $(date +%s) ) / 86400 ))
  if [ "${days}" -lt "${EXPIRY_WARN_DAYS}" ]; then
    preflight_warn "the ${what} expires in ${days} days (${exp}); renew it"
  else
    echo "${what}: usable, expires ${exp}"
  fi
}

preflight() {
  local bad=0 tok
  echo "preflight: the credentials this night needs"

  # The signer, through its token-guarded /cert: one request proves the
  # address, the TLS certificate and the token together.
  if [ -n "${PULSAR_SIGNER_URL:-}" ] && [ -r "${PULSAR_SIGNER_TOKEN_FILE:-}" ]; then
    local -a ca=()
    [ -s "${PULSAR_SIGNER_CA_FILE:-}" ] && ca=(--cacert "${PULSAR_SIGNER_CA_FILE}")
    if curl -fsS --max-time 20 "${ca[@]}" -o /dev/null \
         -H @"$(auth_header "Authorization: Bearer $(cat "${PULSAR_SIGNER_TOKEN_FILE}")")" \
         "${PULSAR_SIGNER_URL%/}/cert" 2>/dev/null; then
      echo "signer: answers at ${PULSAR_SIGNER_URL}"
    else
      echo "FATAL: the signer at ${PULSAR_SIGNER_URL} did not answer /cert with this token" >&2
      echo "       (address, TLS certificate or token); the nvidia build would fail" >&2
      echo "       on it about twenty-five minutes in" >&2
      bad=1
    fi
  else
    echo "signer: not configured here; not checked"
  fi

  # The registry token, out of the auth file the builder logged in with.
  tok=""
  if [ -r "${REGISTRY_AUTH_FILE:-}" ]; then
    tok="$(jq -r '.auths["ghcr.io"].auth // empty' "${REGISTRY_AUTH_FILE}" 2>/dev/null \
             | base64 -d 2>/dev/null | cut -d: -f2- || true)"
  fi
  if [ -n "${tok}" ]; then
    check_github_token "ghcr.io push token" "${tok}" user packages || bad=1
  else
    echo "ghcr.io token: no REGISTRY_AUTH_FILE login here; not checked"
  fi

  # The site commit's token.
  if [ -r "${PULSAR_GIT_TOKEN_FILE:-}" ]; then
    check_github_token "site commit token" "$(cat "${PULSAR_GIT_TOKEN_FILE}")" \
      "repos/${SITE_REPO_SLUG}" push || bad=1
  else
    echo "site commit token: not configured here; not checked"
  fi

  rm -f "${WORK_TMP}/auth-header" "${WORK_TMP}/gh-headers" "${WORK_TMP}/gh-body"
  return "${bad}"
}

# ---------------------------------------------------------------------------
# Everything after the images are pushed: describe them, then say the night
# is done. An ungated night runs it straight after build.sh and publishes. A
# gated one runs it straight after build.sh too, but STAGED (publish.sh
# --stage): the changelog, the SBOM baseline and the site only move when the
# build host releases it, so they never describe a build that was held back.
# ---------------------------------------------------------------------------
finish_night() {
  # Describe what was just published: SBOMs onto the images, the changelog
  # against last night, the page. Part of the nightly rather than a step after
  # it -- an image nobody can inspect is a blob users are asked to trust, and a
  # night that ships one without saying what changed has not finished.
  case "${PULSAR_PUBLISH:-yes}" in
    no) echo "PULSAR_PUBLISH=no -- images pushed, nothing described" >&2 ;;
    *)
      publish_args=(
        --version "${VERSION}"
        --image "${IMAGE}"
        --image-nvidia "${IMAGE_NVIDIA}"
        --prev-digest "${PREV_DIGEST}"
        --work "${WORK}"
        --branch "${PULSAR_PUBLISH_BRANCH:-main}"
      )
      [ "${PULSAR_PUBLISH:-yes}" = dry-run ] && publish_args+=(--dry-run)
      # Gated, either channel: describe it now, while the images are here,
      # and leave becoming the release to the build host after the boot gate
      # (or to a person promoting it) -- see --stage in publish.sh. Ungated, a
      # manual build describes itself without becoming the baseline the next
      # scheduled build diffs against.
      if [ "${PULSAR_GATE:-0}" = 1 ]; then
        publish_args+=(--stage)
      elif [ "${CHANNEL}" = manual ]; then
        publish_args+=(--no-promote)
      fi
      [ -n "${PULSAR_GIT_TOKEN_FILE:-}" ] \
        && publish_args+=(--git-token-file "${PULSAR_GIT_TOKEN_FILE}")
      publish_args+=(--site-repo "${PULSAR_SITE_REPO}")
      "${REPO}/scripts/publish.sh" "${publish_args[@]}"
      ;;
  esac

  elapsed=$(( $(date -u +%s) - started ))
  echo "pulsar nightly ${VERSION} finished in ${elapsed}s"

  # What the operator who started this needs to know, in one place: it exists, it
  # is pullable, and it changed nothing about what anybody else gets.
  if [ "${CHANNEL}" = manual ]; then
    echo
    echo "manual build ${VERSION}:"
    echo "  pushed        ${IMAGE}:${VERSION}"
    echo "                ${IMAGE_NVIDIA}:${VERSION}"
    echo "  not moved     :latest and :${FEDORA_VERSION} still point at the last scheduled build"
    echo "  not written   the SBOM baseline, the published changelog, the site"
    echo "  boot it       bootc switch ${IMAGE_NVIDIA}:${VERSION}"
  fi

  # NOT pinged on a manual build. This is a dead-man's switch on the TIMER: it
  # alerts by omission, so a hand-run build that pinged it would mark the night as
  # healthy and hide a scheduled run that never happened. The one case where doing
  # less is the whole feature. ping_healthcheck holds that rule for both callers.
  # Staged, the night is not done until the build host releases it, and the
  # host pings then.
  [ "${PULSAR_GATE:-0}" = 1 ] || ping_healthcheck "${VERSION} ok in ${elapsed}s"
}

# One ping, two callers. The dead-man's switch watches the TIMER, so any night
# the timer did its job has to ping -- including a night that looked at the
# base and decided correctly that there was nothing to build. Omission means
# "the nightly did not run", and "the nightly ran and shipped nothing" must not
# borrow that meaning.
ping_healthcheck() {
  local what="$1"
  if [ "${CHANNEL}" = manual ]; then
    echo "manual build: healthcheck not pinged -- it watches the timer, and a ping" >&2
    echo "from here would hide a scheduled run that did not happen." >&2
  elif [ -n "${PULSAR_HEALTHCHECK_URL:-}" ]; then
    # A credential near its expiry rides along, so the ping that says the
    # night was fine also says what will stop being fine.
    [ -z "${PREFLIGHT_WARNINGS}" ] || what+=" -- WARNING: ${PREFLIGHT_WARNINGS}"
    curl -fsS --max-time 20 --retry 3 \
      --data-binary "${what}" \
      "${PULSAR_HEALTHCHECK_URL}" >/dev/null \
      || echo "WARNING: healthcheck ping failed; the run itself succeeded" >&2
  else
    echo "NOTE: PULSAR_HEALTHCHECK_URL unset -- nothing is watching this timer." >&2
  fi
}

# Before anything is built, and before the checks: an unrecognised value is a
# config error, and an absent one is the build host failing to say what this is.
# Either way nothing here may pick for it. See the note in the header.
case "${PULSAR_CHANNEL:-}" in
  scheduled|manual) CHANNEL="${PULSAR_CHANNEL}" ;;
  "")
    echo "PULSAR_CHANNEL is not set, so this build cannot say whether it is the" >&2
    echo "one users pull or one somebody started by hand. Refusing to guess:" >&2
    echo "set PULSAR_CHANNEL=scheduled|manual in /etc/pulsar/build.env." >&2
    exit 2 ;;
  *)
    echo "PULSAR_CHANNEL=${PULSAR_CHANNEL} is not scheduled or manual" >&2
    exit 2 ;;
esac

# AN ARGUMENT THIS DOES NOT KNOW IS A STOP, not a shrug. Until it was, every
# one of them was silently discarded and the run continued as if the operator
# had typed nothing -- which is the worst available reading of what they meant:
#
#   nightly.sh --manual      builds SCHEDULED, because the channel comes from
#                            PULSAR_CHANNEL and the flag went nowhere. Consumes
#                            a number in the published series, moves :latest
#                            and :${FEDORA_VERSION} onto a build somebody
#                            kicked off while working, and overwrites the SBOM
#                            baseline the next night diffs against -- the exact
#                            three things the channel exists to keep apart.
#   nightly.sh --base-heck   RUNS A FULL BUILD AND PUBLISHES IT, because the
#                            typo is not --base-check. A misspelled read-only
#                            question became a release.
#
# The header above says the channel is the one thing this script will not
# guess, and an unset PULSAR_CHANNEL is a hard stop for that reason. Swallowing
# an argument is the same guess made one layer out, so it gets the same answer.
# 2, matching the channel guards: a config error rather than a broken run.
#
# 2026-09-02: spawn-builder.sh had this bug in its loud form, dying on "unknown
# argument: --manual", and a manual build could not be triggered at all until
# it was fixed. This is the quiet form of it, which is worse -- it would have
# published.
if [ "$#" -gt 1 ]; then
  echo "nightly.sh takes at most one argument and got $#: $*" >&2
  exit 2
fi
case "${1:-}" in
  ""|--base-check|--preflight) ;;
  --manual|--scheduled|--channel*)
    # The flag a person reaches for, named here because reaching for it is
    # reasonable and the answer is one line away.
    echo "there is no ${1} flag: the channel is PULSAR_CHANNEL." >&2
    echo "  a build on this host:  PULSAR_CHANNEL=manual ${0##*/}" >&2
    echo "  a build on a builder:  spawn-builder.sh --manual, on helios" >&2
    exit 2 ;;
  *)
    echo "unknown argument: ${1}" >&2
    echo "nightly.sh takes --base-check, --preflight, or no argument at all." >&2
    exit 2 ;;
esac

# Ask the gate and stop, building nothing. For the operator wondering why last
# night was quiet or noisy, and for tests/nightly-base-gate.bats, which is the
# reason the mismatch above is now a thing that can fail out loud. 3 rather
# than 1 for "would skip": 1 is a broken run and 2 is a config error, and this
# is neither.
if [ "${1:-}" = --preflight ]; then
  preflight && exit 0
  exit 1
fi

PULSAR_ADDONS_HASH="$(addons_fingerprint)"
export PULSAR_ADDONS_HASH

if [ "${1:-}" = --base-check ]; then
  if anything_moved; then echo "would build"; exit 0; fi
  echo "would skip"
  exit 3
fi

started="$(date -u +%s)"
echo "pulsar nightly starting $(date -u -Iseconds) (${CHANNEL})"

# The checkout belongs to whatever spawned this: the builder's cloud-init
# clones this repo at an explicit ref, so re-fetching here would silently
# build something other than what was asked for. Just say what is being built.
echo "building $(git rev-parse --short HEAD): $(git log -1 --pretty=%s)"

# A manual build is allowed to run from a dirty checkout -- it makes no site
# commit, and building what you just edited is usually the whole reason for
# starting one.
# It is not allowed to be silent about it: the line above stops describing what
# was built, and the version tag outlives that fact.
if [ "${CHANNEL}" = manual ] && ! git diff --quiet HEAD 2>/dev/null; then
  echo "WARNING: the worktree is dirty, so the commit above does not describe" >&2
  echo "         what is in this image. The tag will outlive that." >&2
fi

# The old on-push CI, run here now that there is no on-push anything: lint
# and tests gate the build, so a broken script on main is a failed nightly
# the same evening rather than a latent surprise. Forty seconds against an
# hour-long build.
"${REPO}/scripts/check.sh"

preflight || { echo "preflight failed: fix the credential above; nothing was built" >&2; exit 1; }

# AFTER check.sh, on purpose. Those forty seconds are what turns a broken
# script on main into a failed nightly the same evening, and a quiet night is
# still a night that should notice. Before next-version.sh, equally on purpose:
# a build that does not happen must not consume a number in the published
# series.
if ! anything_moved; then
  elapsed=$(( $(date -u +%s) - started ))
  echo
  # The build host scrapes this line to record the night as skipped, the way
  # it scrapes "this build is" for the version below: `grep -q '^no build
  # tonight: '`. Keep the prefix exactly. Without it a skip reaches helios as a
  # success with no version, which is also what a log that lost its version
  # line looks like -- and the site cannot say "skipped" on a guess.
  echo "no build tonight: base, repo and add-ons unchanged"
  echo "nothing to build: nothing this image is made from has moved, so the"
  echo "published build is still current. Skipping tonight."
  echo "  published    $(oras resolve "${IMAGE}:latest" 2>/dev/null || echo '<unknown>')"
  echo "  to override  PULSAR_FORCE_BUILD=yes"
  ping_healthcheck "no build in ${elapsed}s: base, repo and add-ons unchanged"
  exit 0
fi

VERSION="$("${REPO}/scripts/next-version.sh" \
  --fedora "${FEDORA_VERSION}" --channel "${CHANNEL}" "${IMAGE}")"
# The build host scrapes this line for the version, so its shape is a contract:
# `grep -oP '^this build is \K.*'`. Keep the prefix exactly. The channel goes on
# its own line rather than into this one for the same reason.
echo "this build is ${VERSION}"
echo "channel: ${CHANNEL}"

# MUST happen before the build. This is the image tonight's changelog says it
# came from, and the push below moves :latest onto the new one -- after that
# the outgoing digest is only recoverable if someone wrote it down, and this
# is the someone. Empty on the very first run, which is the baseline case and
# not an error.
#
# On a manual build the push does NOT move :latest, so this resolves the last
# scheduled build and stays true afterwards. That is what makes a manual
# changelog worth reading: it diffs against what users are actually running.
PREV_DIGEST="$(oras resolve "${IMAGE}:latest" 2>/dev/null || true)"
echo "previous :latest digest: ${PREV_DIGEST:-<none, first build>}"

build_args=(
  --variant all
  --version "${VERSION}"
  --image "${IMAGE}"
  --image-nvidia "${IMAGE_NVIDIA}"
  --signer-url "${PULSAR_SIGNER_URL:?PULSAR_SIGNER_URL is not set}"
  --signer-token-file "${PULSAR_SIGNER_TOKEN_FILE:?PULSAR_SIGNER_TOKEN_FILE is not set}"
  --signer-ca-file "${PULSAR_SIGNER_CA_FILE:?PULSAR_SIGNER_CA_FILE is not set}"
  --work "${WORK}"
  --push
)
# :latest and :44 are what a machine follows on its next bootc upgrade. A
# debugging build must not become that, so it publishes its version tag and
# nothing else. build.sh also refuses to move the floating tags onto a -dev
# version even if this line is ever dropped.
[ "${CHANNEL}" = manual ] && build_args+=(--no-floating-tags)
# Gated, the floating tags wait for the boot gate; the build host moves them.
[ "${PULSAR_GATE:-0}" = 1 ] && [ "${CHANNEL}" != manual ] && build_args+=(--no-floating-tags)
"${REPO}/scripts/build.sh" "${build_args[@]}"

# THE BOOT GATE. With PULSAR_GATE=1 (the builder's build.env sets it) the
# floating tags do not move here. The night describes itself now, staged
# (SBOMs, changelog, the site commit on release/<version>), and stops: the
# build host boots each image on a throwaway VM and, when both pass, moves
# the tags, the R2 pointers and the site itself. The builder is not needed
# for that and is deleted as soon as this line is printed -- keep its shape.
if [ "${PULSAR_GATE:-0}" = 1 ]; then
  finish_night
  echo "gate: pending ${VERSION}"
  exit 0
fi

finish_night

}

main "$@"
