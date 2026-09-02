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
# THEN IT SHIPPED A NIGHT OF ZEROS AGAIN, on 2026-08-19, through a comparison
# that was by then working correctly. quay rebuilds silverblue:44 nightly and
# pushes it whether or not the compose resolved one different package, so the
# digest is new most mornings around a package set that is not. No hash of the
# image tells those apart -- new manifest, new config, new ostree commit, seven
# new layers of two hundred and fifty-seven. rpmostree.inputhash does, being a
# hash of the compose inputs rather than of its output, and the second half of
# this file is about reading it off the right image and failing open when it
# is not there.
#
# The harness is stubs on PATH -- the gate's only facts are a few skopeo calls
# and podman's arch, the idiom next-version.bats and greenboot.bats use.

bats_require_minimum_version 1.5.0

AMD64_NOW='sha256:1111111111111111111111111111111111111111111111111111111111111111'
AMD64_NEW='sha256:2222222222222222222222222222222222222222222222222222222222222222'
ARM64_NOW='sha256:3333333333333333333333333333333333333333333333333333333333333333'
ARM64_NEW='sha256:4444444444444444444444444444444444444444444444444444444444444444'
# The compose inputs behind them. Not sha256-shaped on purpose: rpm-ostree
# writes a bare hex hash with no algorithm prefix, and a test that pretends
# otherwise would pass over a gate that assumed the prefix.
INPUT_NOW='325448aa939fc7105df48a13af691d63dbfc970360d09da5506061fb1f1395eb'
INPUT_NEW='9cfda41f0554e83935b3e058ec8205d1d7b5af1fdd1c9e81f676ba66cab7925e'

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
  # Every reference the gate resolves, in order. Which image a label was read
  # off is half of what went wrong here twice, so it is asserted rather than
  # assumed.
  REFS="${BATS_TEST_TMPDIR}/refs.log"
  : > "${REFS}"
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

# The registry, as three answers:
#   $1 the base-digest label on the published image, empty for absent
#   $2 the base-inputhash label on the published image, empty for absent
#   $3 the rpmostree.inputhash the base images carry, empty for absent
# An absent label is an absent KEY here, which is what a registry serves and
# what jq reads as null. The gate no longer asks for one label at a time.
#
# The base TAG answers --raw and NOTHING else. A non-raw inspect of it is the
# old broken question, and this stub refuses it so that reintroducing the call
# fails these tests rather than quietly comparing an index against an instance
# again. The base BY DIGEST is a different question and answers labels: that
# is the instance the gate resolved out of the index, and reading the input
# hash off it -- rather than off the tag, which would resolve who knows what
# by the time it is asked -- is the point of the second comparison.
stub_skopeo() {
  local published base
  published="$(jq -nc --arg d "${1:-}" --arg h "${2:-}" '{Labels: ({}
    | if $d == "" then . else .["digital.arclight.pulsar.base-digest"] = $d end
    | if $h == "" then . else .["digital.arclight.pulsar.base-inputhash"] = $h end)}')"
  base="$(jq -nc --arg h "${3:-}" '{Labels: ({}
    | if $h == "" then . else .["rpmostree.inputhash"] = $h end)}')"
  cat > "${BIN}/skopeo" <<EOF
#!/usr/bin/env bash
raw=no ref=
for a in "\$@"; do
  case "\${a}" in
    --raw)      raw=yes ;;
    docker://*) ref="\${a}" ;;
  esac
done
printf '%s\n' "\${ref}" >> '${REFS}'
case "\${ref}" in
  *pulsar:latest)
    printf '%s\n' '${published}'; exit 0 ;;
  *silverblue@sha256:*)
    printf '%s\n' '${base}'; exit 0 ;;
  *silverblue:44)
    [ "\${raw}" = yes ] || { echo "asked the base tag for a digest, not a manifest" >&2; exit 1; }
    exec cat '${MANIFEST}' ;;
esac
exit 1
EOF
  chmod +x "${BIN}/skopeo"
}

# Which references the gate inspected, one per line.
inspected() { cat "${REFS}"; }

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
  stub_skopeo ""
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


