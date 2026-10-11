#!/usr/bin/env bats
# rpm-sbom.sh: the SBOM attached to every published image, and what
# `pulsar sbom` prints on a running system.
#
# It replaced syft, which needed more than 16GB to scan this image, so this
# file rather than a widely used scanner is what has to emit valid SPDX. Its
# output feeds publish.sh's package-count check, sbom-changelog.sh's diff and
# anyone running `oras discover` on an image, and until this file nothing ran
# it: publish-stage.bats replaces it with a stub.
#
# podman and rpm are stubs, and what they answer is real. The package lines
# below were printed by rpm 6.0.2 on Fedora 44 with the script's own --qf:
# tab-separated, "(none)" for a missing epoch, and gpg-pubkey with "(none)" for
# its arch and "pubkey" for its license, which is how rpm lists an imported
# signing key. The stub refuses any other query format, so a change to the
# query cannot keep passing against output it would no longer get.

bats_require_minimum_version 1.5.0

DIGEST_REAL='sha256:05e3c351a7e762aca8fb067a9a92c1f775a7c4fbb1382c97cdd87bd6fb5b162c'
REF=ghcr.io/arclight-digital/pulsar:44

setup() {
  SBOM="${BATS_TEST_DIRNAME}/../scripts/rpm-sbom.sh"
  BIN="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${BIN}"; PATH="${BIN}:${PATH}"
  export CALLS="${BATS_TEST_TMPDIR}/calls"; : > "${CALLS}"
  unset SOURCE_DATE_EPOCH CONTAINER_RUNTIME

  # The database. A signed-key pair, an epoch on two packages, a noarch one,
  # and libstdc++, whose name is not a legal SPDX id as it stands.
  export RPMDB="${BATS_TEST_TMPDIR}/rpmdb"
  {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      bash '(none)' 5.3.9 3.fc44 x86_64 'GPL-3.0-or-later' \
      gpg-pubkey '(none)' e9a491a3de247814e7e067eae06f8ecdd651ff2e 5dadbbc1 '(none)' pubkey \
      fonts-filesystem 1 5.0.0 2.fc44 noarch MIT \
      NetworkManager 1 1.56.1 2.fc44 x86_64 'GPL-2.0-or-later AND LGPL-2.1-or-later' \
      gpg-pubkey '(none)' 79bdb88f9bbf73910fd4095b6a2af96194843c65 5dadbc64 '(none)' pubkey \
      libstdc++ '(none)' 16.2.1 2.fc44 x86_64 'GPL-3.0-or-later AND LGPL-3.0-or-later'
  } > "${RPMDB}"

  # The query exactly as the script writes it: single-quoted, so rpm and not
  # the shell turns these \t and \n into bytes.
  export QF='%{NAME}\t%{EPOCH}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{LICENSE}\n'
  cat > "${BIN}/rpm" <<'EOF'
#!/usr/bin/env bash
echo "rpm $*" >> "${CALLS}"
[ "$1 $2 $3" = "-qa --qf ${QF}" ] || { echo "rpm stub: unexpected query: $*" >&2; exit 1; }
cat "${RPMDB}"
EOF
  # `podman image inspect REF --format '{{.Digest}}'` prints the digest and a
  # newline, or exits 125 for an image it does not have (both checked against
  # podman 5 on Fedora 44). `podman run ... rpm -qa` is the database above.
  cat > "${BIN}/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "${CALLS}"
case "$1" in
  image)
    [ -n "${DIGEST:-}" ] || { echo "Error: $3: image not known" >&2; exit 125; }
    printf '%s\n' "${DIGEST}" ;;
  run)
    shift
    [ "$1 $2 $3" = "--rm --network=none ${REF_WANT}" ] || { echo "podman stub: unexpected run: $*" >&2; exit 1; }
    shift 3
    exec "$@" ;;
  *) exit 125 ;;
esac
EOF
  chmod +x "${BIN}/rpm" "${BIN}/podman"
  export DIGEST="${DIGEST_REAL}" REF_WANT="${REF}"
}

sbom() {
  run --separate-stderr "${SBOM}" "$@"
  [ "$status" -eq 0 ] || { echo "status ${status}: ${stderr}"; return 1; }
  printf '%s\n' "${output}" > "${BATS_TEST_TMPDIR}/sbom.json"
}

# jq over the last document produced
doc() { jq -r "$@" "${BATS_TEST_TMPDIR}/sbom.json"; }

@test "an image is described as an SPDX 2.3 document, one package per rpm" {
  sbom "${REF}"
  [ "$(doc .spdxVersion)" = SPDX-2.3 ]
  [ "$(doc .dataLicense)" = CC0-1.0 ]
  [ "$(doc .SPDXID)" = SPDXRef-DOCUMENT ]
  [ "$(doc .name)" = "${REF}" ]
  [ "$(doc '.creationInfo.creators | join(",")')" = "Tool: pulsar-rpm-sbom,Organization: Arclight" ]
  [ "$(doc '[.packages[].name] | join(" ")')" = "bash fonts-filesystem NetworkManager libstdc++" ]
  # package-only, as the header promises
  [ "$(doc '[.packages[] | select(.filesAnalyzed != false)] | length')" = 0 ]
  [ "$(doc '[.packages[] | .downloadLocation, .licenseConcluded, .copyrightText] | unique | join(",")')" = NOASSERTION ]
}

