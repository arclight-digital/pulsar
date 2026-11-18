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
# The live session opens the installer app; an ISO without it can't install.
# (Before the app existed, a placeholder window stood in for it, and an ISO
# built from a tree that had lost the app would have shipped that window.)
for f in scripts/pulsar-installer scripts/pulsar-install-system scripts/pulsar-install-disk; do
  [ -f "$REPO/$f" ] || { echo "$f is missing: an ISO without it can't install Pulsar" >&2; exit 1; }
done
[ "$(id -u)" -eq 0 ] || { echo "run as root (image-builder needs the rootful storage)" >&2; exit 1; }
command -v image-builder >/dev/null || { echo "image-builder not found" >&2; exit 1; }

# A context holding only what Containerfile.installer copies.
ctx=$(mktemp -d /var/tmp/pulsar-installer-ctx.XXXXXX)
trap 'rm -rf "$ctx"' EXIT
mkdir -p "$ctx/scripts" "$ctx/system_files/usr/share/pulsar/installer"
cp "$REPO/Containerfile.installer" "$ctx/"
cp -r "$REPO/system_files.installer" "$ctx/"
cp -r "$REPO/system_files/usr/share/pulsar/installer/repart" "$ctx/system_files/usr/share/pulsar/installer/"
cp "$REPO/scripts/pulsar-install-disk" "$REPO/scripts/pulsar-install-system" "$REPO/scripts/pulsar-installer" \
  "$ctx/scripts/"

podman image exists "$PAYLOAD" || podman pull "$PAYLOAD"
podman image exists "$IMAGE" || podman pull "$IMAGE"
podman build --pull=never -t localhost/pulsar-installer:build -f "$ctx/Containerfile.installer" \
  --build-arg IMAGE="$IMAGE" --build-arg PAYLOAD_SOURCE="containers-storage:$PAYLOAD" \
  --build-arg PAYLOAD_TARGET="$TARGET" --build-arg VARIANT="$VARIANT" \
  --build-arg PAYLOAD_SIZE="$(podman image inspect --format '{{.Size}}' "$PAYLOAD")" "$ctx"

# osbuild labels the live tree from the image's own file_contexts, and the
# kernel takes a label only when the HOST's loaded policy defines its type:
# setfiles dies with "Invalid argument" on the first one it doesn't. A host
# on an older Fedora than the image lacks base-policy types (2026-11-15: an
# F44 builder, an F45 image, systemd_clonesetup_generator_exec_t), and a stock
# host lacks the add-on modules the image ships (2026-10-18:
# flatpak_helper_exec_t). No package install gives an F44 host F45's types.
# A root process in permissive mode can write a label the policy doesn't
# know, and it reads back as written only while the host stays permissive
# (enforcing again, it reads as unlabeled_t), so the whole image-builder run
# is permissive, not just its relabel. That is for a throwaway builder
# (PULSAR_ISO_PERMISSIVE=1, which weekly.sh sets); anywhere else the build
# is refused, naming the labels, before image-builder starts.
SELINUXFS=${PULSAR_SELINUXFS:-/sys/fs/selinux}
unknown=()
if [ "$(cat "$SELINUXFS/enforce" 2>/dev/null)" = 1 ]; then
  contexts=$(podman run --rm --pull=never --entrypoint /bin/sh localhost/pulsar-installer:build -c \
      'cd /etc/selinux/targeted/contexts/files && cat file_contexts file_contexts.homedirs file_contexts.local 2>/dev/null' \
    | grep -oE '[a-z_]+:object_r:[A-Za-z0-9_]+:s0' | sort -u) || true
  [ -n "$contexts" ] || { echo "could not read the installer image's file_contexts" >&2; exit 1; }
  while IFS= read -r c; do
    # the kernel's own check: writing a context here fails if it is invalid
    ( printf '%s' "$c" > "$SELINUXFS/context" ) 2>/dev/null || unknown+=("$(cut -d: -f3 <<<"$c")")
  done <<<"$contexts"
fi
permissive=""
if [ ${#unknown[@]} -gt 0 ]; then
  echo "this host's SELinux policy lacks ${#unknown[@]} type(s) the image labels with: ${unknown[*]}" >&2
  if [ "${PULSAR_ISO_PERMISSIVE:-}" != 1 ]; then
    echo "osbuild cannot label the live tree here. build on a host whose policy has them" >&2
    echo "(the image's Fedora release, with the image's policy modules), or, on a" >&2
    echo "throwaway host, set PULSAR_ISO_PERMISSIVE=1" >&2
    exit 1
  fi
  echo "permissive while image-builder runs (PULSAR_ISO_PERMISSIVE=1); enforcing again after"
  setenforce 0
  permissive=1
  trap '[ -z "$permissive" ] || setenforce 1; rm -rf "$ctx"' EXIT
fi

mkdir -p "$OUT"
image-builder build --bootc-ref localhost/pulsar-installer:build \
  --bootc-installer-payload-ref "$PAYLOAD" --bootc-default-fs btrfs \
  --output-dir "$OUT" bootc-generic-iso
if [ -n "$permissive" ]; then setenforce 1; permissive=""; fi
# image-builder names it bootc-fedora-44-bootc-generic-iso-x86_64.iso: the
# name people see on their download is Pulsar's, with the image's version
ver=$(skopeo inspect "containers-storage:$PAYLOAD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Labels"].get("org.opencontainers.image.version") or "dev")')
iso=$(find "$OUT" -name '*.iso' | head -1)
[ -n "$iso" ] || { echo "image-builder made no ISO" >&2; exit 1; }
name="pulsar-${VARIANT}-installer-${ver}.iso"
mv -f "$iso" "$OUT/$name"
ls -l "$OUT/$name"
