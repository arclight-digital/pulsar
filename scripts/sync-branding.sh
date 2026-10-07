#!/usr/bin/env bash
# Derive the image's branding files from assets/.
#
# assets/ is the source of truth. Everything this script writes under
# system_files/ is generated or copied -- re-run it whenever the art changes.
#
# assets/brand/ is the designer's v2 package dropped in whole: svg/, png/ and
# in-os/ keep the package's own layout (and its README.md, which says which
# file goes where) so the next drop is a copy, not a re-sort. Two rules from
# that package decide most of what follows:
#
#   * in-os/ is drawn for the OS. The GDM logo, the Plymouth watermark and the
#     app icon were made at their target sizes by the designer, so they are
#     INSTALLED as supplied, not re-derived here. Re-deriving them from a
#     lockup is what this script used to do, and it is exactly the work the
#     in-os files exist to replace.
#   * The mark is a responsive family: the large drawing above 56px, the
#     heavier `-small` drawing from 20 to 56px. A cut that lands at 56px or
#     below is taken from a small drawing, never shrunk from the large one --
#     shrinking the large one is what the small drawing was drawn to avoid.
#
# The cuts that ARE rendered here (the icon sizes, the About lockups) come
# from the SVG rather than from a finished PNG: each is rasterized well above
# its target and reduced from there, so the small fixed-size cuts get
# supersampled edges instead of second-generation pixels. The reduction runs
# in linear light -- reducing light-on-dark art in sRGB thins the strokes --
# and is followed by a soft unsharp pass to put back the edge a reduction
# costs. The unsharp THRESHOLD is what keeps that pass off the marks' glow
# gradient, which beads and rings if you sharpen it. Raise the amount and you
# get a rim on the wordmark long before the glow survives it.
#
# The icon art is a full 256 tile and is never trimmed; the lockups ARE
# trimmed on purpose, because their cuts are fitted to a fixed panel box.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A="${REPO}/assets"
B="${A}/brand"
S="${REPO}/system_files/usr/share"

command -v magick >/dev/null || { echo "needs ImageMagick 7 (magick)" >&2; exit 1; }
# grep's status alone: in a pipe, magick dying of SIGPIPE once grep -q has
# matched would read, under pipefail, as no librsvg
grep -qi 'SVG.*RSVG' < <(magick -list format) || {
    echo "needs an ImageMagick built against librsvg -- its own MSVG renderer" >&2
    echo "ignores <filter>, which silently drops the marks' glow" >&2; exit 1; }
for f in svg/pulsar-mark-small.svg svg/pulsar-tile-small.svg \
         svg/pulsar-lockup-horizontal.svg svg/pulsar-lockup-horizontal-light.svg \
         in-os/pulsar-logo-icon.svg in-os/pulsar-gdm-logo.png in-os/watermark.png; do
    [[ -r "${B}/${f}" ]] || { echo "missing asset: ${B}/${f}" >&2; exit 1; }
done

# Soft by design: enough to recover the edge the reduction costs, not enough to
# rim the wordmark. SHARPEN=none renders flat.
SHARPEN="${SHARPEN:-0x0.5+0.30+0.015}"
SHARP=(); [[ "${SHARPEN}" == none ]] || SHARP=(-unsharp "${SHARPEN}")

# No fontconfig binding any more. The v1 lockups set PULSAR as live <text>, so
# an unresolvable Host Grotesk quietly substituted and the wordmark shipped
# wrong; this script used to pin fontconfig to the repo's cuts for that
# reason. v2's wordmark is converted to outlines, so the render no longer
# touches a font at all -- and a check for a font nothing reads would only be
# a way for this script to fail for no reason.
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

# One high rasterization per source, reused by every cut taken from it.
# 768dpi puts the 256-unit icon art at 2048px (4x the largest icon); 384dpi
# puts the ~883-unit lockups at ~4700px, far past 4x the 279px About cut.
magick -background none -density 768 "${B}/in-os/pulsar-logo-icon.svg" \
       -depth 16 "${WORK}/icon.png"
magick -background none -density 768 "${B}/svg/pulsar-tile-small.svg" \
       -depth 16 "${WORK}/icon-small.png"
magick -background none -density 384 "${B}/svg/pulsar-lockup-horizontal.svg" \
       -trim +repage -depth 16 "${WORK}/lockup.png"
magick -background none -density 384 "${B}/svg/pulsar-lockup-horizontal-light.svg" \
       -trim +repage -depth 16 "${WORK}/lockup-light.png"

# Reduce a master to a target: linear light, Lanczos, soft unsharp. Extra
# magick arguments (gravity/extent) land after the resize, before the write.
reduce() { # $1=master $2=resize-geometry $3=destination [extra magick args...]
    local src="$1" geom="$2" dst="$3"; shift 3
    mkdir -p "$(dirname "${dst}")"
    magick -background none "${src}" \
           -colorspace RGB -filter Lanczos -resize "${geom}" -colorspace sRGB \
           "${SHARP[@]}" "$@" -depth 8 -strip "${dst}"
}

# Install a file the designer drew for its target, and say what it is: these
# are fixed-size PNGs, so the size printed is the size that ships.
supplied() { # $1=source $2=destination
    install -Dm644 "$1" "$2"
    echo "  $2 ($(magick identify -format '%wx%h' "$2"), as supplied)"
}

