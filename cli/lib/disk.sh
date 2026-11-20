# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): pulsar agent disk: what agents leave behind on /var.

# agent disk -- what's taking the disk agents write to: free space on /var,
# the room suspend needs, and the big things in /var/tmp, ~/.cache and the
# sessions' scratch folders, which is where an agent's leftovers end up.
#   pulsar agent disk [--json]
#   pulsar agent disk --delete <path>   one of those, and nothing else
DISK_MIN=${PULSAR_DISK_MIN:-1000000000}
disk_roots() {
    printf 'tmp\t%s\n' "${PULSAR_DISK_TMP:-/var/tmp}"
    printf 'cache\t%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}"
}

# Whether a path is one agent disk lists, so may delete: an entry right in a
# root, or a session's scratch folder. Never a root itself, never through a
# symlink, never the scratch root.
disk_deletable() {
    local p=$1 kind root real
    # exactly as written, resolved: no symlink, no .., nothing relative, exists
    real=$(realpath -e -- "$p") || return 1
    [ "$real" = "$p" ] || return 1
    case "$p" in
        "${AGENT_SCRATCH}"|"${AGENT_SCRATCH}"/*/*) return 1 ;;
        "${AGENT_SCRATCH}"/*) return 0 ;;
    esac
    while IFS=$'\t' read -r kind root; do
        [ "$(dirname "$p")" != "$root" ] || return 0
    done < <(disk_roots)
    return 1
}

agent_disk() {
    local usage="usage: pulsar agent disk [--json] | --delete <path>"
    case "${1:-}" in
        -h|--help) printf '%s\n' "$usage"; return 0 ;;
        --delete)
            [ $# -eq 2 ] || die "$usage"
            disk_deletable "$2" || die "not one of the things agent disk lists: $2"
            local b; b=$(du -sb -- "$2" 2>/dev/null | cut -f1) || b=0
            rm -rf -- "$2"
            [ ! -e "$2" ] || die "could not delete all of $2"
            printf 'deleted %s (%s)\n' "$2" "$(human_bytes "${b:-0}")"
            return 0 ;;
        "") ;;
        *) die "$usage" ;;
    esac
    need jq
    local free need="" spath="" items kind root e
    free=$(free_bytes "${PULSAR_DISK_TMP:-/var/tmp}")
    IFS=$'\t' read -r need spath < <(suspend_need) || true
    # sizes at idle priority: ~/.cache can be tens of GB of small files
    items=$( {
        if [ -d "$AGENT_SCRATCH" ]; then
            for e in "$AGENT_SCRATCH"/*; do
                [ -d "$e" ] && [ ! -L "$e" ] || continue
                printf 'session\t%s\n' "$e"
            done
        fi
        while IFS=$'\t' read -r kind root; do
            [ -d "$root" ] || continue
            for e in "$root"/* "$root"/.[!.]*; do
                [ -e "$e" ] && [ ! -L "$e" ] && [ "$e" != "$AGENT_SCRATCH" ] || continue
                printf '%s\t%s\n' "$kind" "$e"
            done
        done < <(disk_roots); } | while IFS=$'\t' read -r kind e; do
            b=$(nice -n 19 ionice -c3 du -sb -- "$e" 2>/dev/null | cut -f1) || continue
            [ -n "$b" ] || continue
            # a session's folder is listed whatever its size: it's named
            [ "$kind" = session ] || [ "$b" -ge "$DISK_MIN" ] || continue
            jq -n -c --arg k "$kind" --arg p "$e" --argjson b "$b" --argjson t "$(stat -c %Y -- "$e")" \
                '{kind: $k, path: $p, bytes: $b, modified: $t}
                 + (if $k == "session" then {session: ($p | split("/") | last)} else {} end)'
        done | jq -s -c 'sort_by(-.bytes)')
    if [ "${JSON:-0}" = 1 ]; then
        jq -n -c --argjson f "${free:-null}" --arg n "$need" --arg sp "$spath" --argjson i "$items" \
            '{free: $f, suspend_need: (if $n == "" then null else ($n | tonumber) end),
              suspend_path: (if $sp == "" then null else $sp end), items: $i}'
        return 0
    fi
    printf '%s free' "$(human_bytes "${free:-0}")"
    [ -z "$need" ] || printf '; suspend needs %s in %s' "$(human_bytes "$need")" "$spath"
    printf '\n'
    jq -r '.[] | [.bytes, .path] | @tsv' <<<"$items" | while IFS=$'\t' read -r b e; do
        printf '%8s  %s\n' "$(human_bytes "$b")" "${e/#"$HOME"/\~}"
    done
}
