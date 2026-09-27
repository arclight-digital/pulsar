#!/usr/bin/env bats
# The release order: both variants built, checked and pushed under their
# version before either floating tag moves.
#
# build.sh used to move vanilla's :latest before nvidia had even started
# building, so a night whose nvidia half failed left every vanilla machine a
# build ahead of every nvidia one, for as long as nvidia kept failing. It now
# pushes version tags only, and promotes both at the end. And vanilla's
# checks and upload run while nvidia builds, instead of before it.
#
# The harness is build.sh from a copy of the tree, with podman and skopeo as
# stubs that write down what they were asked to do. The rechunk stub writes a
# real OCI layout carrying the version in os-release, so the content check
# runs for real rather than being stubbed past.

bats_require_minimum_version 1.5.0

VERSION=44.20260927.0

setup() {
  for v in "${!PULSAR_@}"; do unset "${v}"; done
  BIN="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${BIN}"
  PATH="${BIN}:${PATH}"
  TREE="${BATS_TEST_TMPDIR}/tree"; mkdir -p "${TREE}/scripts"
  cp "${BATS_TEST_DIRNAME}/../scripts/build.sh" "${TREE}/scripts/"
  : > "${TREE}/Containerfile"; : > "${TREE}/Containerfile.nvidia"
  export EVENTS="${BATS_TEST_TMPDIR}/events"; : > "${EVENTS}"
  printf '#!/usr/bin/env bash\necho "diff ${3##*/}" >> "%s"\n' "${EVENTS}" > "${TREE}/scripts/diff-chunk-metadata.sh"
  chmod +x "${TREE}/scripts/"*.sh
  export STORE="${BATS_TEST_TMPDIR}/store"; mkdir -p "${STORE}"
  export WORKDIR="${BATS_TEST_TMPDIR}/work"
  export TOKEN="${BATS_TEST_TMPDIR}/token"; echo t > "${TOKEN}"
  export FAIL_NVIDIA_BUILD=no FAIL_VANILLA_PUSH=no
  printf '#!/usr/bin/env bash\nexit 1\n' > "${BIN}/mokutil"; chmod +x "${BIN}/mokutil"
  stub_podman; stub_skopeo
}

stub_podman() {
  cat > "${BIN}/podman" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  info)
    case "$*" in
      *GraphRoot*) echo "${STORE}" ;;
      *RunRoot*)   echo "${STORE}/run" ;;
      *Driver*)    echo overlay ;;
    esac ;;
  build)
    file=; for a in "$@"; do case "${prev}" in --file) file="${a}" ;; esac; prev="${a}"; done
    case "${file}" in
      *nvidia) echo "build nvidia start" >> "${EVENTS}"
               sleep 1
               [ "${FAIL_NVIDIA_BUILD}" = no ] || { echo "build nvidia FAILED" >> "${EVENTS}"; exit 1; }
               echo "build nvidia done" >> "${EVENTS}" ;;
      *)       echo "build vanilla" >> "${EVENTS}" ;;
    esac ;;
  image)
    case "$2" in exists) exit 0 ;; inspect) echo "sha256:base" ;; esac ;;
  run)
    out=; ver=
    for a in "$@"; do
      case "${a}" in
        oci:*) out="${a#oci:}"; out="${out%:build}" ;;
        org.opencontainers.image.version=*) ver="${a#*=}" ;;
      esac
    done
    echo "rechunk ${out##*/}" >> "${EVENTS}"
    d="$(mktemp -d)"; mkdir -p "${d}/usr/lib"
    printf 'NAME="Pulsar"\nVERSION="%s"\n' "${ver}" > "${d}/usr/lib/os-release"
    tar -C "${d}" -cf "${out}/blobs/sha256/layer" usr ;;
  images) ;;
esac
exit 0
STUB
  chmod +x "${BIN}/podman"
}