# ---------------------------------------------------------------------------
# Icons
#
# in-os/pulsar-logo-icon.svg is the tile (the mark on a navy rounded square),
# not the bare mark the v1 icon was: a transparent mark is unreadable on a
# light launcher grid, and the tile is what the designer handed over as the
# app/system icon. It is svg/pulsar-tile.svg under the OS's name.
#
# The large sizes come from it. 48px is in the small range, so it comes from
# svg/pulsar-tile-small.svg, the same tile with the heavier small drawing and
# no star field -- at 48px the stars are only noise, and the large drawing's
# tapered tail thins to nothing.
# ---------------------------------------------------------------------------
echo "App icon (hicolor)        <- in-os/pulsar-logo-icon (>56px), svg/pulsar-tile-small (<=56px)"
install -Dm644 "${B}/in-os/pulsar-logo-icon.svg" \
               "${S}/icons/hicolor/scalable/apps/pulsar-logo-icon.svg"
echo "  ${S}/icons/hicolor/scalable/apps/pulsar-logo-icon.svg"
for sz in 512 256 128 64 48; do
    master="${WORK}/icon.png"; (( sz <= 56 )) && master="${WORK}/icon-small.png"
    reduce "${master}" "${sz}x${sz}" \
           "${S}/icons/hicolor/${sz}x${sz}/apps/pulsar-logo-icon.png"
    echo "  ${S}/icons/hicolor/${sz}x${sz}/apps/pulsar-logo-icon.png (${sz}px)"
done

# The welcome's hero mark: the large drawing, shown well above 56px, in both
# colourings so it follows Dark Style. Vector, installed as supplied.
echo "Welcome mark              <- svg/pulsar-mark, svg/pulsar-mark-light"
for m in pulsar-mark pulsar-mark-light; do
    install -Dm644 "${B}/svg/${m}.svg" "${S}/pulsar/brand/${m}.svg"
    echo "  ${S}/pulsar/brand/${m}.svg"
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
#
# The designer's cut, drawn with the small mark: 320x88, cropped tight to the
# lockup (v1 shipped 320x77 with margin). Nothing in the override pins a
# height, so the new crop needs no config change. The key takes ONE file, so
# in-os/pulsar-gdm-logo-2x.png has no slot here; it stays in assets/brand for
# the day a HiDPI greeter wants it.
echo "GDM login                 <- in-os/pulsar-gdm-logo.png"
supplied "${B}/in-os/pulsar-gdm-logo.png" "${S}/pulsar/pulsar-gdm-logo.png"

# The terminal mark for `pulsar manifest`, from the same SVG as everything
# else. Generated here so it cannot drift from the artwork: a hand-drawn copy
# was wrong about the shape within a day of being written.
#
# The SMALL drawing, by the family's own size rule: 38 raster columns is a
# 38px mark, inside the 20-56px small range. The large drawing's tail tapers
# to a soft point that falls below one character well before the end of the
# sweep, which is the part that makes it a sweep and not a ring.
#
# --rows is the height of the art in lines; its width follows from the mark's
# own proportions and the terminal cell's (measured from JetBrains Mono), so
# the mark comes out round. 19 rows is the point -- that is the height of a
# typical readout (5 header rows, 6 or 7 host rows, 7 components), so the art
# and the information end together instead of the mark stopping short of the
# values beside it. At 19 rows the small mark is 38 columns wide.
python3 "${REPO}/scripts/render-ascii-logo.py" "${B}/svg/pulsar-mark-small.svg" \
        --rows 19 -o "${S}/pulsar/logo.ansi"

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
# So the filenames stay Fedora's: the path is hardcoded in a binary, and
# overwriting one file beats patching gnome-control-center. 279x80 is the size
# Fedora ships; the panel does not scale it.
#
# Rendered, because the designer did not draw a 279x80 cut: the plain
# horizontal lockup for dark, the -light one for light. At 279 wide the mark
# is ~75px, above 56, so the large drawing the lockups carry is the right one.
# Do not derive light art by recolouring the dark lockup -- -light is authored
# with its own gradient direction and a deep-violet core.
# ---------------------------------------------------------------------------
fit279() { # $1=master $2=destination -- contain into the panel's fixed box
    reduce "$1" 279x80 "$2" -gravity center -extent 279x80
    echo "  $2 (279x80)"
}

echo "GNOME About lockup        <- svg/pulsar-lockup-horizontal"
fit279 "${WORK}/lockup.png" "${S}/pixmaps/fedora_whitelogo_med.png"
echo "GNOME About lockup (light) <- svg/pulsar-lockup-horizontal-light"
fit279 "${WORK}/lockup-light.png" "${S}/pixmaps/fedora_logo_med.png"

# ---------------------------------------------------------------------------
# Plymouth watermark: the designer's cut for black, 400x110, bottom-centre via
# the theme's WatermarkVerticalAlignment (a fraction, not a pixel offset, so
# the taller crop needs no .plymouth change).
#
# two-step loads one watermark.png at whatever scale the framebuffer is and
# has no @2x lookup, so in-os/watermark-2x.png has no home in the theme. It
# stays in assets/brand; switching to it is a physical-size decision (twice
# the size on every panel), not a HiDPI one.
# ---------------------------------------------------------------------------
echo "Plymouth watermark        <- in-os/watermark.png"
supplied "${B}/in-os/watermark.png" "${S}/plymouth/themes/pulsar/watermark.png"

# (The site's marks are the package's svg/ files, staged directly by
# pulsar-site's stage-assets.mjs; nothing to generate.)

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
