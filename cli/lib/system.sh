# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): pulsar status and pulsar manifest: the image and the machine.

# ---------------------------------------------------------------------------
# status / manifest
# ---------------------------------------------------------------------------
# The fields of `rpm-ostree status --json` that matter, and the only shape
# Pulsar hands out: `status --json` and `report` both use it.
STATUS_JQ='{ deployments: [ .deployments[]? | with_entries(select(.key | IN(
    "booted", "staged", "pinned", "version", "timestamp", "checksum",
    "container-image-reference", "container-image-reference-digest",
    "requested-packages", "requested-local-packages",
    "requested-base-removals", "requested-base-local-replacements"))) ] }'

cmd_status() {
    need rpm-ostree
    local js; js=$(rpm-ostree status --json 2>/dev/null) || die "could not read deployment status"
    if [ "${JSON:-0}" = 1 ]; then printf '%s' "$js" | jq "$STATUS_JQ"; return 0; fi
    # The image reference sheds its whole transport prefix -- a single strip
    # left "docker://" behind on "ostree-image-signed:docker://ghcr.io/...".
    local tsv
    tsv=$(printf '%s' "$js" | jq -r '
      .deployments[]? |
      (if .booted then "booted" elif .staged then "staged" else "-" end) + "\t"
      + (.version // "?") + "\t"
      + ((."container-image-reference" // .origin // "?") | sub("^([a-z-]+:)+(//)?"; "")) + "\t"
      + (if .pinned then "yes" else "no" end)')
    [ -n "$tsv" ] || { printf 'no deployments reported\n'; return 0; }

    # Columns measured from the data, like the manifest. The image reference
    # is the elastic column: truncated only when a real terminal is too
    # narrow to hold it -- a hardcoded 42 was cutting the tag off refs on
    # terminals with a hundred columns to spare -- and a pipe always gets
    # the full reference.
    local verw=7 imgw=5 state ver img pin
    while IFS=$'\t' read -r state ver img pin; do
        [ "${#ver}" -gt "$verw" ] && verw=${#ver}
        [ "${#img}" -gt "$imgw" ] && imgw=${#img}
    done <<<"$tsv"
    local cols=0 max=0
    [ -n "$C_RESET" ] && cols=$(tput cols 2>/dev/null || echo 0)
    if [ "$cols" -gt 0 ]; then
        max=$((cols - 8 - 1 - verw - 1 - 1 - 6))   # state, gaps, version, pinned
        if [ "$max" -ge 12 ] && [ "$imgw" -gt "$max" ]; then imgw=$max; else max=0; fi
    fi

    printf '%s%-8s %-*s %-*s %s%s\n' "$C_BOLD" "STATE" "$verw" "VERSION" "$imgw" "IMAGE" "PINNED" "$C_RESET"
    while IFS=$'\t' read -r state ver img pin; do
        if [ "$max" -gt 0 ] && [ "${#img}" -gt "$max" ]; then
            img="${img:0:max-3}..."
        fi
        printf '%-8s %-*s %-*s %s\n' "$state" "$verw" "$ver" "$imgw" "$img" "$pin"
    done <<<"$tsv"
}

# ---------------------------------------------------------------------------
# The machine, as opposed to the image. This is fastfetch's half of the
# readout, and it follows fastfetch's rule: everything is read at run time and
# every row is OPTIONAL. A VM with no DMI table, a tty with no session, a
# build container with no /sys -- each drops its row rather than printing a
# question mark, because a manifest full of "?" reads like a broken command
# instead of an honest one. Nothing below may fail `manifest`: every reader
# returns non-zero instead of dying, and its caller skips it.
#
# The readers return RAW values and the formatting lives in host_rows, for the
# same reason the manifest rows leave jq untouched: `--json` needs the number,
# the terminal needs "8.1 GiB / 62.2 GiB", and a reader that only knows how to
# produce the second cannot serve the first.
# ---------------------------------------------------------------------------

# Vendors disagree about which DMI field holds the name a human would use.
# Lenovo puts the marketing name in product_version and a model code ("83F5")
# in product_name; Dell does the reverse and parks "Not Specified" in version.
# Trying them in this order, with the known placeholder strings filtered, gets
# both right without special-casing either vendor.
dmi_model() {
    local f v
    for f in product_version product_family product_name; do
        v=$(cat "/sys/devices/virtual/dmi/id/$f" 2>/dev/null) || continue
        case "$v" in
            ""|None|"To Be Filled By O.E.M."|"System Product Name"|\
            "Default string"|"Not Specified"|"Not Applicable"|"INVALID") continue ;;
        esac
        printf '%s\n' "$v"; return 0
    done
    return 1
}

# "Intel(R) Core(TM) Ultra 9 275HX" is the string the kernel exports; the
# trademark noise is not information.
cpu_name() {
    local m
    m=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -1)
    [ -n "$m" ] || return 1
    m=${m//(R)/}; m=${m//(TM)/}; m=${m//(tm)/}; m=${m//(C)/}
    m=$(printf '%s' "$m" | tr -s ' '); m=${m# }; m=${m% }
    printf '%s\n' "$m"
}

# Threads rather than cores: nproc is what schedulers and gamescope see.
cpu_threads() { nproc 2>/dev/null || return 1; }

# One row per display-class PCI device, in bus order, the way fastfetch prints
# a GPU line each. 3D-controller class is included on purpose: on most hybrid
# laptops the discrete card enumerates as 0302, not 0300, and filtering to VGA
# alone hides the card the user bought this image for. Without pciutils the
# vendor:device pair still goes out -- it is enough to look up, and better
# than silence.
gpu_names() {
    local line d found=1
    if have lspci; then
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            # "GB203M / GN22-X9 [GeForce RTX 5080 Max-Q]" -> the bracketed
            # marketing name, which is the half anyone recognises.
            case "$d" in *'['*']'*) d=${d##*[}; d=${d%%]*} ;; esac
            printf '%s\n' "$d"; found=0
        done < <(lspci -mm 2>/dev/null | awk -F'"' \
            '$2 ~ /VGA compatible controller|3D controller|Display controller/ { print $6 }')
    else
        for line in /sys/bus/pci/devices/*; do
            case "$(cat "$line/class" 2>/dev/null)" in
                0x03*) printf '%s:%s\n' \
                    "$(cat "$line/vendor" 2>/dev/null)" \
                    "$(cat "$line/device" 2>/dev/null)"; found=0 ;;
            esac
        done
    fi
    return "$found"
}

gib() { awk -v k="$1" 'BEGIN { printf "%.1f GiB\n", k / 1048576 }'; }

# "used total", in kB, as /proc/meminfo reports them. "Used" is total minus
# MemAvailable rather than minus MemFree: cache and reclaimable slab are not
# memory you have lost, and MemFree alone makes every healthy Linux box look
# full. MemAvailable predates every kernel this image can boot, but if it is
# somehow missing, used goes out as "-" rather than as a fabricated number.
mem_kb() {
    local total avail
    total=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null) || return 1
    [ -n "$total" ] || return 1
    avail=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null)
    if [ -n "$avail" ]; then printf '%s %s\n' "$((total - avail))" "$total"
    else                     printf -- '- %s\n' "$total"; fi
}

# Used / total, fastfetch's form.
mem_used_total() {
    local used total
    read -r used total < <(mem_kb) || return 1
    [ -n "$total" ] || return 1
    if [ "$used" = "-" ]; then gib "$total"
    else printf '%s / %s\n' "$(gib "$used")" "$(gib "$total")"; fi
}

# XDG_CURRENT_DESKTOP is a colon-separated list on derivative desktops
# ("pop:GNOME"); the last entry is the real one. Both variables are absent
# under sudo and on a tty, which is exactly when this row should not print.
session_desc() {
    local de=${XDG_CURRENT_DESKTOP:-} ty=${XDG_SESSION_TYPE:-}
    de=${de##*:}
    if   [ -n "$de" ] && [ -n "$ty" ]; then printf '%s (%s)\n' "$de" "$ty"
    elif [ -n "$de" ];                 then printf '%s\n' "$de"
    elif [ -n "$ty" ];                 then printf '%s\n' "$ty"
    else return 1; fi
}

uptime_s() {
    local s
    read -r s _ < /proc/uptime 2>/dev/null || return 1
    s=${s%.*}
    [ -n "$s" ] || return 1
    printf '%s\n' "$s"
}

# Coarse on purpose: this answers "did you reboot after the update?", and
# seconds of precision would only make the row noisier. --json gets the
# integer instead, because a machine should not have to parse "2h 14m".
uptime_desc() {
    local s d h m
    s=$(uptime_s) || return 1
    d=$((s / 86400)); h=$(((s % 86400) / 3600)); m=$(((s % 3600) / 60))
    if   [ "$d" -gt 0 ]; then printf '%dd %dh\n' "$d" "$h"
    elif [ "$h" -gt 0 ]; then printf '%dh %dm\n' "$h" "$m"
    else                      printf '%dm\n' "$m"; fi
}

# key<TAB>value rows for whatever this machine will admit to.
host_rows() {
    local v c n
    if v=$(dmi_model); then printf 'host\t%s\n' "$v"; fi
    if c=$(cpu_name); then
        if n=$(cpu_threads); then c="$c ($n threads)"; fi
        printf 'cpu\t%s\n' "$c"
    fi
    while IFS= read -r v; do
        if [ -n "$v" ]; then printf 'gpu\t%s\n' "$v"; fi
    done < <(gpu_names || true)
    if v=$(mem_used_total); then printf 'memory\t%s\n' "$v"; fi
    if v=$(session_desc);   then printf 'session\t%s\n' "$v"; fi
    if v=$(uptime_desc);    then printf 'uptime\t%s\n' "$v"; fi
    return 0
}

# The same facts as data. Raw numbers, not the terminal's formatting, and
# absent fields OMITTED rather than null -- the rows drop, so the keys drop
# too, and a consumer can test presence instead of testing for null.
#
# Everything lands under one "host" key so `jq 'del(.host)'` gives back the
# baked manifest: two machines on the same build still compare equal, which
# was the whole reason this was not merged in at the top level.
host_json() {
    local model cpu threads gpus used total de ty up
    model=$(dmi_model)   || model=""
    cpu=$(cpu_name)      || cpu=""
    threads=$(cpu_threads) || threads=""
    gpus=$(gpu_names | jq -R -s 'split("\n") | map(select(length > 0))') || gpus="[]"
    read -r used total < <(mem_kb) || { used="-"; total=""; }
    [ "$used" = "-" ] && used=""
    de=${XDG_CURRENT_DESKTOP:-}; de=${de##*:}
    ty=${XDG_SESSION_TYPE:-}
    up=$(uptime_s) || up=""

    jq -n --arg model "$model" --arg cpu "$cpu" --arg de "$de" --arg ty "$ty" \
          --argjson gpu "$gpus" \
          --argjson threads "${threads:-null}" \
          --argjson used "${used:-null}" \
          --argjson total "${total:-null}" \
          --argjson up "${up:-null}" '
      def prune: with_entries(select(
          .value != null and .value != "" and .value != [] and .value != {}));
      {
        model:       $model,
        cpu:         $cpu,
        cpu_threads: $threads,
        gpu:         $gpu,
        memory:      ({ used_bytes:  (if $used  == null then null else $used  * 1024 end),
                        total_bytes: (if $total == null then null else $total * 1024 end)
                      } | prune),
        session:     ({ desktop: $de, type: $ty } | prune),
        uptime_s:    $up
      } | prune
    '
}

cmd_manifest() {
    [ -r "$MANIFEST" ] || die "no manifest at ${MANIFEST} (image predates it, or was built without one)"
    if [ "${JSON:-0}" = 1 ]; then
        # The baked document plus one key, so the JSON says what the rows say.
        # A machine that can tell us nothing about itself gets no host key at
        # all rather than an empty object to special-case.
        local hj; hj=$(host_json)
        if [ -z "$hj" ] || [ "$hj" = "{}" ]; then
            cat "$MANIFEST"
        else
            jq --argjson host "$hj" '. + { host: $host }' "$MANIFEST" \
                || die "manifest at ${MANIFEST} is not valid JSON"
        fi
        return 0
    fi
    # Rows leave jq as key<TAB>value, unpadded and uncolored: widths, color,
    # and wrapping are terminal concerns, and bash is the only side that
    # knows the terminal. (Escapes hardcoded in the jq program once meant
    # `pulsar manifest | cat` emitted raw control codes.)
    # Split in two so the machine rows can be spliced between them: what this
    # image IS, what it is running ON, then what is INSIDE it.
    #
    # Every row here is a FACT. There were once two that were not: `sbom` and
    # `attestation`, whose values were other commands to go and run. The
    # attestation one made the cost obvious -- the baked `gh attestation
    # verify ...` line is 82 characters, three times the next longest row, and
    # it dragged the readout's right edge out past the art to say something
    # `pulsar --help` already says. A manifest is an inventory, not a menu.
    # Both commands still exist (`pulsar sbom`, `pulsar attest`); they are
    # listed where commands are listed.
    local head rest tsv
    head=$(jq -r '
      [ ["image",   (.image // "?") + (if .variant then " (" + .variant + ")" else "" end)],
        (if .release then ["release", .release] else empty end),
        ["build",   (.version // "?")],
        ["base",    (.base // "?")],
        ["built",   (.built // "?")],
        ["kernel",  (.kernel // "?")]
      ] | .[] | .[0] + "\t" + .[1]
    ' "$MANIFEST") || die "manifest at ${MANIFEST} is not valid JSON"
    rest=$(jq -r '
      ((.components // {}) | to_entries | map([.key, (.value | tostring)]))
      | .[] | .[0] + "\t" + .[1]
    ' "$MANIFEST") || die "manifest at ${MANIFEST} is not valid JSON"

    tsv=$head
    local hr; hr=$(host_rows)
    if [ -n "$hr" ];   then tsv=$(printf '%s\n%s' "$tsv" "$hr"); fi
    if [ -n "$rest" ]; then tsv=$(printf '%s\n%s' "$tsv" "$rest"); fi

    # The key column is measured, never guessed. A fixed width of 11 already
    # ran "attestation" into its value once; components come from the
    # manifest, so the longest key is whatever the image happened to ship.
    local keyw=0 k v
    while IFS=$'\t' read -r k v; do
        [ "${#k}" -gt "$keyw" ] && keyw=${#k}
    done <<<"$tsv"

    # Fit against the REAL terminal, not a magic minimum. The art is drawn
    # only when it leaves the values a usable column, and values wrap inside
    # their column -- the terminal's own wrap restarts at column zero, which
    # shears the art and the table both (seen in the field at 72 columns:
    # every long value snapped its row in half). An explicit --logo skips the
    # fit check; asking twice means wanting it regardless. cols=0 (no tty,
    # tput failure) disables wrapping entirely -- pipes do not wrap.
    local cols=0 artw=0 avail=0
    [ -n "$C_RESET" ] && cols=$(tput cols 2>/dev/null || echo 0)
    if want_logo; then
        artw=$(logo_width)
        if [ "$cols" -gt 0 ] && [ "${LOGO:-auto}" != always ] && \
           [ $((cols - artw - 2 - keyw - 2)) -lt 24 ]; then
            artw=0    # art at the price of the information is the wrong trade
        fi
    fi
    if [ "$cols" -gt 0 ]; then
        avail=$((cols - keyw - 2))
        [ "$artw" -gt 0 ] && avail=$((avail - artw - 2))
        [ "$avail" -lt 16 ] && avail=0   # too narrow to wrap sensibly
    fi

    local rows
    rows=$(format_rows "$keyw" "$avail" <<<"$tsv")
    if [ "$artw" -gt 0 ]; then paste_logo "$rows"; else printf '%s\n' "$rows"; fi
    swatches
}

# key<TAB>value rows in, colored lines out: the key padded into its column,
# the value word-wrapped to $2 columns with continuations indented under the
# value column. avail=0 wraps nothing. A single word longer than the column
# (an oci:// reference) is left whole -- a word broken to fit is worse than
# one the terminal wraps.
format_rows() {
    local keyw=$1 avail=$2 k v line word i
    while IFS=$'\t' read -r k v; do
        local -a words=() parts=()
        if [ "$avail" -gt 0 ]; then
            read -ra words <<<"$v"
            line=""
            for word in "${words[@]}"; do
                if [ -z "$line" ]; then line=$word
                elif [ $(( ${#line} + 1 + ${#word} )) -le "$avail" ]; then line="$line $word"
                else parts+=("$line"); line=$word; fi
            done
            parts+=("$line")
        else
            parts=("$v")
        fi
        printf '%s%-*s%s%s\n' "$C_KEY" $((keyw + 2)) "$k" "$C_RESET" "${parts[0]}"
        for ((i = 1; i < ${#parts[@]}; i++)); do
            printf '%*s%s\n' $((keyw + 2)) '' "${parts[i]}"
        done
    done
}

# The mark as ASCII, rendered from assets/brand/svg/pulsar-mark-small.svg by
# scripts/render-ascii-logo.py and shipped at /usr/share/pulsar/logo.ansi.
# Generated so it cannot drift from the artwork -- see that script for why
# hand-drawing it failed.
#
# Every line carries exactly the same number of visible characters, so pasting
# a second column beside it needs no width arithmetic -- and because the ramp
# is 7-bit, one character is one byte and `${#s}` is honest in any locale.
LOGO_FILE=${PULSAR_LOGO:-${PULSAR_LOGO_DIR:-/usr/share/pulsar}/logo.ansi}

# fastfetch's shape: art on the left, readout on the right, and whichever
# column is shorter simply runs out. Suppressed when there is no terminal to
# draw on or no art to draw; whether the terminal is WIDE enough is decided
# in cmd_manifest, where the measured key column is known.
want_logo() {
    [ "${LOGO:-auto}" != "never" ] || return 1
    [ -r "$LOGO_FILE" ] || return 1
    [ "${LOGO:-auto}" = "always" ] || [ -n "$C_RESET" ]
}

# Measured from the art itself, with the escapes stripped: the file is
# generated, so hardcoding its width here would be a second source of truth
# that nothing keeps honest.
logo_width() {
    local first
    IFS= read -r first < "$LOGO_FILE" || true
    # ${#} rather than wc -c: paste_logo pads with ${#} too, and the two must
    # agree on what "width" means if a custom PULSAR_LOGO is ever not 7-bit
    first=$(printf '%s' "$first" | sed $'s/\033\[[0-9;]*m//g')
    printf '%s\n' "${#first}"
}

paste_logo() {
    local -a art=() info=()
    mapfile -t art < "$LOGO_FILE"
    mapfile -t info <<< "$1"
    # Measured from the art itself, with the escapes stripped: the file is
    # generated, so hardcoding its width here would be a second source of
    # truth that nothing keeps honest.
    local plain pad
    plain=$(printf '%s' "${art[0]:-}" | sed $'s/\033\[[0-9;]*m//g')
    printf -v pad '%*s' "${#plain}" ''
    local i n=${#art[@]} m=${#info[@]}
    [ "$m" -gt "$n" ] && n=$m
    for ((i = 0; i < n; i++)); do
        printf '%s  %s\n' "${art[i]-$pad}" "${info[i]-}"
    done
}

# The brand palette as terminal blocks, the way fastfetch closes its readout.
# This is the line that makes the one-pager's mock terminal a transcript rather
# than an illustration -- the page shows these swatches, so the real command
# has to as well. 24-bit colour, and only when we are on a terminal;
# `pulsar manifest --json` and piped output get nothing.
swatches() {
    [ -n "$C_RESET" ] || return 0
    local rgb
    printf '\n'
    for rgb in "11;14;26" "36;31;61" "62;203;255" "143;168;255" "75;63;212" "233;237;247"; do
        printf '\033[48;2;%sm   \033[0m' "$rgb"
    done
    printf '\n'
}
