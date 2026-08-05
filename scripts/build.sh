#!/usr/bin/env bash
# Build Pulsar LOCALLY, for testing changes before pushing them.
#
# This is not how the deployed images are produced. Both variants are built,
# signed, and pushed by .github/workflows/build.yml; the machine running
# Pulsar pulls them and builds nothing. Use this to check that a Containerfile
# edit works before it reaches CI.
#
#   ./build.sh            both, vanilla then nvidia
#   ./build.sh vanilla    branding/fonts/scx/papercuts -- no signing key used
#   ./build.sh nvidia     needs a local vanilla build and the signing key
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYDIR=/etc/pki/akmods-keys
FEDORA_VERSION="${FEDORA_VERSION:-44}"
BASE="localhost/pulsar"
NVIDIA="localhost/pulsar-nvidia"

VARIANT="${1:-all}"
case "$VARIANT" in
    vanilla|nvidia|all) ;;
    *) echo "usage: $0 [vanilla|nvidia|all]" >&2; exit 2 ;;
esac

[[ $EUID -eq 0 ]] || { echo "must run as root (see comment at top)" >&2; exit 1; }

# --- Secure Boot precheck, only relevant to the nvidia variant --------------
#
# Compare SHA1 fingerprints, not Distinguished Names. mokutil prints a
# fingerprint per key; matching on that is exact, whereas DN string matching
# depends on how openssl chooses to render the subject.
#
# Three distinct outcomes, deliberately. An earlier version collapsed "could
# not read the MOK list" into "not enrolled" and cried wolf on a correctly
# enrolled key. Not being able to verify is not the same as having verified
# a failure.
mok_check() {
    local enrolled cert_fp
    enrolled=$(mokutil --list-enrolled 2>/dev/null || true)
    if [[ -z "$enrolled" ]]; then
        echo "NOTE: could not read the MOK list; skipping Secure Boot precheck." >&2
        return 0
    fi

    cert_fp=$(openssl x509 -inform der -in "${KEYDIR}/certs/public_key.der" \
                -noout -fingerprint -sha1 2>/dev/null \
              | tr 'A-Z' 'a-z' | grep -oE '([0-9a-f]{2}:){19}[0-9a-f]{2}' || true)
    if [[ -z "$cert_fp" ]]; then
        echo "NOTE: could not fingerprint the signing cert; skipping precheck." >&2
        return 0
    fi

    if grep -qiF "$cert_fp" <<<"$enrolled"; then
        echo "signing cert is enrolled in MOK (${cert_fp})"
        return 0
    fi

    echo "WARNING: signing cert ${cert_fp}" >&2
    echo "         is NOT enrolled in MOK. The build will succeed but the" >&2
    echo "         resulting image will not boot with Secure Boot on." >&2
    echo "         Enroll it with:" >&2
    echo "           mokutil --import ${KEYDIR}/certs/public_key.der" >&2
}

build_vanilla() {
    echo "==> ${BASE}:${FEDORA_VERSION}  (local test build, no signing key)"
    # --pull=newer or this rebuilds the same bytes forever: podman's default
    # pull policy is "missing", so an already-cached silverblue:44 is reused
    # and every RUN then cache-hits. No new kernel, no security updates.
    podman build --pull=newer \
        --file "${REPO}/Containerfile" \
        --build-arg FEDORA_VERSION="${FEDORA_VERSION}" \
        -t "${BASE}:${FEDORA_VERSION}" \
        -t "${BASE}:latest" \
        "${REPO}"
}

build_nvidia() {
    for f in "${KEYDIR}/private/private_key.priv" "${KEYDIR}/certs/public_key.der"; do
        [[ -r "$f" ]] || { echo "missing signing key: $f" >&2; exit 1; }
    done
    mok_check

    podman image exists "${BASE}:${FEDORA_VERSION}" \
        || { echo "base ${BASE}:${FEDORA_VERSION} not built; run '$0 vanilla' first" >&2; exit 1; }

    echo "==> ${NVIDIA}:${FEDORA_VERSION}  (uses the signing key)"
    podman build \
        --file "${REPO}/Containerfile.nvidia" \
        --build-arg FEDORA_VERSION="${FEDORA_VERSION}" \
        --build-arg BASE_IMAGE="${BASE}" \
        --secret id=akmods_priv,src="${KEYDIR}/private/private_key.priv" \
        --secret id=akmods_cert,src="${KEYDIR}/certs/public_key.der" \
        -t "${NVIDIA}:${FEDORA_VERSION}" \
        -t "${NVIDIA}:latest" \
        "${REPO}"
}

[[ "$VARIANT" == vanilla || "$VARIANT" == all ]] && build_vanilla
[[ "$VARIANT" == nvidia  || "$VARIANT" == all ]] && build_nvidia
true  # the tests above are the last commands; do not let a false exit the script

echo
echo "built:"
podman images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' \
    --filter reference='localhost/pulsar*' | sort -u
echo
echo "These are TEST images. Deployed images come from CI; push to main and"
echo "the machine picks them up. To boot one of these locally anyway:"
echo "  bootc switch --transport containers-storage ${NVIDIA}:latest"
