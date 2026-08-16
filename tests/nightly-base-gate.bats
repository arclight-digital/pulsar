#!/usr/bin/env bats
# The "is there anything to build tonight" gate, which shipped broken.
#
# It went in on 2026-08-14 to stop a night where no package moved from becoming
# a notification and a multi-gigabyte pull on every machine. It then did that
# exact thing on 2026-08-15 and again on 2026-08-16: same base, same package
# set, new digest, everyone notified.
#
# The cause is a shape mismatch no amount of reading the code out loud catches,
# because both halves are correct on their own. silverblue:44 is a multi-arch
# index. build.sh records what podman pulled, which is the per-arch manifest
# INSIDE that index; base_moved() asked skopeo for the tag's digest, which is
# the index ITSELF. Two different sha256s of two different documents, never
# equal, so the gate voted "moved" every night and said so in the log.
#
# So these tests are about digest SHAPES above all else, and the first one is
# the regression: the recorded label is an arch instance, the base has not
# moved, and the night must be skipped. `nightly.sh --base-check` exists to
# make that question askable without a build attached to the answer.
#
# The harness is stubs on PATH -- the gate's only facts are two skopeo calls
# and podman's arch, the idiom next-version.bats and greenboot.bats use.

bats_require_minimum_version 1.5.0

AMD64_NOW='sha256:1111111111111111111111111111111111111111111111111111111111111111'
AMD64_NEW='sha256:2222222222222222222222222222222222222222222222222222222222222222'
ARM64_NOW='sha256:3333333333333333333333333333333333333333333333333333333333333333'
ARM64_NEW='sha256:4444444444444444444444444444444444444444444444444444444444444444'

setup() {
  # The builder puts PULSAR_* in /etc/pulsar/build.env and a hand-run test
  # inherits them: PULSAR_CHANNEL=manual alone would make every assertion below
  # pass for the wrong reason, since a manual build is not gated at all.
  for v in "${!PULSAR_@}"; do unset "${v}"; done

  NIGHTLY="${BATS_TEST_DIRNAME}/../scripts/nightly.sh"
  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${BIN}"
  PATH="${BIN}:${PATH}"

  export IMAGE=ghcr.io/arclight-digital/pulsar
  export IMAGE_NVIDIA=ghcr.io/arclight-digital/pulsar-nvidia
  export BASE_IMAGE=quay.io/fedora-ostree-desktops/silverblue
  export FEDORA_VERSION=44
  export PULSAR_CHANNEL=scheduled

  MANIFEST="${BATS_TEST_TMPDIR}/base.json"
  stub_podman amd64
}

# The base tag as quay actually serves it: an index naming one manifest per
# architecture. $1 amd64 digest, $2 arm64 digest.
write_index() {
  cat > "${MANIFEST}" <<EOF
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[
{"mediaType":"application/vnd.oci.image.manifest.v1+json","size":1234,"digest":"$1","platform":{"architecture":"amd64","os":"linux"}},
{"mediaType":"application/vnd.oci.image.manifest.v1+json","size":1234,"digest":"$2","platform":{"architecture":"arm64","os":"linux"}}]}
EOF
}

# A tag that is a plain image manifest rather than an index, which is what the
# gate must fall back to reading whole.
write_manifest() {
  cat > "${MANIFEST}" <<'EOF'
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"digest":"sha256:cafe","size":1},"layers":[]}
EOF
}

# What a registry would call the bytes in ${MANIFEST}: the sha256 of the
# document exactly as served. The gate computes this the same way, so a test
# asserting on it is asserting on the real rule and not on a shared constant.
manifest_digest() {
  echo "sha256:$(sha256sum < "${MANIFEST}" | cut -d' ' -f1)"
}

# $1 = the base-digest label on the published image. `<no value>` is what the
# Go template prints when the label is absent, so it is spelled out rather
# than approximated with an empty string.
#
# The base tag answers --raw and NOTHING else. A non-raw inspect of it is the
# old broken question, and this stub refuses it so that reintroducing the call
# fails these tests rather than quietly comparing an index against an instance
# again.
stub_skopeo() {
  cat > "${BIN}/skopeo" <<EOF
#!/usr/bin/env bash
raw=no ref=
for a in "\$@"; do
  case "\${a}" in
    --raw)      raw=yes ;;
    docker://*) ref="\${a}" ;;
  esac
done
case "\${ref}" in
  *pulsar:latest)
    printf '%s\n' '${1}'; exit 0 ;;
  *silverblue:44)
    [ "\${raw}" = yes ] || { echo "asked the base tag for a digest, not a manifest" >&2; exit 1; }
    exec cat '${MANIFEST}' ;;