@test "the signing keys rpm keeps in its database are not packages, and are counted" {
  sbom "${REF}"
  [ "$(doc '[.packages[] | select(.name == "gpg-pubkey")] | length')" = 0 ]
  [[ "$stderr" == *"excluded 2 gpg-pubkey"* ]]
}

@test "an epoch is in the version only when the package has one" {
  # rpm prints "(none)"; an SBOM that kept it would say (none):5.3.9-3.fc44
  # and break every comparison sbom-changelog.sh makes.
  sbom "${REF}"
  [ "$(doc '.packages[] | select(.name == "bash") | .versionInfo')" = 5.3.9-3.fc44 ]
  [ "$(doc '.packages[] | select(.name == "NetworkManager") | .versionInfo')" = 1:1.56.1-2.fc44 ]
  [ "$(doc '.packages[] | select(.name == "fonts-filesystem") | .versionInfo')" = 1:5.0.0-2.fc44 ]
  [ "$(doc '[.packages[].versionInfo | select(contains("none"))] | length')" = 0 ]
}

@test "the purl carries the name, the version and the arch" {
  sbom "${REF}"
  [ "$(doc '.packages[] | select(.name == "bash") | .externalRefs[0].referenceLocator')" = \
    "pkg:rpm/fedora/bash@5.3.9-3.fc44?arch=x86_64" ]
  [ "$(doc '.packages[] | select(.name == "fonts-filesystem") | .externalRefs[0].referenceLocator')" = \
    "pkg:rpm/fedora/fonts-filesystem@1:5.0.0-2.fc44?arch=noarch" ]
}

@test "the declared license is rpm's own license string" {
  sbom "${REF}"
  [ "$(doc '.packages[] | select(.name == "NetworkManager") | .licenseDeclared')" = \
    "GPL-2.0-or-later AND LGPL-2.1-or-later" ]
}

@test "every package has a legal, unique SPDX id, and the document describes each one" {
  sbom "${REF}"
  # SPDX ids are [A-Za-z0-9.-] after the prefix; libstdc++ has two '+'
  [ "$(doc '[.packages[].SPDXID | select(test("^SPDXRef-[A-Za-z0-9.-]+$") | not)] | length')" = 0 ]
  [ "$(doc '[.packages[].SPDXID] | unique | length')" = 4 ]
  [ "$(doc '[.relationships[] | select(.spdxElementId == "SPDXRef-DOCUMENT" and .relationshipType == "DESCRIBES")] | length')" = 4 ]
  [ "$(doc '([.packages[].SPDXID] | sort) == ([.relationships[].relatedSpdxElement] | sort)')" = true ]
}

@test "the document is named after the exact digest it describes" {
  sbom "${REF}"
  [ "$(doc .documentNamespace)" = "https://pulsar.arclight.digital/spdx/${DIGEST_REAL}" ]
  grep -qx "podman image inspect ${REF} --format {{.Digest}}" "${CALLS}"
}

@test "an image whose digest cannot be read is named unknown, never left blank" {
  DIGEST="" sbom "${REF}"
  [ "$(doc .documentNamespace)" = "https://pulsar.arclight.digital/spdx/unknown" ]
}

@test "the package query runs in a container with no network" {
  sbom "${REF}"
  grep -q "^podman run --rm --network=none ${REF} rpm -qa --qf " "${CALLS}"
}

@test "--local describes the running system from its own rpm database" {
  sbom --local
  [[ "$(doc .name)" == local:* ]]
  [ "$(doc .documentNamespace)" = "https://pulsar.arclight.digital/spdx/local" ]
  [ "$(doc '[.packages[].name] | join(" ")')" = "bash fonts-filesystem NetworkManager libstdc++" ]
  if grep -q '^podman' "${CALLS}"; then cat "${CALLS}"; false; fi
}

@test "no argument at all describes the running system" {
  sbom
  [[ "$(doc .name)" == local:* ]]
  grep -q '^rpm -qa' "${CALLS}"
}

@test "SOURCE_DATE_EPOCH pins the creation time, written as the SPDX date it must be" {
  # SPDX 2.3 wants YYYY-MM-DDThh:mm:ssZ. SOURCE_DATE_EPOCH is seconds since
  # 1970 by definition, so passing it through verbatim made the document
  # invalid exactly when someone asked for a reproducible one.
  SOURCE_DATE_EPOCH=1700000000 sbom "${REF}"
  [ "$(doc .creationInfo.created)" = 2023-11-14T22:13:20Z ]
}

@test "without SOURCE_DATE_EPOCH the creation time is now, as an SPDX date" {
  sbom "${REF}"
  [[ "$(doc .creationInfo.created)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "with no jq it refuses in one line rather than emitting half a document" {
  local sandbox="${BATS_TEST_TMPDIR}/nojq" t
  mkdir -p "${sandbox}"
  for t in bash cat awk wc date; do ln -sf "$(command -v "${t}")" "${sandbox}/${t}"; done
  run --separate-stderr env PATH="${BIN}:${sandbox}" "${SBOM}" "${REF}"
  [ "$status" -eq 1 ]
  [ "$stderr" = "jq is required" ]
  [ -z "$output" ]
}