# ---------------------------------------------------------------------------
# The second failure: the digest moved and it meant nothing. 2026-08-19.
# ---------------------------------------------------------------------------

@test "a rebuilt base that composed the same packages is not a reason to build" {
  # The regression, in the shape it actually shipped: quay's nightly rebuild
  # of silverblue:44 moved every hash on the image around a package set that
  # did not change, and the gate above it voted to build, correctly, on the
  # wrong question.
  write_index "${AMD64_NEW}" "${ARM64_NOW}"
  stub_skopeo "${AMD64_NOW}" "${INPUT_NOW}" "${INPUT_NOW}"
  check
  [ "$status" -eq 3 ]
  [[ "$output" == *"would skip"* ]]
  [[ "$output" == *"same packages"* ]]
  [[ "$output" == *"${INPUT_NOW}"* ]]
}

@test "a rebuilt base that resolved different packages builds" {
  write_index "${AMD64_NEW}" "${ARM64_NOW}"
  stub_skopeo "${AMD64_NOW}" "${INPUT_NOW}" "${INPUT_NEW}"
  check
  [ "$status" -eq 0 ]
  [[ "$output" == *"would build"* ]]
  # The pair in the log, for the same reason the digests are in it.
  [[ "$output" == *"${INPUT_NOW} -> ${INPUT_NEW}"* ]]
}

@test "the input hash is read off the arch instance, not off the tag" {
  # Reading it off silverblue:44 would be the first bug wearing a new hat: the
  # tag is an index, and whatever a registry hands back for a non-raw inspect
  # of one is not necessarily the image this build pulls.
  write_index "${AMD64_NEW}" "${ARM64_NOW}"
  stub_skopeo "${AMD64_NOW}" "${INPUT_NOW}" "${INPUT_NOW}"
  check
  [ "$status" -eq 3 ]
  [[ "$(inspected)" == *"silverblue@${AMD64_NEW}"* ]]
}

@test "the input hash is not fetched at all when the digest already matches" {
  # It costs a round trip the digest comparison does not, and the digest
  # matching is a complete answer on its own.
  write_index "${AMD64_NOW}" "${ARM64_NOW}"
  stub_skopeo "${AMD64_NOW}" "${INPUT_NOW}" "${INPUT_NOW}"
  check
  [ "$status" -eq 3 ]
  [[ "$(inspected)" != *"silverblue@"* ]]
}

@test "builds when the published image records no input hash" {
  # Every image built before build.sh started writing the label, which is the
  # night this change lands. One rebuild, then it has a hash to compare.
  write_index "${AMD64_NEW}" "${ARM64_NOW}"
  stub_skopeo "${AMD64_NOW}" "" "${INPUT_NOW}"
  check
  [ "$status" -eq 0 ]
  [[ "$output" == *"would build"* ]]
}

@test "builds when the base carries no input hash to compare against" {
  write_index "${AMD64_NEW}" "${ARM64_NOW}"
  stub_skopeo "${AMD64_NOW}" "${INPUT_NOW}" ""
  check
  [ "$status" -eq 0 ]
  [[ "$output" == *"<unreadable>"* ]]
}

@test "an unchanged input hash does not override a base that never moved" {
  # Ordering, stated as a test: a matching digest returns before the input
  # hash is consulted, so a base that is bit for bit where it was skips on the
  # cheap answer and the expensive one is never asked.
  write_index "${AMD64_NOW}" "${ARM64_NOW}"
  stub_skopeo "${AMD64_NOW}" "${INPUT_NOW}" "${INPUT_NEW}"
  check
  [ "$status" -eq 3 ]
  [[ "$output" == *"is still ${AMD64_NOW}"* ]]
}

@test "PULSAR_FORCE_BUILD=yes builds through a matching input hash too" {
  write_index "${AMD64_NEW}" "${ARM64_NOW}"
  stub_skopeo "${AMD64_NOW}" "${INPUT_NOW}" "${INPUT_NOW}"
  export PULSAR_FORCE_BUILD=yes
  check
  [ "$status" -eq 0 ]
}