esac
exit 1
EOF
  chmod +x "${BIN}/skopeo"
}

stub_podman() {
  printf '#!/usr/bin/env bash\nprintf %%s\\\\n %s\n' "$1" > "${BIN}/podman"
  chmod +x "${BIN}/podman"
}

check() {
  run --separate-stderr "${NIGHTLY}" --base-check
}

@test "skips when the recorded arch instance still is what the tag resolves to" {
  write_index "${AMD64_NOW}" "${ARM64_NOW}"
  stub_skopeo "${AMD64_NOW}"
  check
  [ "$status" -eq 3 ]
  [[ "$output" == *"would skip"* ]]
}

@test "builds when the arch instance moved" {
  write_index "${AMD64_NEW}" "${ARM64_NOW}"
  stub_skopeo "${AMD64_NOW}"
  check
  [ "$status" -eq 0 ]
  [[ "$output" == *"would build"* ]]
  # Both digests in the line, because the pair is what made this diagnosable.
  [[ "$output" == *"${AMD64_NOW}"* ]]
  [[ "$output" == *"${AMD64_NEW}"* ]]
}

@test "an arm64-only respin is not a reason to build" {
  # The index digest moves because one of its entries did. Nothing this build
  # pulls changed, and comparing indexes rather than instances would ship it.
  write_index "${AMD64_NOW}" "${ARM64_NOW}"
  local before; before="$(manifest_digest)"
  write_index "${AMD64_NOW}" "${ARM64_NEW}"
  [ "$(manifest_digest)" != "${before}" ]
  stub_skopeo "${AMD64_NOW}"
  check
  [ "$status" -eq 3 ]
}

@test "follows the build host's architecture, not amd64 by assumption" {
  write_index "${AMD64_NEW}" "${ARM64_NOW}"
  stub_podman arm64
  stub_skopeo "${ARM64_NOW}"
  check
  [ "$status" -eq 3 ]
}

@test "a label carrying the index digest is still a match" {
  # Not what build.sh writes today. If it ever does -- another podman, another
  # way of reading it back -- the gate must not start shipping nightly zeros
  # again while both sides look right.
  write_index "${AMD64_NOW}" "${ARM64_NOW}"
  stub_skopeo "$(manifest_digest)"
  check
  [ "$status" -eq 3 ]
}

@test "a base tag that is a plain manifest compares whole" {
  write_manifest
  stub_skopeo "$(manifest_digest)"
  check
  [ "$status" -eq 3 ]
}

@test "builds when the published image records no base digest" {
  write_index "${AMD64_NOW}" "${ARM64_NOW}"
  stub_skopeo '<no value>'
  check
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"records no base digest"* ]]
}

@test "builds when the base cannot be resolved" {
  rm -f "${MANIFEST}"
  stub_skopeo "${AMD64_NOW}"
  check
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"could not resolve"* ]]
}

@test "an index that omits its mediaType is still an index" {
  # OCI does not require it, and reading one as a plain manifest is exactly
  # the misidentification this whole file is about.
  cat > "${MANIFEST}" <<EOF
{"schemaVersion":2,"manifests":[
{"size":1234,"digest":"${AMD64_NOW}","platform":{"architecture":"amd64","os":"linux"}}]}
EOF
  stub_skopeo "${AMD64_NOW}"
  check
  [ "$status" -eq 3 ]
}

@test "builds when there is no skopeo to ask with" {
  write_index "${AMD64_NOW}" "${ARM64_NOW}"
  stub_skopeo "${AMD64_NOW}"
  rm -f "${BIN}/skopeo"
  # A PATH with everything the gate needs except the one tool under test. The
  # stubs stay first, so podman is still answered.
  local sandbox="${BATS_TEST_TMPDIR}/nosk" t
  mkdir -p "${sandbox}"
  for t in bash jq mktemp rm cat cut sha256sum; do
    ln -sf "$(command -v "${t}")" "${sandbox}/${t}"
  done
  PATH="${BIN}:${sandbox}" check
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no skopeo"* ]]
}

@test "PULSAR_FORCE_BUILD=yes builds a night that would have been skipped" {
  write_index "${AMD64_NOW}" "${ARM64_NOW}"
  stub_skopeo "${AMD64_NOW}"
  export PULSAR_FORCE_BUILD=yes
  check
  [ "$status" -eq 0 ]
}

@test "a manual build is not gated on the base at all" {
  write_index "${AMD64_NOW}" "${ARM64_NOW}"
  stub_skopeo "${AMD64_NOW}"
  export PULSAR_CHANNEL=manual
  check
  [ "$status" -eq 0 ]
  [[ "$output" == *"not gated"* ]]
}
