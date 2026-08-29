#!/usr/bin/env bash
# Derive the image's branding files from assets/.
#
# assets/ is the source of truth. Everything this script writes under
# system_files/ is generated -- re-run it whenever the art or fonts change.
#
# Every cut below is rendered from the SVG art rather than resampled from a
# finished PNG: each is rasterized well above its target and reduced from
# there, so the small fixed-size cuts get supersampled edges instead of
# second-generation pixels. The reduction runs in linear light -- reducing
# light-on-dark art in sRGB thins the strokes -- and is followed by a soft
# unsharp pass to put back the edge a reduction costs. The unsharp THRESHOLD
# is what keeps that pass off the marks' glow gradient, which beads and rings
# if you sharpen it. Raise the amount and you get a rim on the wordmark long
# before the glow survives it.
#
# Deliberately does NOT trim the mark art: the marks carry a gaussian glow
# whose alpha extends past the geometry, and trimming clips it -- which also
# changes their optical size within the icon grid. The lockups ARE trimmed on
# purpose, because their cuts are fitted to fixed panel boxes.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="${REPO}/assets"
S="${REPO}/system_files/usr/share"

# The GDM logo and plymouth watermark sizes (below) do not scale at runtime:
# both are physical-size decisions tied to the panel, sized for 2560x1600.
# On a 4K panel roughly double them; on 1080p roughly halve them.

command -v magick >/dev/null || { echo "needs ImageMagick 7 (magick)" >&2; exit 1; }
magick -list format | grep -qi 'SVG.*RSVG' || {
    echo "needs an ImageMagick built against librsvg -- its own MSVG renderer" >&2
    echo "ignores <filter>, which silently drops the marks' glow" >&2; exit 1; }
for f in pulsar-mark.svg pulsar-mark-mono.svg pulsar-mark-color-dark.svg \
         pulsar-lockup-horizontal.svg pulsar-lockup-horizontal-color-dark.svg; do
    [[ -r "${A}/brand/${f}" ]] || { echo "missing asset: ${A}/brand/${f}" >&2; exit 1; }
done

# Soft by design: enough to recover the edge the reduction costs, not enough to
# rim the wordmark. SHARPEN=none renders flat.
SHARPEN="${SHARPEN:-0x0.5+0.30+0.015}"
SHARP=(); [[ "${SHARPEN}" == none ]] || SHARP=(-unsharp "${SHARPEN}")

# The lockup wordmark is live <text> in Host Grotesk, so the SVG renders
# through fontconfig. Bind that to the cuts this repo ships instead of whatever
# happens to be installed: an unresolvable family does not fail the render, it
# quietly substitutes, and the wordmark ships wrong. With no Host Grotesk
# visible the lockup rasterizes 292px wide instead of 1284 -- silently, and
# only the width says so.
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
cat >"${WORK}/fonts.conf" <<EOF
<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>${A}/fonts/Host_Grotesk/static</dir>
  <dir>${A}/fonts/JetBrains_Mono/static</dir>
  <cachedir>${WORK}/fc-cache</cachedir>
</fontconfig>
EOF
export FONTCONFIG_FILE="${WORK}/fonts.conf"

# One high rasterization per source, reused by every cut taken from it.
# 768dpi puts the 256-unit marks at 2048px (4x the largest icon); 384dpi puts
# the 382-unit lockup at 1284px trimmed (4x the widest lockup cut).
magick -background none -density 768 "${A}/brand/pulsar-mark.svg" \
       -depth 16 "${WORK}/mark.png"
magick -background none -density 384 "${A}/brand/pulsar-lockup-horizontal.svg" \
       -trim +repage -depth 16 "${WORK}/lockup.png"
magick -background none -density 384 "${A}/brand/pulsar-lockup-horizontal-color-dark.svg" \
       -trim +repage -depth 16 "${WORK}/lockup-dark.png"

# Reduce a master to a target: linear light, Lanczos, soft unsharp. Extra
# magick arguments (gravity/extent) land after the resize, before the write.
reduce() { # $1=master $2=resize-geometry $3=destination [extra magick args...]
    local src="$1" geom="$2" dst="$3"; shift 3
    mkdir -p "$(dirname "${dst}")"
    magick -background none "${src}" \
           -colorspace RGB -filter Lanczos -resize "${geom}" -colorspace sRGB \
           "${SHARP[@]}" "$@" -depth 8 -strip "${dst}"
}

# ---------------------------------------------------------------------------
# Icons
# ---------------------------------------------------------------------------
echo "GNOME About / icon theme  <- pulsar-mark (color)"
install -Dm644 "${A}/brand/pulsar-mark.svg" \
               "${S}/icons/hicolor/scalable/apps/pulsar-logo-icon.svg"
echo "  ${S}/icons/hicolor/scalable/apps/pulsar-logo-icon.svg"
for sz in 512 256 128 64 48; do
    reduce "${WORK}/mark.png" "${sz}x${sz}" \
           "${S}/icons/hicolor/${sz}x${sz}/apps/pulsar-logo-icon.png"
    echo "  ${S}/icons/hicolor/${sz}x${sz}/apps/pulsar-logo-icon.png (${sz}px)"
