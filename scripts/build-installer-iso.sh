#!/usr/bin/env bash
# Build Pulsar's live installer ISO: Containerfile.installer, booted live by
# image-builder's bootc-generic-iso, with the image it installs embedded.
#
#   sudo ./scripts/build-installer-iso.sh
#   sudo ./scripts/build-installer-iso.sh --variant nvidia --out /var/tmp/iso
#
# Options:
#   --image REF     the image the live system is built FROM
#                   (default ghcr.io/arclight-digital/pulsar[-nvidia]:latest)
#   --payload REF   the image embedded and installed (default: --image)
#   --target REF    what the installed system follows for updates
#                   (default: --payload, so a digest-pinned payload still
#                   follows its tag only if you pass --target with the tag)
#   --variant V     vanilla | nvidia (default vanilla); written to payload.json
#   --out DIR       where the ISO lands (default ./output/installer)
#
# Root, because image-builder runs osbuild against the rootful containers-
# storage: both refs are read from it (Local), so the payload is pulled
# there first if it isn't already. Needs image-builder >= v49 (Fedora's
# package, or ghcr.io/osbuild/image-builder-cli).
#
# Before the GUI exists, a placeholder window stands in for
# scripts/pulsar-installer so the live session can be tested end to end.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT=vanilla IMAGE="" PAYLOAD="" TARGET="" OUT="${REPO}/output/installer"
while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE=$2; shift 2 ;;
    --payload) PAYLOAD=$2; shift 2 ;;
    --target) TARGET=$2; shift 2 ;;
    --variant) VARIANT=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
case "$VARIANT" in
  vanilla) IMAGE=${IMAGE:-ghcr.io/arclight-digital/pulsar:latest} ;;
  nvidia) IMAGE=${IMAGE:-ghcr.io/arclight-digital/pulsar-nvidia:latest} ;;
  *) echo "--variant is vanilla or nvidia" >&2; exit 2 ;;
esac
PAYLOAD=${PAYLOAD:-$IMAGE}
TARGET=${TARGET:-$PAYLOAD}
[ "$(id -u)" -eq 0 ] || { echo "run as root (image-builder needs the rootful storage)" >&2; exit 1; }
command -v image-builder >/dev/null || { echo "image-builder not found" >&2; exit 1; }

# A context holding only what Containerfile.installer copies.
ctx=$(mktemp -d /var/tmp/pulsar-installer-ctx.XXXXXX)
trap 'rm -rf "$ctx"' EXIT
mkdir -p "$ctx/scripts" "$ctx/system_files/usr/share/pulsar/installer"
cp "$REPO/Containerfile.installer" "$ctx/"
cp -r "$REPO/system_files.installer" "$ctx/"
cp -r "$REPO/system_files/usr/share/pulsar/installer/repart" "$ctx/system_files/usr/share/pulsar/installer/"
cp "$REPO/scripts/pulsar-install-disk" "$REPO/scripts/pulsar-install-system" "$ctx/scripts/"
if [ -f "$REPO/scripts/pulsar-installer" ]; then
  cp "$REPO/scripts/pulsar-installer" "$ctx/scripts/"
else
  echo "note: no scripts/pulsar-installer yet; using a placeholder window" >&2
  cat > "$ctx/scripts/pulsar-installer" <<'EOF'
#!/usr/bin/python3
# PLACEHOLDER until scripts/pulsar-installer exists: proves the live session
# starts the installer.
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk
app = Adw.Application(application_id="digital.arclight.Pulsar.Installer")
app.connect("activate", lambda a: Adw.ApplicationWindow(
    application=a, title="Install Pulsar", default_width=900, default_height=640,
    content=Adw.StatusPage(title="Install Pulsar", description="Placeholder installer window")).present())
app.run(None)
EOF
fi

podman image exists "$PAYLOAD" || podman pull "$PAYLOAD"
podman image exists "$IMAGE" || podman pull "$IMAGE"
podman build --pull=never -t localhost/pulsar-installer:build -f "$ctx/Containerfile.installer" \
  --build-arg IMAGE="$IMAGE" --build-arg PAYLOAD_SOURCE="containers-storage:$PAYLOAD" \
  --build-arg PAYLOAD_TARGET="$TARGET" --build-arg VARIANT="$VARIANT" \
  --build-arg PAYLOAD_SIZE="$(podman image inspect --format '{{.Size}}' "$PAYLOAD")" "$ctx"

mkdir -p "$OUT"
image-builder build --bootc-ref localhost/pulsar-installer:build \
  --bootc-installer-payload-ref "$PAYLOAD" --bootc-default-fs btrfs \
  --output-dir "$OUT" bootc-generic-iso
# image-builder names it bootc-fedora-44-bootc-generic-iso-x86_64.iso: the
# name people see on their download is Pulsar's, with the image's version
ver=$(skopeo inspect "containers-storage:$PAYLOAD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Labels"].get("org.opencontainers.image.version") or "dev")')
iso=$(find "$OUT" -name '*.iso' | head -1)
[ -n "$iso" ] || { echo "image-builder made no ISO" >&2; exit 1; }
name="pulsar-${VARIANT}-installer-${ver}.iso"
mv -f "$iso" "$OUT/$name"
ls -l "$OUT/$name"