stub_skopeo() {
  cat > "${BIN}/skopeo" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  inspect)
    case "$*" in
      # a layout's manifest: one text per slot, so its digest is predictable
      *--raw*oci:*) l="${*##*oci:}"; l="${l%:build}"; printf 'manifest-%s\n' "${l##*/}" ;;
      *--raw*) echo "manifest unknown"; exit 1 ;;   # the version tag is free
      *oci:*)  echo '{"Layers":["a"]}' ;;
    esac ;;
  copy)
    df=; dst=; src=
    while [ $# -gt 0 ]; do
      case "$1" in --digestfile) df="$2"; shift ;; docker://*) dst="${1#docker://}" ;; oci:*) src="${1#oci:}" ;; esac
      shift
    done
    tag="${dst##*:}"
    case "${dst}" in *pulsar:"${VERSION_UNDER_TEST}")
      # Vanilla's upload. Does it overlap the nvidia build? Wait a little for
      # the build to have started; a serial flow never starts it first.
      for _ in $(seq 1 40); do grep -q 'build nvidia start' "${EVENTS}" && break; sleep 0.1; done
      grep -q 'build nvidia start' "${EVENTS}" || echo "vanilla push without overlap" >> "${EVENTS}"
      [ "${FAIL_VANILLA_PUSH}" = no ] || { echo "copy ${dst} FAILED" >> "${EVENTS}"; exit 1; } ;;
    esac
    echo "copy ${dst}" >> "${EVENTS}"
    # what a registry reports: the digest of the manifest it was given
    src="${src%:build}"
    echo "sha256:$(printf 'manifest-%s\n' "${src##*/}" | sha256sum | cut -d' ' -f1)" > "${df}" ;;
esac
exit 0
STUB
  chmod +x "${BIN}/skopeo"
}

build() {
  export VERSION_UNDER_TEST="${VERSION}"
  run --separate-stderr env PULSAR_MIN_FREE_GB=0 "${TREE}/scripts/build.sh" \
    --variant all --version "${VERSION}" --push --no-wallpapers \
    --image ghcr.io/arclight-digital/pulsar --image-nvidia ghcr.io/arclight-digital/pulsar-nvidia \
    --signer-url http://10.0.0.5:8443 --signer-token-file "${TOKEN}" \
    --work "${WORKDIR}" "$@"
}

line_of() { grep -n -m1 -F -- "$1" "${EVENTS}" | cut -d: -f1; }

# A negated grep fails a bats test only on its last line -- bats does not
# apply errexit to a negated command -- so absence is asserted explicitly.
no_event() {
  if grep -qE -- "$1" "${EVENTS}"; then
    echo "unexpected event matching: $1" >&2
    cat "${EVENTS}" >&2
    return 1
  fi
}

@test "both version tags are pushed before either floating tag moves" {
  build
  [ "$status" -eq 0 ] || { cat "${EVENTS}"; echo "$stderr"; false; }
  v="$(line_of "copy ghcr.io/arclight-digital/pulsar:${VERSION}")"
  n="$(line_of "copy ghcr.io/arclight-digital/pulsar-nvidia:${VERSION}")"
  first_float="$(grep -n -m1 -E 'copy .*:(latest|44)$' "${EVENTS}" | cut -d: -f1)"
  [ -n "$v" ] && [ -n "$n" ] && [ -n "$first_float" ]
  [ "$first_float" -gt "$v" ] && [ "$first_float" -gt "$n" ]
  grep -qx 'copy ghcr.io/arclight-digital/pulsar:latest' "${EVENTS}"
  grep -qx 'copy ghcr.io/arclight-digital/pulsar-nvidia:latest' "${EVENTS}"
  grep -qx 'copy ghcr.io/arclight-digital/pulsar:44' "${EVENTS}"
  grep -qx 'copy ghcr.io/arclight-digital/pulsar-nvidia:44' "${EVENTS}"
}

@test "REGRESSION: an nvidia build that fails moves no floating tag at all" {
  # The split release: vanilla's :latest used to move before nvidia built.
  FAIL_NVIDIA_BUILD=yes build
  [ "$status" -ne 0 ]
  no_event 'copy .*:(latest|44)$'
}

