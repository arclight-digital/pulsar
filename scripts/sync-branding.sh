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
         pulsar-mark-mono.svg pulsar-mark-ink.svg; do
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

# Full color, not mono: plymouth composites the watermark PNG as-is on the
# splash background, and the color mark reads correctly there -- same dark
# ground as the wallpapers. (The mono cut was an overcorrection; only GDM
# keeps it, whose grey ground genuinely fights the color art.)
echo "Plymouth watermark        <- pulsar-mark (color)"
png "${A}/icons/pulsar-mark-1024.png" "${PLYMOUTH_PX}" "${S}/plymouth/themes/pulsar/watermark.png"

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
# The mark alone looks wrong here -- Fedora fills this slot with a lockup, so
# this is the one place the wordmark exists. The wordmark is PULSAR in Host
# Grotesk Bold, uppercase, tracked 0.3em, which is the brand treatment;
# it is NOT the UI font weight, and tightening the tracking kills it.
#
# The mark is sized to fit the 80px height COMPLETELY. Its gaussian glow is
# soft alpha with no hard boundary, so any overflow clips to a straight edge
# and reads as a cropped logo -- the glow has to live inside the canvas even
# though that makes the visible disc smaller than the box suggests.
#
# Two cuts because the panel background flips with the theme: the mono art
# disappears on light, and the color art's white core disappears just as badly,
# hence pulsar-mark-ink.svg for the light side.
# ---------------------------------------------------------------------------
lockup() { # $1=mark svg  $2=text colour  $3=destination
    magick -background none "$1" -resize 1024x1024 -trim -resize x76 "${TMP}/mark.png"
    magick -background none -fill "$2" -font "${WORDMARK_FONT}" \
           -pointsize "${WORDMARK_PT}" -kerning "${WORDMARK_TRACK}" label:PULSAR -trim "${TMP}/word.png"
    magick "${TMP}/mark.png" "${TMP}/word.png" -background none -gravity center +smush 14 \
           -background none -gravity center -extent 279x80 -strip "$3"
    echo "  $3 (279x80)"
}
# 0.3em of tracking is the brand spec (44px/700/0.3em in the poster cut);
# expressed here as a ratio so the pointsize can change without breaking it.
WORDMARK_PT=30
WORDMARK_TRACK=$(awk "BEGIN{printf \"%.0f\", ${WORDMARK_PT:-30}*0.3}")
WORDMARK_FONT="${A}/fonts/Host_Grotesk/static/HostGrotesk-Bold.ttf"
[[ -r "${WORDMARK_FONT}" ]] || { echo "missing wordmark font: ${WORDMARK_FONT}" >&2; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

echo "GNOME About lockup        <- pulsar-mark-mono + Host Grotesk"
lockup "${A}/icons/pulsar-mark-mono.svg" white     "${S}/pixmaps/fedora_whitelogo_med.png"
echo "GNOME About lockup (light) <- pulsar-mark-ink + Host Grotesk"
lockup "${A}/icons/pulsar-mark-ink.svg"  '#241F3D' "${S}/pixmaps/fedora_logo_med.png"

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
