#!/usr/bin/env bash
# Render changelog.json into a static HTML fragment for the one-pager.
#
#   render-changelog.sh changelog.json > site/changelog.html
#
# Runs in CI, where jq exists -- deliberately NOT in site/build.sh, which is
# executed by Cloudflare's build image and is kept to plain `cp` so the page
# can never fail to deploy because a tool was missing from someone's builder.
#
# Everything is escaped through jq's @html. The input is machine-generated
# from an SBOM, but package names reach it from RPM metadata, and metadata is
# not a trust boundary you want to discover the hard way.
set -euo pipefail

IN=${1:-changelog.json}
[ -r "$IN" ] || { echo "cannot read $IN" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# Rows shown per list. The remainder is COUNTED in the page, never dropped
# silently -- a truncated list that looks complete is how a changelog starts
# lying about what shipped.
LIMIT=${CHANGELOG_LIMIT:-25}

jq -r --argjson limit "$LIMIT" '
  def esc: . // "" | @html;
  def rows(list; render):
    (list | length) as $n |
    if $n == 0 then ""
    else
      (list[:$limit] | map(render) | join("\n")) +
      (if $n > $limit
       then "\n<li class=\"cl-more\">and \($n - $limit) more</li>"
       else "" end)
    end;

  .summary as $s |
  "<p class=\"cl-meta\">Generated \(.generated | esc)" +
  (if .baseline == true
   then " · first build, nothing to compare against yet"
   else " · \($s.upgraded) upgraded · \($s.added) added · \($s.removed) removed" +
        (if $s.downgraded > 0 then " · \($s.downgraded) downgraded" else "" end) +
        (if $s.changed > 0 then " · \($s.changed) changed" else "" end)
   end) + "</p>",

  (if (.changed | length) > 0 then
    "<h3 class=\"cl-h\">Upgraded</h3>\n<ul class=\"cl-list\">\n" +
    rows([.changed[] | select(.direction != "downgraded")];
         "<li><span class=\"cl-pkg\">\(.name | esc)</span>" +
         "<span class=\"cl-ver\">\(.from | esc) → \(.to | esc)</span></li>") +
    "\n</ul>"
  else "" end),

  (if ([.changed[] | select(.direction == "downgraded")] | length) > 0 then
    "<h3 class=\"cl-h\">Downgraded</h3>\n<ul class=\"cl-list\">\n" +
    rows([.changed[] | select(.direction == "downgraded")];
         "<li><span class=\"cl-pkg\">\(.name | esc)</span>" +
         "<span class=\"cl-ver\">\(.from | esc) → \(.to | esc)</span></li>") +
    "\n</ul>"
  else "" end),

  (if (.added | length) > 0 then
    "<h3 class=\"cl-h\">Added</h3>\n<ul class=\"cl-list\">\n" +
    rows(.added;
         "<li><span class=\"cl-pkg\">\(.name | esc)</span>" +
         "<span class=\"cl-ver\">\(.version | esc)</span></li>") +
    "\n</ul>"
  else "" end),

  (if (.removed | length) > 0 then
    "<h3 class=\"cl-h\">Removed</h3>\n<ul class=\"cl-list\">\n" +
    rows(.removed;
         "<li><span class=\"cl-pkg\">\(.name | esc)</span>" +
         "<span class=\"cl-ver\">\(.version | esc)</span></li>") +
    "\n</ul>"
  else "" end)
' "$IN" | grep -v '^$' || true