done

# GDM login screen.
#
# NOT a hardcoded path: the greeter reads the org.gnome.login-screen "logo"
# key, which Fedora merely sets in its own gschema override. A key with a
# default can be outranked by a later-sorting override, so Pulsar points it
# at its own file (zz0-pulsar.gschema.override) instead of overwriting a file
# gdm does not own. The About-panel cuts below are the genuinely hardcoded
# case.
#
# Using the standard key also gets the placement for free: GDM positions the
# logo low on the greeter, the way stock Fedora looks, with no theme patch.
# Sized by width, not a square: this is a horizontal lockup, and 192 square
# would shrink the wordmark to nothing. If the lockup reads too busy on the
# greeter, swap the source to pulsar-mark-mono.svg at ~192px square --
# the mono mark is the contrast-safe fallback.
GDM_LOGO_W=${GDM_LOGO_W:-320}
echo "GDM login                 <- pulsar-lockup-horizontal (color, dark-ground)"
mkdir -p "${S}/pulsar"
reduce "${WORK}/lockup.png" "${GDM_LOGO_W}x" "${S}/pulsar/pulsar-gdm-logo.png"
echo "  ${S}/pulsar/pulsar-gdm-logo.png (${GDM_LOGO_W}px wide)"

# The terminal mark for `pulsar manifest`, from the same SVG as everything
# else. Generated here so it cannot drift from the artwork: a hand-drawn copy
# was wrong about the shape within a day of being written.
#
# --cols is the RASTER width, not the width of the art that comes out: the
# renderer trims the SVG's blank margin in both directions, so 56 rasterised
# lands on 19 rows by 36 columns. 19 rows is the point -- that is the height
# of a typical readout (5 header rows, 6 or 7 host rows, 7 components), so the
# art and the information end together instead of the mark stopping six rows
# short of the values beside it.
#
# The trim is why this could grow at all. Untrimmed, 56 raster columns meant
# 56 columns of art, of which 20 were the glow's empty margin -- ten columns
# of indent on the left and ten of gap before the readout on the right. Cut,
# the taller mark is NARROWER than the 38 this used to ship, so it is drawn on
# more terminals than the old one was, not fewer.
python3 "${REPO}/scripts/render-ascii-logo.py" "${A}/brand/pulsar-mark.svg" \
        --cols 56 -o "${S}/pulsar/logo.ansi"

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
# The lockup art is AUTHORED, not generated: assets/brand/pulsar-lockup-*.svg
# are the design source, and the matching .png files are exports of them kept
# for consumers that cannot take vector. Render from the SVG here; the PNG
# exports are a generation behind by definition. The plain cuts carry a white
# wordmark (dark-ground art); the *-color-dark cuts are the authored
# light-ground family (colored arc, near-black cores and wordmark). Do not
# rebuild lockups from mark + font, and do not derive light art by recoloring
# -- both looks were retired in favor of the authored set.
# ---------------------------------------------------------------------------
fit279() { # $1=master $2=destination -- contain into the panel's fixed box
    reduce "$1" 279x80 "$2" -gravity center -extent 279x80
    echo "  $2 (279x80)"
}

echo "GNOME About lockup        <- pulsar-lockup-horizontal (color)"
fit279 "${WORK}/lockup.png" "${S}/pixmaps/fedora_whitelogo_med.png"
echo "GNOME About lockup (light) <- pulsar-lockup-horizontal-color-dark"
fit279 "${WORK}/lockup-dark.png" "${S}/pixmaps/fedora_logo_med.png"

# ---------------------------------------------------------------------------
# Plymouth watermark: the authored color lockup, bottom-center via the theme's
# WatermarkVerticalAlignment. Sized for 2560x1600 like the other physical-size
# assets.
# ---------------------------------------------------------------------------
echo "Plymouth watermark        <- pulsar-lockup-horizontal (color)"
reduce "${WORK}/lockup.png" x96 "${S}/plymouth/themes/pulsar/watermark.png"
echo "  ${S}/plymouth/themes/pulsar/watermark.png ($(magick identify -format '%wx%h' "${S}/plymouth/themes/pulsar/watermark.png"))"

# (The site's light-theme mark is authored art too -- site/stage-assets.mjs
# stages assets/brand/pulsar-mark-color-dark.svg directly; nothing to
# generate.)

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
    # Globbed once into an array: the count then comes from the same list that
    # was installed, rather than from a second glob piped through `ls` that
    # could disagree with it.
    faces=("${A}/fonts/${src}/static/"*.ttf)
    mkdir -p "${S}/fonts/pulsar/${dst}"
    install -m644 "${faces[@]}"                "${S}/fonts/pulsar/${dst}/"
    install -m644 "${A}/fonts/${src}/OFL.txt"  "${S}/fonts/pulsar/${dst}/"
    echo "  ${S}/fonts/pulsar/${dst}/ (${#faces[@]} faces + OFL)"
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