@test "a vanilla push that fails moves no floating tag either" {
  FAIL_VANILLA_PUSH=yes build
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"vanilla failed its checks or its push"* ]]
  no_event 'copy .*:(latest|44)$'
}

@test "vanilla ships while nvidia builds, and is done before the nvidia rechunk" {
  build
  [ "$status" -eq 0 ]
  no_event 'vanilla push without overlap'
  [ "$(line_of "copy ghcr.io/arclight-digital/pulsar:${VERSION}")" -lt "$(line_of 'rechunk nvidia')" ]
  # and the rechunks themselves never overlap anything: vanilla's precedes
  # the nvidia build it would otherwise share the store with
  [ "$(line_of 'rechunk vanilla')" -lt "$(line_of 'build nvidia start')" ]
}

@test "vanilla's log is printed whole, not interleaved with nvidia's" {
  build
  [ "$status" -eq 0 ]
  [[ "$output" == *"vanilla checks and push, which ran alongside the nvidia build:"* ]]
  [[ "$output" == *"chunked vanilla content confirmed: ${VERSION}"* ]]
}

@test "--no-floating-tags pushes version tags and moves nothing" {
  build --no-floating-tags
  [ "$status" -eq 0 ]
  grep -qx "copy ghcr.io/arclight-digital/pulsar:${VERSION}" "${EVENTS}"
  grep -qx "copy ghcr.io/arclight-digital/pulsar-nvidia:${VERSION}" "${EVENTS}"
  no_event 'copy .*:(latest|44)$'
}

# ---------------------------------------------------------------------------
# --promote-only: the second half of a gated night. The first half pushed
# version tags and stopped; a VM booted them; this moves the floating tags
# onto exactly what was booted, and builds nothing.
# ---------------------------------------------------------------------------

promote_only() {
  run --separate-stderr env PULSAR_MIN_FREE_GB=0 "${TREE}/scripts/build.sh" \
    --promote-only --variant all --image ghcr.io/arclight-digital/pulsar \
    --image-nvidia ghcr.io/arclight-digital/pulsar-nvidia --work "${WORKDIR}" "$@"
}

gated_build() {
  build --no-floating-tags
  [ "$status" -eq 0 ] || { cat "${EVENTS}"; echo "$stderr"; false; }
  : > "${EVENTS}"
}

@test "--promote-only moves both floating tags and builds nothing" {
  gated_build
  promote_only --version "${VERSION}"
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  for t in latest 44; do
    grep -qx "copy ghcr.io/arclight-digital/pulsar:${t}" "${EVENTS}"
    grep -qx "copy ghcr.io/arclight-digital/pulsar-nvidia:${t}" "${EVENTS}"
  done
  no_event '^(build|rechunk)'
  no_event "copy .*:${VERSION}\$"
}

@test "--promote-only refuses a layout that is not the version it was asked for" {
  gated_build
  promote_only --version 44.20260928.0
  [ "$status" -ne 0 ]
  no_event 'copy '
}

@test "--promote-only refuses a layout that is not the digest that was gated" {
  gated_build
  echo "sha256:0000000000000000000000000000000000000000000000000000000000000000" > "${WORKDIR}/digest-nvidia"
  promote_only --version "${VERSION}"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"what was pushed and gated"* ]]
  # nothing at all: checking nvidia after promoting vanilla would be the
  # split release again
  no_event 'copy '
}

@test "--promote-only with nothing built refuses" {
  promote_only --version "${VERSION}"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"nothing was built here to promote"* ]]
}

@test "--promote-only with --no-floating-tags moves nothing" {
  gated_build
  promote_only --version "${VERSION}" --no-floating-tags
  [ "$status" -eq 0 ]
  no_event 'copy '
}

@test "--promote-only requires --version" {
  promote_only
  [ "$status" -eq 2 ]
}
