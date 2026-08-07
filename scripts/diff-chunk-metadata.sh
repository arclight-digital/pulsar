#!/usr/bin/bash
# Did the rechunk change any file's mode or ownership on the way through?
#
# rpm-ostree compose build-chunked-oci re-slices a finished image by writing
# it through an ostree commit and exporting fresh layers. That round trip is
# supposed to be metadata-preserving, and mostly is -- but there is a known
# upstream class of bug where directory permissions and ownership come out
# different from the base commit. On an image that carries an enrolled Secure
# Boot key and signed kmods, "mostly" is not the standard: a mode that drifts
# on /usr/lib/modules or an ownership change under /etc/pki is the kind of
# thing that is invisible until a machine refuses to boot or a signature stops
# verifying, and by then it has shipped.
#
# So the build asks, instead of trusting the tool. Both sides are listed with
# tar, so the comparison is apples to apples: symbolic modes and numeric
# uid/gid from the same producer, never `find` on one side and tar on the
# other. Neither side is unpacked -- the source streams through `podman
# export` and the chunked side is read straight out of the layout's blobs.
#
# Two transformations are EXPECTED and are not drift:
#
#   /etc -> /usr/etc   ostree stores the commit's /etc under /usr/etc, so
#                      chunked usr/etc/foo is compared against source etc/foo.
#   /var emptied       bootc owns /var at runtime; the image is not where its
#                      content lives. Only usr/ and etc/ are compared.
#
# Usage:
#   diff-chunk-metadata.sh <source-image> <oci-layout-dir> <tag>
#
# Exit: 0 clean (or benign drift, reported), 1 drift that must not ship,
#       2 could not determine.
#
# "Could not determine" is not clean, for the reason check-scx-btf.sh gives:
# a gate that degrades to a guess is how the thing it guards gets shipped.
set -uo pipefail

