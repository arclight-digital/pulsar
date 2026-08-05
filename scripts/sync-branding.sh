#!/usr/bin/env bash
# Derive the image's branding files from assets/.
#
# assets/ is the source of truth. Everything this script writes under
# system_files/ is generated -- re-run it whenever the art or fonts change.
#
# Deliberately does NOT trim whitespace from the source art: the marks carry a
# gaussian glow whose alpha extends past the geometry, and trimming clips it.
# If the About-panel logo renders too small, re-export the art with tighter
# bounds rather than trimming here.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="${REPO}/assets"
S="${REPO}/system_files/usr/share"

# --- display-dependent sizes -------------------------------------------------
# Neither of these scales at runtime, so both are physical-size decisions tied
# to the panel. Sized for 2560x1600. On a 4K panel roughly double them; on
# 1080p roughly halve them.
PLYMOUTH_PX=${PLYMOUTH_PX:-320}   # boot splash watermark
GDM_PX=${GDM_PX:-192}             # login screen logo
# -----------------------------------------------------------------------------

command -v magick >/dev/null || { echo "needs ImageMagick 7 (magick)" >&2; exit 1; }
for f in pulsar-mark.svg pulsar-mark-1024.png pulsar-mark-mono-1024.png \
         pulsar-mark-mono.svg pulsar-lockup-horizontal.png \
         pulsar-lockup-horizontal-mono.png; do
    [[ -r "${A}/icons/${f}" ]] || { echo "missing asset: ${A}/icons/${f}" >&2; exit 1; }
done

png() { magick "$1" -filter Lanczos -resize "$2x$2" -strip "$3"; echo "  $3 (${2}px)"; }

# ---------------------------------------------------------------------------
# Icons
# ---------------------------------------------------------------------------
echo "GNOME About / icon theme  <- pulsar-mark (color)"
install -Dm644 "${A}/icons/pulsar-mark.svg" \
               "${S}/icons/hicolor/scalable/apps/pulsar-logo-icon.svg"
echo "  ${S}/icons/hicolor/scalable/apps/pulsar-logo-icon.svg"
for sz in 512 256 128 64 48; do
    mkdir -p "${S}/icons/hicolor/${sz}x${sz}/apps"
    png "${A}/icons/pulsar-mark-1024.png" "$sz" \
        "${S}/icons/hicolor/${sz}x${sz}/apps/pulsar-logo-icon.png"
done

# Mono cuts. Both land on dark backgrounds with no theme awareness and no
# contrast guarantee, so they use the white-on-transparent art.
echo "GDM login                 <- pulsar-mark-mono"
png "${A}/icons/pulsar-mark-mono-1024.png" "${GDM_PX}" "${S}/pixmaps/fedora-gdm-logo.png"

# Plymouth watermark is generated in the lockup section below -- it needs the
# wordmark font variables, which are defined there.

# ---------------------------------------------------------------------------
# GNOME Settings -> About lockup.
#
# NOT the os-release LOGO= icon. That key points at pulsar-logo-icon, which is
# square, and the About panel does not use it -- gnome-control-center has these
# two paths compiled in, and picks by theme:
#
#   fedora_whitelogo_med.png   dark theme
#   fedora_logo_med.png        light theme
#
# So the filenames stay Fedora's, same reasoning as fedora-gdm-logo.png: the
# path is hardcoded in a binary, and overwriting one file beats patching
# gnome-control-center. 279x80 is the size Fedora ships; the panel does not
# scale it.
#
# The lockup art is AUTHORED, not generated: assets/icons/pulsar-lockup-*.png
# are the design source (color and mono cuts, white wordmark -- dark-ground
# art). Light surfaces get an INK derivation: the mono cut with its RGB
# flattened to #241F3D, keeping the authored geometry and alpha. Do not
# rebuild lockups from mark + font here; that generated look was retired.
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
LOCKUP="${A}/icons/pulsar-lockup-horizontal.png"
LOCKUP_MONO="${A}/icons/pulsar-lockup-horizontal-mono.png"

