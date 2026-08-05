#!/usr/bin/env bash
# Emit an SPDX 2.3 SBOM for a bootc image, from its RPM database.
#
#   rpm-sbom.sh IMAGE_REF > sbom.spdx.json
#
# Why not syft, which is the obvious tool and the one this repo reached for
# first: syft scans an IMAGE by squashing and indexing every layer, and on
# this image that needs more than 16GB. Measured, not guessed -- the OOM
# killer logged 16.67GB against a 16GB cap with stock settings, 16.74GB with
# file analysis disabled, and 16.74GB with only the RPM cataloger selected.
# The number barely moves because the cost is the layer indexing, which
# happens before any cataloger runs. GitHub's standard runner has 16GB, so
# that approach could never have worked here.
#
# What it was spending 16GB to rediscover is a database the image already
# carries. `rpm -qa` produces the SAME 1790 packages in 0.49s and 52MB of
# RSS -- verified against syft's own rpm-db cataloger output on this image,
# which agreed exactly. For an RPM-based OS the rpm database IS the package
# manifest; walking the filesystem to infer it is work with no product.
#
# The trade is that this file, rather than a widely-used scanner, is now
# responsible for emitting valid SPDX. It is deliberately minimal and
# package-only: no file-level records, which is what SPDX calls
# filesAnalyzed:false, and no attempt at dependency relationships.
set -euo pipefail

REF=${1:-}
[ -n "$REF" ] || { echo "usage: $(basename "$0") IMAGE_REF" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

RUNTIME=${CONTAINER_RUNTIME:-podman}

# Resolve the digest so the document identifies the exact bytes described,
# not a tag that moves underneath it.
digest=$("$RUNTIME" image inspect "$REF" --format '{{.Digest}}' 2>/dev/null || echo "")
[ -n "$digest" ] || digest="unknown"

# EPOCH is the reason for the awk rather than a plain --qf: rpm prints
# "(none)" for packages without one, and an SBOM that records a literal
# "(none):1.2-3" as the version breaks every comparison downstream. Epoch is
# folded in only when it exists, which is exactly how rpm itself renders NEVRA.
pkgs=$("$RUNTIME" run --rm --network=none "$REF" \
        rpm -qa --qf '%{NAME}\t%{EPOCH}\t%{VERSION}\t%{RELEASE}\t%{ARCH}\t%{LICENSE}\n')

# gpg-pubkey is not a package. rpm keeps imported signing keys in the same
# database, versioned by key fingerprint; emitting them as SPDX packages
# would describe the mise and rpmfusion keys as installed software. They are
# dropped, and the count is REPORTED on stderr rather than silently vanishing.
keys=$(printf '%s\n' "$pkgs" | awk -F'\t' '$1 == "gpg-pubkey"' | wc -l)
[ "$keys" -eq 0 ] || echo "note: excluded ${keys} gpg-pubkey pseudo-package(s)" >&2

printf '%s\n' "$pkgs" \
  | awk -F'\t' 'NF >= 5 && $1 != "gpg-pubkey"' \
  | jq -R -s -c '
      split("\n") | map(select(length > 0) | split("\t"))
      | map({
          name:    .[0],
          epoch:   .[1],
          version: .[2],
          release: .[3],
          arch:    .[4],
          license: (.[5] // "NOASSERTION")
        })
      | map(. + {
          nevr: (if .epoch == "(none)" or .epoch == "" then "" else .epoch + ":" end)
                + .version + "-" + .release
        })' \
  | jq --arg ns "https://pulsar.arclight.digital/spdx/${digest}" \
       --arg created "${SOURCE_DATE_EPOCH:+}${SOURCE_DATE_EPOCH:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
       --arg ref "$REF" \
       --arg digest "$digest" '
      {
        spdxVersion: "SPDX-2.3",
        dataLicense: "CC0-1.0",
        SPDXID: "SPDXRef-DOCUMENT",
        name: $ref,
        documentNamespace: $ns,
        creationInfo: {
          created: $created,
          creators: ["Tool: pulsar-rpm-sbom", "Organization: Arclight"]
        },
        comment: "Package inventory read from the image RPM database. filesAnalyzed is false throughout: no file-level records are produced.",
        packages: (to_entries | map(
          .key as $i | .value as $p | {
            SPDXID: ("SPDXRef-Package-rpm-" + ($p.name | gsub("[^a-zA-Z0-9.-]"; "-")) + "-" + ($i | tostring)),
            name: $p.name,
            versionInfo: $p.nevr,
            downloadLocation: "NOASSERTION",
            filesAnalyzed: false,
            licenseConcluded: "NOASSERTION",
            licenseDeclared: ($p.license // "NOASSERTION"),
            copyrightText: "NOASSERTION",
            externalRefs: [{
              referenceCategory: "PACKAGE-MANAGER",
              referenceType: "purl",
              referenceLocator: ("pkg:rpm/fedora/" + $p.name + "@" + $p.nevr + "?arch=" + $p.arch)
            }]
          })),
        relationships: (to_entries | map({
          spdxElementId: "SPDXRef-DOCUMENT",
          relatedSpdxElement: ("SPDXRef-Package-rpm-" + (.value.name | gsub("[^a-zA-Z0-9.-]"; "-")) + "-" + (.key | tostring)),
          relationshipType: "DESCRIBES"
        }))
      }'