SOURCE_IMAGE="${1:?usage: diff-chunk-metadata.sh <source-image> <layout-dir> <tag>}"
LAYOUT="${2:?usage: diff-chunk-metadata.sh <source-image> <layout-dir> <tag>}"
TAG="${3:?usage: diff-chunk-metadata.sh <source-image> <layout-dir> <tag>}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# GNU tar -tv prints: mode owner/group size date time name[ -> target]
#   -rwxr-xr-x 0/0    1234 2026-08-06 12:00 usr/bin/foo
#   lrwxrwxrwx 0/0       0 2026-08-06 12:00 usr/bin/bar -> baz
#   hrw-r--r-- 0/0       0 2026-08-06 12:00 usr/bin/qux link to usr/bin/foo
#
# Name starts at field 6 and may contain spaces, so it is everything from
# there minus the link suffix. Hardlinks carry no mode of their own worth
# comparing -- tar prints the link's, not the target's -- so they are recorded
# as links and resolved against the target entry after the union is built.
# Directories arrive with a trailing slash on one side and not always the
# other; a leading ./ is likewise a producer's habit, not a path difference.
#
# Written out as a file rather than inlined so the parallel pass below can run
# it with awk -f. One implementation, used by both sides -- the whole point of
# this script is that the two sides are read by the same producer.
cat > "${WORK}/normalise.awk" <<'NORMALISE'
    {
      mode = $1
      split($2, own, "/")
      name = ""
      for (i = 6; i <= NF; i++) name = name (i > 6 ? " " : "") $i

      link = ""
      if (match(name, / -> /))     { link = substr(name, RSTART + 4); name = substr(name, 1, RSTART - 1) }
      else if (match(name, / link to /)) { link = substr(name, RSTART + 9); name = substr(name, 1, RSTART - 1)
                                           mode = "@hardlink" }

      sub(/^\.\//, "", name); sub(/^\//, "", name)
      sub(/^\.\//, "", link); sub(/^\//, "", link)
      if (name == "" || name == ".") next
      if (name != "/" ) sub(/\/$/, "", name)

      # whiteouts are a layered-image concept; a freshly composed rootfs
      # must not contain any, and one here would mean the union below is
      # hiding a deletion rather than describing a filesystem.
      n = split(name, seg, "/")
      if (seg[n] ~ /^\.wh\./) { print "WHITEOUT\t" name > "/dev/stderr"; next }

      print name "\t" mode "\t" own[1] "\t" own[2] "\t" link
    }
NORMALISE

normalise() { awk -f "${WORK}/normalise.awk"; }

# ---------------------------------------------------------------------------
# Source side: the image podman just built, flattened by export. A created
# container is never started, so nothing runs; export just streams its rootfs.
# ---------------------------------------------------------------------------
cid="$(podman create "${SOURCE_IMAGE}" /bin/true 2>/dev/null)"
if [ -z "${cid}" ]; then
  echo "cannot create a container from ${SOURCE_IMAGE}" >&2
  exit 2
fi
podman export "${cid}" 2>/dev/null \
  | tar -tv --numeric-owner -f - 2>/dev/null \
  | normalise > "${WORK}/source.raw" 2>"${WORK}/source.wh"
podman rm -f "${cid}" >/dev/null 2>&1

if [ ! -s "${WORK}/source.raw" ]; then
  echo "listed nothing from ${SOURCE_IMAGE}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Chunked side: every layer in manifest order, later layers winning, read
# from the blobs already on disk. tar auto-detects the compression, so this
# does not care whether the tool wrote gzip or zstd.
# ---------------------------------------------------------------------------
manifest="$(skopeo inspect --raw "oci:${LAYOUT}:${TAG}" 2>/dev/null)"
if [ -z "${manifest}" ]; then
  echo "cannot read a manifest from oci:${LAYOUT}:${TAG}" >&2
  exit 2
fi

layers="$(printf '%s' "${manifest}" | jq -r '.layers[].digest')"
if [ -z "${layers}" ]; then
  echo "manifest lists no layers" >&2
  exit 2
fi

count=0
: > "${WORK}/blobs.list"
while read -r digest; do
  blob="${LAYOUT}/blobs/sha256/${digest#sha256:}"
  [ -f "${blob}" ] || { echo "missing blob for ${digest}" >&2; exit 2; }
  printf '%05d %s\n' "${count}" "${blob}" >> "${WORK}/blobs.list"
  count=$((count + 1))
done <<< "${layers}"

# Read in parallel, CONCATENATE IN MANIFEST ORDER. Two hundred layers of
# single-threaded gunzip is most of this script's wall clock, and on a build
# host whose store is a network volume it is the difference between a minute
# and twenty. Order is not cosmetic -- the union below keeps the LAST writer
# for each path, so a reordered concatenation silently compares the wrong
# layer. Zero-padded indices make the glob restore manifest order exactly.
# shellcheck disable=SC2016  # $1..$3 are sh -c's positionals, not this shell's
xargs -P "$(nproc 2>/dev/null || echo 4)" -L1 sh -c '
  tar -tv --numeric-owner -f "$3" 2>/dev/null \
    | awk -f "$1/normalise.awk" > "$1/part.$2.raw" 2> "$1/part.$2.wh"
' _ "${WORK}" < "${WORK}/blobs.list"

cat "${WORK}"/part.*.raw > "${WORK}/chunked.raw"
cat "${WORK}"/part.*.wh  > "${WORK}/chunked.wh"
rm -f "${WORK}"/part.*
echo "compared ${count} chunked layers against ${SOURCE_IMAGE}"

if [ -s "${WORK}/chunked.wh" ]; then
  echo "whiteout entries in a freshly composed rootfs:" >&2
  sort -u "${WORK}/chunked.wh" | head -20 >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Union, expected transforms, and scope. Last writer wins on both sides --
# tac | sort -u -k1,1 keeps the LAST line for each path, since sort -u keeps
# the first of equal keys and tac has already reversed layer order.
# ---------------------------------------------------------------------------
union() {
  tac "$1" | sort -u -t"$(printf '\t')" -k1,1
}
union "${WORK}/source.raw"  > "${WORK}/source.all"
union "${WORK}/chunked.raw" > "${WORK}/chunked.all"

# hardlinks take their target's mode, resolved within the same side
resolve_links() {
  awk -F'\t' '
    NR == FNR { mode[$1] = $2; uid[$1] = $3; gid[$1] = $4; next }
    {
      if ($2 == "@hardlink" && $5 in mode) { $2 = mode[$5]; $3 = uid[$5]; $4 = gid[$5] }
      print $1 "\t" $2 "\t" $3 "\t" $4
    }
  ' OFS='\t' "$1" "$1"
}

# ostree keeps the commit's /etc at /usr/etc; map it back so the comparison
# is about metadata rather than about a layout the tool is meant to apply.
scope() {
  resolve_links "$1" | awk -F'\t' '
    {
      p = $1
      sub(/^usr\/etc\//, "etc/", p)
      if (p !~ /^(usr|etc)\//) next
      print p "\t" $2 "\t" $3 "\t" $4
    }
  ' | sort -u -t"$(printf '\t')" -k1,1
}
scope "${WORK}/source.all"  > "${WORK}/source.cmp"
scope "${WORK}/chunked.all" > "${WORK}/chunked.cmp"

join -t"$(printf '\t')" -j1 -o 0,1.2,1.3,1.4,2.2,2.3,2.4 \
  "${WORK}/source.cmp" "${WORK}/chunked.cmp" > "${WORK}/both"
join -t"$(printf '\t')" -j1 -v1 "${WORK}/source.cmp" "${WORK}/chunked.cmp" \
  > "${WORK}/only-source"

# ---------------------------------------------------------------------------
# Classify. Ownership changes, setuid/setgid bits gained or lost, and new
# world-writability are the classes that matter to a signed, Secure Boot
# image: they change who can write what the bootloader and kmod chain trust.
# Everything else is reported and does not stop the build, because the point
# of the first runs is to learn what this tool actually does to an image.
# ---------------------------------------------------------------------------
awk -F'\t' '
  function bit(m, i) { return substr(m, i, 1) }
  {
    path = $1; smode = $2; suid = $3; sgid = $4; cmode = $5; cuid = $6; cgid = $7
    if (smode == cmode && suid == cuid && sgid == cgid) next

    critical = 0
    if (suid != cuid || sgid != cgid) critical = 1
    if ((bit(smode,4) ~ /[sS]/) != (bit(cmode,4) ~ /[sS]/)) critical = 1
    if ((bit(smode,7) ~ /[sS]/) != (bit(cmode,7) ~ /[sS]/)) critical = 1
    if (bit(smode,9) != "w" && bit(cmode,9) == "w") critical = 1

    line = path "  " smode " " suid ":" sgid "  ->  " cmode " " cuid ":" cgid
    if (critical) print line > "/dev/stderr"; else print line
  }
' "${WORK}/both" > "${WORK}/benign" 2>"${WORK}/critical"

benign=$(wc -l < "${WORK}/benign")
critical=$(wc -l < "${WORK}/critical")
missing=$(wc -l < "${WORK}/only-source")

if [ "${benign}" -gt 0 ]; then
  echo "mode drift on ${benign} path(s), none security-relevant:"
  head -40 "${WORK}/benign" | sed 's/^/  /'
  [ "${benign}" -gt 40 ] && echo "  ... and $((benign - 40)) more"
fi

if [ "${missing}" -gt 0 ]; then
  echo "paths in the source image that the chunked image does not have:" >&2
  head -40 "${WORK}/only-source" | cut -f1 | sed 's/^/  /' >&2
  [ "${missing}" -gt 40 ] && echo "  ... and $((missing - 40)) more" >&2
fi

if [ "${critical}" -gt 0 ]; then
  echo "ownership or privilege-bit changes across the rechunk:" >&2
  head -40 "${WORK}/critical" | sed 's/^/  /' >&2
  [ "${critical}" -gt 40 ] && echo "  ... and $((critical - 40)) more" >&2
fi

if [ "${critical}" -gt 0 ] || [ "${missing}" -gt 0 ]; then
  exit 1
fi

echo "no ownership, setuid/setgid, or world-writable changes across the rechunk"
exit 0
