#!/usr/bin/env bash
# Build a local test image: the published pulsar-nvidia image with THIS
# branch's theming overlaid, so it can be rebased onto and lived in before
# the change merges. Not part of the nightly; a one-off for trying the theme
# engine on real hardware.
#
#   scripts/theme-test-image.sh [--no-save]
#
# Produces localhost/pulsar-theming-test:latest and, unless --no-save,
# /var/tmp/pulsar-theming-test.ociarchive for root to rebase from:
#
#   sudo rpm-ostree rebase ostree-unverified-image:oci-archive:/var/tmp/pulsar-theming-test.ociarchive
#
# and back to the real tag afterwards (rpm-ostree, not bootc, because bootc
# switch would drop layered packages):
#
#   sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/arclight-digital/pulsar-nvidia:latest
#
# The theme RUN step is not copied here: it is cut out of the real
# Containerfile at build time, so this image runs exactly the step the
# nightly will. Renders come from scripts/render-theme-wallpapers.py; without
# them the image still builds, and themes use the brand wallpapers.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE=${THEME_TEST_BASE:-ghcr.io/arclight-digital/pulsar-nvidia:latest}
TAG=localhost/pulsar-theming-test:latest
ARCHIVE=/var/tmp/pulsar-theming-test.ociarchive
SAVE=yes
[ "${1:-}" = --no-save ] && SAVE=no

say() { printf '\n==> %s\n' "$*"; }

# The theme step, verbatim: from its COPY to the blank line that ends its RUN.
step=$(awk '/^COPY scripts\/pulsar-theme scripts\/pulsar-theme-picker/{on=1} on{print} on&&/^$/{exit}' \
         "${REPO}/Containerfile")
[ -n "${step}" ] || { echo "FATAL: could not find the theme step in Containerfile" >&2; exit 1; }

n=$(find "${REPO}/system_files/usr/share/pulsar/themes" -path '*/backgrounds/*.png' | wc -l)
echo "theme wallpaper renders present: ${n} (0 means themes fall back to the brand wallpapers)"

cf=$(mktemp)
trap 'rm -f "${cf}"' EXIT
cat > "${cf}" <<EOF
FROM ${BASE}
# The branch's overlay: themes, templates, extension, units, presets, the
# zz0/zz1 overrides and the picker's .desktop, plus the CLI verb.
COPY system_files/ /
COPY cli/pulsar /usr/bin/pulsar
${step}
RUN glib-compile-schemas /usr/share/glib-2.0/schemas && \\
    systemctl --global enable pulsar-theme-init.service && \\
    systemctl --global enable pulsar-theme-notice.service && \\
    for u in pulsar-theme-init.service pulsar-theme-notice.service; do \\
      grep -qx "enable \${u}" /usr/lib/systemd/user-preset/50-pulsar.preset || \\
        { echo "FATAL: \${u} is enabled --global here but missing from the user preset"; exit 1; }; \\
    done && \\
    pulsar theme list && \\
    rm -rf /tmp/* && \\
    bootc container lint
EOF

say "building ${TAG} from ${BASE}"
podman build --pull=newer -t "${TAG}" -f "${cf}" "${REPO}"

if [ "${SAVE}" = yes ]; then
  say "saving ${ARCHIVE}"
  rm -f "${ARCHIVE}"
  podman save --format oci-archive -o "${ARCHIVE}" "${TAG}"
  ls -lh "${ARCHIVE}"
fi
say "done"
