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
         pulsar-lockup-horizontal-color-dark.png pulsar-mark-color-dark.svg; do
    [[ -r "${A}/brand/${f}" ]] || { echo "missing asset: ${A}/brand/${f}" >&2; exit 1; }
done

png() { magick "$1" -filter Lanczos -resize "$2x$2" -strip "$3"; echo "  $3 (${2}px)"; }

# ---------------------------------------------------------------------------
# Icons
# ---------------------------------------------------------------------------
echo "GNOME About / icon theme  <- pulsar-mark (color)"
install -Dm644 "${A}/brand/pulsar-mark.svg" \
               "${S}/icons/hicolor/scalable/apps/pulsar-logo-icon.svg"
echo "  ${S}/icons/hicolor/scalable/apps/pulsar-logo-icon.svg"
for sz in 512 256 128 64 48; do
    mkdir -p "${S}/icons/hicolor/${sz}x${sz}/apps"
    png "${A}/brand/pulsar-mark-1024.png" "$sz" \
        "${S}/icons/hicolor/${sz}x${sz}/apps/pulsar-logo-icon.png"
done

# GDM login screen.
#
# This one is NOT a hardcoded path, and used to be treated as one. The greeter
# reads the org.gnome.login-screen "logo" key, which Fedora merely sets in
# /usr/share/glib-2.0/schemas/org.gnome.login-screen.gschema.override. A key
# with a default can be outranked by a later-sorting override, so Pulsar
# points it at its own file (zz0-pulsar.gschema.override) instead of
# overwriting a file gdm does not own. The About-panel cuts below are the
# genuinely hardcoded case -- that distinction is real, and this file used to
# blur it.
#
# Using the standard key also gets the placement for free: GDM positions the
# logo low on the greeter, the way stock Fedora looks, with no theme patch.
# Width, not the square GDM_PX: this is a horizontal lockup, and 192 square
# would shrink the wordmark to nothing. Swap the source to
# pulsar-mark-mono-1024.png and use "${GDM_PX}" if the lockup reads too busy
# on the greeter -- the mono mark is the contrast-safe fallback.
GDM_LOGO_W=${GDM_LOGO_W:-320}
echo "GDM login                 <- pulsar-lockup-horizontal (color, dark-ground)"
mkdir -p "${S}/pulsar"
magick -background none "${A}/brand/pulsar-lockup-horizontal.png" \
       -trim -resize "${GDM_LOGO_W}x" -strip "${S}/pulsar/pulsar-gdm-logo.png"
echo "  ${S}/pulsar/pulsar-gdm-logo.png (${GDM_LOGO_W}px wide)"

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
# The lockup art is AUTHORED, not generated: assets/brand/pulsar-lockup-*.png
# are the design source. The plain cuts carry a white wordmark (dark-ground
# art); the *-color-dark cuts are the authored light-ground family (colored
# arc, near-black cores and wordmark). Do not rebuild lockups from mark +
# font, and do not derive light art by recoloring -- both looks were retired
# in favor of the authored set.
# ---------------------------------------------------------------------------
LOCKUP="${A}/brand/pulsar-lockup-horizontal.png"
LOCKUP_DARK="${A}/brand/pulsar-lockup-horizontal-color-dark.png"

fit279() { # $1=source $2=destination -- contain into the panel's fixed box
    magick -background none "$1" -trim -resize 279x80 \
           -gravity center -extent 279x80 -strip "$2"
    echo "  $2 (279x80)"
}

echo "GNOME About lockup        <- pulsar-lockup-horizontal (color)"
fit279 "${LOCKUP}" "${S}/pixmaps/fedora_whitelogo_med.png"
echo "GNOME About lockup (light) <- pulsar-lockup-horizontal-color-dark"
fit279 "${LOCKUP_DARK}" "${S}/pixmaps/fedora_logo_med.png"

# ---------------------------------------------------------------------------
# Plymouth watermark: the authored color lockup, bottom-center via the theme's
# WatermarkVerticalAlignment. Sized for 2560x1600 like the other physical-size
# assets.
# ---------------------------------------------------------------------------
echo "Plymouth watermark        <- pulsar-lockup-horizontal (color)"
magick -background none "${LOCKUP}" -trim -resize x96 -strip \
       "${S}/plymouth/themes/pulsar/watermark.png"
echo "  ${S}/plymouth/themes/pulsar/watermark.png ($(magick identify -format '%wx%h' "${S}/plymouth/themes/pulsar/watermark.png"))"

# (The site's light-theme mark is authored art too -- site/build.sh stages
# assets/brand/pulsar-mark-color-dark.svg directly; nothing to generate.)

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
echo "assets/brand/pulsar-tile* are unused by the image -- that is the"
echo "rounded-square cut, an app-icon form. Keep them for an ISO or"
echo "launcher icon later."