fit279() { # $1=source $2=destination -- contain into the panel's fixed box
    magick -background none "$1" -trim -resize 279x80 \
           -gravity center -extent 279x80 -strip "$2"
    echo "  $2 (279x80)"
}
ink() { # $1=source $2=destination -- authored geometry, ink-colored for light
    magick "$1" -channel RGB -fill '#241F3D' -colorize 100 +channel -strip "$2"
}

echo "GNOME About lockup        <- pulsar-lockup-horizontal (color)"
fit279 "${LOCKUP}" "${S}/pixmaps/fedora_whitelogo_med.png"
echo "GNOME About lockup (light) <- pulsar-lockup-horizontal-mono, inked"
ink "${LOCKUP_MONO}" "${TMP}/lockup-ink.png"
fit279 "${TMP}/lockup-ink.png" "${S}/pixmaps/fedora_logo_med.png"

# ---------------------------------------------------------------------------
# Plymouth watermark: the authored color lockup, bottom-center via the theme's
# WatermarkVerticalAlignment. Sized for 2560x1600 like the other physical-size
# assets.
# ---------------------------------------------------------------------------
echo "Plymouth watermark        <- pulsar-lockup-horizontal (color)"
magick -background none "${LOCKUP}" -trim -resize x96 -strip \
       "${S}/plymouth/themes/pulsar/watermark.png"
echo "  ${S}/plymouth/themes/pulsar/watermark.png ($(magick identify -format '%wx%h' "${S}/plymouth/themes/pulsar/watermark.png"))"

# ---------------------------------------------------------------------------
# Site light-theme mark: the ink derivation of the authored mono mark. The
# ink SVGs were retired with the generated lockups; this raster is what
# site/main.js swaps in on the light theme (site/build.sh stages it).
# ---------------------------------------------------------------------------
echo "Site ink mark             <- pulsar-mark-mono-1024, inked"
ink "${A}/icons/pulsar-mark-mono-1024.png" "${TMP}/mark-ink-full.png"
magick "${TMP}/mark-ink-full.png" -filter Lanczos -resize 512x512 -strip \
       "${REPO}/site/assets-static/pulsar-mark-ink.png"
echo "  ${REPO}/site/assets-static/pulsar-mark-ink.png (512px)"

# ---------------------------------------------------------------------------
# Fonts
#
# STATIC CUTS ONLY. The variable and static files report the same family name
# ("Host Grotesk", "JetBrains Mono"), so shipping both makes fontconfig
# arbitrate between a static Bold and the variable font's Bold named instance.
# Which one wins depends on scan order. Ship one or the other, never both.
#
# OFL.txt travels with the fonts -- the license requires it on redistribution,
# and this image is redistribution.
# ---------------------------------------------------------------------------
echo "Fonts                     <- static cuts"
rm -rf "${S}/fonts/pulsar"
while IFS='|' read -r src dst; do
    [[ -n "$src" ]] || continue
    mkdir -p "${S}/fonts/pulsar/${dst}"
    install -m644 "${A}/fonts/${src}/static/"*.ttf "${S}/fonts/pulsar/${dst}/"
    install -m644 "${A}/fonts/${src}/OFL.txt"      "${S}/fonts/pulsar/${dst}/"
    echo "  ${S}/fonts/pulsar/${dst}/ ($(ls "${A}/fonts/${src}/static/"*.ttf | wc -l) faces + OFL)"
done <<'EOF'
Host_Grotesk|host-grotesk
JetBrains_Mono|jetbrains-mono
EOF

echo
echo "family names in use (must match zz0-pulsar.gschema.override):"
fc-scan --format '  %{family[0]}\n' "${S}/fonts/pulsar" 2>/dev/null | sort -u
echo
echo "assets/icons/pulsar-tile* are unused by the image -- that is the"
echo "rounded-square cut, an app-icon form. Keep them for an ISO or"
echo "launcher icon later."
