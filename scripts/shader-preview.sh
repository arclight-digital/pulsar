#!/usr/bin/env bash
# Render the wallpaper shader for iteration. Edit assets/shaders/pulsar.frag,
# run this, look at the PNG, repeat.
#
#   ./scripts/shader-preview.sh                 1280x720 preview -> .preview/
#   ./scripts/shader-preview.sh 3840 2160       full size
#   ./scripts/shader-preview.sh --ship          write into system_files/ at 4K
#   ./scripts/shader-preview.sh --rebuild       force the render image to rebuild
#
# Rootless podman is fine here -- no GPU, no signing key, nothing privileged.
# The render container is cached after the first run, so iterations are fast.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="localhost/pulsar-shader:latest"

REBUILD=0
SHIP=0
ARGS=()
for a in "$@"; do
    case "$a" in
        --rebuild) REBUILD=1 ;;
        --ship)    SHIP=1 ;;
        *)         ARGS+=("$a") ;;
    esac
done

W="${ARGS[0]:-1280}"
H="${ARGS[1]:-720}"
if [[ $SHIP -eq 1 ]]; then
    W="${ARGS[0]:-3840}"; H="${ARGS[1]:-2160}"
    OUT="/repo/system_files/usr/share/backgrounds/pulsar"
    HOSTOUT="${REPO}/system_files/usr/share/backgrounds/pulsar"
else
    OUT="/repo/.preview"
    HOSTOUT="${REPO}/.preview"
fi

if [[ $REBUILD -eq 1 ]] || ! podman image exists "$IMAGE"; then
    echo "==> building render image (first run only)"
    podman build -q -f "${REPO}/scripts/shader-render.Containerfile" -t "$IMAGE" "${REPO}/scripts" >/dev/null
fi

podman run --rm -v "${REPO}:/repo:z" "$IMAGE" --width "$W" --height "$H" --out "$OUT"

echo
echo "wrote to ${HOSTOUT}/"
[[ $SHIP -eq 1 ]] || echo "(.preview/ is gitignored -- use --ship to write the real ones)"
