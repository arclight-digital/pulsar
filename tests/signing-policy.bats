#!/usr/bin/env bats
# Image signature verification, staged ahead of enforcement.
#
# The image ships the key its updates will be signed with and says where the
# signatures live, but does not yet require them: a policy that demanded a
# signature before any image carried one would make every host refuse its
# next update. These hold the staged half in place until the enforcing half
# (policy.json, and the ostree-image-signed transport) lands.

ROOT="${BATS_TEST_DIRNAME}/.."

@test "the shipped verification key is the key releases are signed with" {
  # Two copies of one key: keys/cosign.pub is what build-iso.sh verifies the
  # ISO against and what the site publishes. A rotation that updated one
  # would leave hosts trusting a key nothing signs with.
  cmp "${ROOT}/keys/cosign.pub" "${ROOT}/system_files/etc/pki/containers/pulsar.pub"
}

@test "signatures are looked for as sigstore attachments on Pulsar's registry" {
  f="${ROOT}/system_files/etc/containers/registries.d/pulsar.yaml"
  run python3 -c '
import sys
lines = [l.split("#")[0].rstrip() for l in open(sys.argv[1])]
lines = [l for l in lines if l.strip()]
assert lines == ["docker:", "  ghcr.io/arclight-digital:", "    use-sigstore-attachments: true"], lines
' "$f"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "no policy.json yet: nothing enforces a signature no image carries" {
  # Remove this test in the same change that ships the policy -- and only
  # once every image under ghcr.io/arclight-digital is signed.
  [ ! -e "${ROOT}/system_files/etc/containers/policy.json" ]
}
