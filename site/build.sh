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

cp "${REPO}/site/style.css" "${REPO}/site/main.js" "${OUT}/"

# The changelog section is spliced in at the <!--CHANGELOG--> marker rather
# than fetched at runtime, so the package list is in the HTML the crawler and
# the no-JS reader both get.
#
# changelog.html is rendered and committed by the nightly image build (jq
# lives there, not here) -- this loop stays plain awk so the page can never
# fail to deploy over a missing tool in Cloudflare's builder. Before the first
# nightly lands, the marker collapses to a placeholder instead of a hole.
CHANGELOG_FRAGMENT="${REPO}/site/changelog.html"
MANIFEST_FRAGMENT="${REPO}/site/manifest.html"
awk -v frag="${CHANGELOG_FRAGMENT}" '
  /<!--CHANGELOG-->/ {
    n = 0
    while ((getline line < frag) > 0) { print line; n++ }
    close(frag)
    if (n == 0)
      print "<p class=\"cl-meta\">The first nightly has not published a changelog yet.</p>"
    next
  }
  { print }
' "${REPO}/site/index.html" \
| awk -v frag="${MANIFEST_FRAGMENT}" '
  /<!--MANIFEST-->/ {
    n = 0
    while ((getline line < frag) > 0) { print line; n++ }
    close(frag)
    if (n == 0)
      print "<pre><code>the first nightly has not rendered a manifest yet</code></pre>"
    next
  }
  { print }
' > "${OUT}/index.html"

# The raw diff and manifest, served next to the page they are rendered from.
if [ -f "${REPO}/site/changelog.json" ]; then
  cp "${REPO}/site/changelog.json" "${OUT}/"
fi
if [ -f "${REPO}/site/manifest.json" ]; then
  cp "${REPO}/site/manifest.json" "${OUT}/"
fi
cp "${REPO}/assets/brand/pulsar-mark.svg" \
   "${REPO}/assets/brand/pulsar-mark-color-dark.svg" \
   "${REPO}/assets/brand/pulsar-animated.svg" \
   "${REPO}/assets/brand/pulsar-animated-color-dark.svg" \
   "${REPO}/assets/brand/favicon.svg" \
   "${REPO}/assets/shaders/pulsar.frag" \
   "${REPO}/assets/fonts/Host_Grotesk/static/HostGrotesk-Regular.ttf" \
   "${REPO}/assets/fonts/Host_Grotesk/static/HostGrotesk-Bold.ttf" \
   "${REPO}/assets/fonts/JetBrains_Mono/static/JetBrainsMono-Regular.ttf" \
   "${OUT}/assets/"
# committed silk stills: the no-WebGL/while-loading hero fallback. The one
# exception to "nothing rendered lives in git" -- silk is locked, the pair is
# ~180KB total, and regenerating is documented in the file's sibling renders.
cp "${REPO}/site/assets-static/gamescale.svg" "${OUT}/assets/"
cp "${REPO}/site/assets-static/silk-still-dark.jpg" \
   "${REPO}/site/assets-static/silk-still-light.jpg" \
   "${REPO}/site/assets-static/og.jpg" \
   "${OUT}/assets/"
# both font licenses travel with their fonts; distinct names, one dir
cp "${REPO}/assets/fonts/Host_Grotesk/OFL.txt"   "${OUT}/assets/OFL-host-grotesk.txt"
cp "${REPO}/assets/fonts/JetBrains_Mono/OFL.txt" "${OUT}/assets/OFL-jetbrains-mono.txt"

echo "site assembled at ${OUT}:"
du -sh "${OUT}" | cut -f1
