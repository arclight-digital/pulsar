#!/usr/bin/env bash
# Assemble the deployable site into site/_site (gitignored).
#
# Brand assets and the wallpaper shader are staged from assets/ at build time
# so the page and the OS can never drift apart -- do NOT hand-copy files into
# site/. OFL.txt travels with the fonts; the license requires it.
#
# Local preview:  ./site/build.sh && python3 -m http.server -d site/_site
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO}/site/_site"

rm -rf "${OUT}"
mkdir -p "${OUT}/assets"

cp "${REPO}/site/index.html" "${REPO}/site/style.css" "${REPO}/site/main.js" "${OUT}/"
cp "${REPO}/assets/icons/pulsar-mark.svg" \
   "${REPO}/assets/icons/favicon.svg" \
   "${REPO}/assets/shaders/pulsar.frag" \
   "${REPO}/assets/fonts/Host_Grotesk/static/HostGrotesk-Regular.ttf" \
   "${REPO}/assets/fonts/Host_Grotesk/static/HostGrotesk-Bold.ttf" \
   "${REPO}/assets/fonts/Host_Grotesk/OFL.txt" \
   "${OUT}/assets/"

echo "site assembled at ${OUT}:"
du -sh "${OUT}" | cut -f1
