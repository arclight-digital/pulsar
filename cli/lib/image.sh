# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): pulsar sbom, verify and changelog: where the image came from.

# ---------------------------------------------------------------------------
# sbom -- generated, never baked.
#
# A file inside the image cannot describe the image that contains it: adding
# it changes the thing it describes. So this reads the live rpm database,
# which is the same source CI scans, through the same script. The published
# per-build copies live in R2 and are linked from the manifest.
# ---------------------------------------------------------------------------
cmd_sbom() {
    no_json sbom
    [ -x "$SBOM_TOOL" ] || die "sbom generator missing at ${SBOM_TOOL}"
    "$SBOM_TOOL" --local
}

# ---------------------------------------------------------------------------
# verify -- prove where this image came from.
#
# The verify command lives in the manifest rather than here because the owner
# and registry are build-time facts: an image built from a fork must verify
# against the fork, and a copy of the command in the CLI would verify against
# us and pass when it should not.
#
# Run as an argv array, never through eval or `bash -c`. The manifest is a
# data file and running a string out of one is a habit worth not having; the
# array also means a value containing a pipe or a semicolon fails loudly
# instead of doing something inventive.
#
# The verifier is NOT shipped in the image, so the command is printed before
# anything is checked. Printing first is what makes the missing-tool path
# useful rather than a dead end: the line on your screen is the whole answer
# to "how do I check this myself", and it is as true from a distrobox or a
# laptop that has never booted Pulsar as it is from here.
# ---------------------------------------------------------------------------
cmd_verify() {
    # The booted image, by digest (a tag moves; the digest is what is
    # running), against the release key the image itself ships. Images are
    # signed on the build host after the boot gate; each signature carries its
    # Rekor entry, which cosign checks offline. A signature from before the
    # build logged them has none: that one is checked on the key alone, and
    # this says so rather than failing a genuinely signed image.
    local key="${PULSAR_COSIGN_KEY:-/etc/pki/containers/pulsar.pub}"
    need rpm-ostree; need jq
    [ -r "$key" ] || die "this image ships no release key at ${key}"
    local js; js=$(rpm-ostree status --json 2>/dev/null) || die "could not read deployment status"
    local booted='[ .deployments[]? | select(.booted == true) ][0]'
    local ref digest
    ref=$(printf '%s' "$js" | jq -r "${booted} | (.\"container-image-reference\" // \"\") | sub(\"^([a-z-]+:)+(//)?\"; \"\")")
    digest=$(printf '%s' "$js" | jq -r "${booted} | .\"container-image-reference-digest\" // \"\"")
    [ -n "$ref" ] && [ -n "$digest" ] || die "the booted deployment is not a registry image; there is no signature to check"
    # the tag, if any, is on the last path component (a registry may have a port)
    local image="${ref%%@*}"
    case "${image##*/}" in *:*) image="${image%:*}" ;; esac
    image="${image}@${digest}"
    local cmd="cosign verify --key ${key} ${image}"
    # Echoed first: the point of the command is that you can check it yourself,
    # and a verifier you cannot read is not much of one.
    printf '%s%s%s\n' "$C_DIM" "$cmd" "$C_RESET"
    have cosign || die "cosign is not on this machine. Install it in a toolbox (toolbox run sudo dnf install -y cosign), then run the command above with toolbox run"
    if cosign verify --key "$key" "$image" >/dev/null 2>&1; then
        printf 'signed with the release key, and the signature is logged in Rekor\n'
        return 0
    fi
    # The Rekor check failed. The key alone is enough only for a signature that
    # carries no Rekor bundle at all, which is what a signature from before the
    # build host logged them looks like. A key-signed signature whose bundle
    # does not verify is a failure: passing it on the key alone would let a
    # broken or forged log entry read as "from before Rekor".
    local verified
    verified=$(cosign verify --key "$key" --insecure-ignore-tlog=true "$image" 2>/dev/null) \
        || die "no signature on ${image} verifies against ${key}"
    # Two views have to agree that a key-signed signature has no bundle.
    # verify's JSON lists only the signatures that matched the key, with
    # .optional.Bundle on each one that carries a bundle. `cosign download
    # signature` lists every signature on the image with an explicit
    # "Bundle": null on those without one. The second states the absence
    # outright, so a cosign whose verify output stopped naming bundles fails
    # here instead of passing every signature as pre-Rekor.
    local bare_matched bare_listed sigs
    bare_matched=$(printf '%s' "$verified" \
        | jq -er 'if type == "array" then [ .[] | select(.optional.Bundle == null) ] | length else error("not a list") end' 2>/dev/null) \
        || die "could not read cosign's verify output for ${image}"
    sigs=$(cosign download signature "$image" 2>/dev/null) \
        || die "could not download the signatures on ${image} to check for a Rekor entry"
    bare_listed=$(printf '%s' "$sigs" \
        | jq -ser '[ .[] | select(type == "object" and has("Bundle") and .Bundle == null) ] | length' 2>/dev/null) \
        || die "could not read the signatures cosign downloaded for ${image}"
    if [ "$bare_matched" -gt 0 ] && [ "$bare_listed" -gt 0 ]; then
        printf 'signed with the release key, but not verified in Rekor (signatures from before Rekor logging have no entry)\n'
        return 0
    fi
    die "${image} is signed with the release key, but its Rekor entry does not verify"
}

# ---------------------------------------------------------------------------
# changelog -- what moved between the published build and this one.
# ---------------------------------------------------------------------------
cmd_changelog() {
    local url; url=$(mf changelog_url)
    [ -n "$url" ] || die "this image records no changelog_url; see ${MANIFEST}"
    need curl
    local js
    js=$(curl -fsSL "$url" 2>/dev/null) || die "could not fetch ${url}"
    if [ "${JSON:-0}" = 1 ]; then printf '%s\n' "$js"; return 0; fi
    # A baseline diff says what it is instead of "0 upgraded · 0 added";
    # downgrades are marked ! rather than blending into the upgrades; and a
    # response that is not the changelog (a captive portal, an error page
    # served as 200) dies with a message instead of raw jq stderr.
    printf '%s' "$js" | jq -r '
      if .baseline == true then
        "first build, nothing to compare against yet",
        "generated \(.generated // "?")"
      else
        "\(.summary.upgraded // 0) upgraded · \(.summary.added // 0) added · \(.summary.removed // 0) removed"
        + (if (.summary.downgraded // 0) > 0 then " · \(.summary.downgraded) downgraded" else "" end),
        "generated \(.generated // "?")",
        (if (.held.nvidia // "") != "" then "nvidia held back: \(.held.nvidia); nvidia machines stay on the build before" else empty end),
        "",
        (.changed[]? | "  \(if .direction == "downgraded" then "!" else "~" end) \(.name)  \(.from) → \(.to)"),
        (.added[]?   | "  + \(.name)  \(.version)"),
        (.removed[]? | "  - \(.name)  \(.version)")
      end' || die "the response from ${url} is not a changelog"
}
