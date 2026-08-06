#!/usr/bin/env bash
# Render a baked image manifest into the one-pager's manifest card.
#
#   render-manifest.sh manifest.json > site/manifest.html
#
# Same contract as render-changelog.sh: runs in CI, where jq exists; the
# output is committed; site/build.sh only splices, so the deploy can never
# fail over a missing tool. The rows are the ones `pulsar manifest` prints,
# in the CLI's order.
#
# No sbom or attestation row. Both were values that named another command to
# run, which is not what an inventory is for; the CLI dropped them for the
# same reason. The page loses nothing -- its pipeline section IS the
# attestation command, live, with a copy button.
#
# The host rows the CLI prints have no meaning here either: this renders a
# BUILD's manifest, and there is no machine on the other side of it.
#
# Values are escaped through @html: they come from rpm and os-release, and
# metadata is not a trust boundary you want to discover the hard way.
set -euo pipefail

IN=${1:-manifest.json}
[ -r "$IN" ] || { echo "cannot read $IN" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

jq -r '
  def esc: tostring | @html;
  ([ ["image",   (.image // "?") + (if .variant then " (" + .variant + ")" else "" end)],
     ["version", (.version // "?")],
     ["base",    (.base // "?")],
     ["built",   (.built // "?")],
     ["kernel",  (.kernel // "?")]
   ]
   + (.components // {} | to_entries | map([.key, (.value | tostring)]))) as $rows
  | ($rows | map(.[0] | length) | max + 2) as $w
  | "<pre><code>"
    + ($rows
       | map("<span class=\"k\">" + (.[0] | esc) + "</span>"
             + (" " * ($w - (.[0] | length)))
             + (.[1] | esc))
       | join("\n"))
    + "</code></pre>"
' "$IN"
