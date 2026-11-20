# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): pulsar agent undo and diff: the snapshots taken at each start.

# ---------------------------------------------------------------------------
# agent undo -- put a project's files back the way they were when a session
# started. Rollback covers the OS; this covers what an agent did to your work.
#
# Each start of a session in a git repository records a snapshot of the
# working files, tracked and untracked alike, as a commit no branch points
# at: refs/pulsar/undo/<session>/<time>. Built on a copy of the real index,
# so only what changed is read again, and nothing of the user's index,
# branches or stash is touched. Not in it: files git ignores (build output,
# node_modules), and untracked files over UNDO_MAX_BYTES, named in the
# snapshot's message.
#
# The snapshot of the start that began the session (its first, or --new)
# is the one an undo goes back to; the session's record names it (base=).
# A restart (a reboot, Start in Settings, an attach to one that died) takes
# a snapshot too, for --to, but never moves it. The last UNDO_KEEP
# snapshots are kept, and the start's always.
#
# An undo restores files and deletes the ones added since; it never moves a
# branch. Commits made since stay, and are named. What the files were just
# before the undo is kept too (refs/pulsar/undone/<session>/...), so
# --redo takes the undo back. So an undo never overwrites or deletes a file
# that copy does not hold (one git ignores now, one grown over the limit),
# and never touches a path git ignores, by today's rules or by the
# snapshot's (an .env the agent took out of .gitignore): it leaves those as
# they are, and names them.
# ---------------------------------------------------------------------------
UNDO_KEEP=${PULSAR_UNDO_KEEP:-10}
UNDO_MAX_BYTES=${PULSAR_UNDO_MAX_BYTES:-52428800}

# undo_tree <top> <message> -> a commit of the working files, on stdout
undo_tree() {
    local top=$1 msg=$2 gd idx tmp tree head f size
    gd=$(git -C "$top" rev-parse --path-format=absolute --git-dir) || return 1
    idx=$(git -C "$top" rev-parse --path-format=absolute --git-path index) || return 1
    tmp=$(mktemp "${gd}/pulsar-undo-index.XXXXXX") || return 1
    if [ -f "$idx" ]; then cp "$idx" "$tmp"; else rm -f "$tmp"; fi
    local -a skip=() skipped=()
    while IFS= read -r -d '' f; do
        size=$(stat -c %s -- "${top}/${f}" 2>/dev/null) || continue
        [ "$size" -le "$UNDO_MAX_BYTES" ] && continue
        skip+=(":(exclude,literal)${f}"); skipped+=("$f")
    done < <(git -C "$top" ls-files -z --others --exclude-standard)
    [ ${#skipped[@]} -eq 0 ] || msg+=$'\n\n'"Not in it (untracked, over $((UNDO_MAX_BYTES / 1048576)) MB):"$'\n'"$(printf '%s\n' "${skipped[@]}")"
    if ! GIT_INDEX_FILE=$tmp git -C "$top" add -A -- . "${skip[@]}" >/dev/null 2>&1 \
        || ! tree=$(GIT_INDEX_FILE=$tmp git -C "$top" write-tree); then
        rm -f "$tmp"; return 1
    fi
    rm -f "$tmp"
    head=$(git -C "$top" rev-parse -q --verify HEAD) || head=""
    GIT_AUTHOR_NAME=Pulsar GIT_AUTHOR_EMAIL=pulsar@localhost GIT_COMMITTER_NAME=Pulsar GIT_COMMITTER_EMAIL=pulsar@localhost \
        git -C "$top" commit-tree "$tree" ${head:+-p "$head"} -m "$msg"
}

undo_top() { git -C "$1" rev-parse --show-toplevel 2>/dev/null; }

# undo_snapshot_start <session> <dir> <1 if this start begins the session>
#                     <the snapshot of its start, from the record>
# Sets UNDO_SNAP_TOP and UNDO_SNAP_REF (the snapshot it took, if it took
# one) and UNDO_SNAP_BASE (the start's, for the record).
undo_snapshot_start() {
    local s=$1 dir=$2 new=$3 base=$4 top c old ref n=0
    UNDO_SNAP_TOP=""; UNDO_SNAP_REF=""; UNDO_SNAP_BASE=$base
    [ "$new" = 0 ] || UNDO_SNAP_BASE=""
    top=$(undo_top "$dir") || {
        printf 'note: %s is not in a git repository, so pulsar agent undo has nothing to go back to\n' "${dir/#"$HOME"/\~}" >&2
        return 0; }
    if ! c=$(undo_tree "$top" "pulsar: ${s} $([ "$new" = 1 ] && echo started || echo restarted) $(date '+%Y-%m-%d %H:%M')"); then
        printf 'note: git could not snapshot %s; pulsar agent undo %s has nothing new to go back to\n' "$top" "$s" >&2
        return 0
    fi
    ref="refs/pulsar/undo/${s}/$(date +%s%N)"
    git -C "$top" update-ref "$ref" "$c" || return 0
    UNDO_SNAP_TOP=$top; UNDO_SNAP_REF=$ref
    if [ "$new" = 1 ]; then
        UNDO_SNAP_BASE=$ref
    elif [ -z "$base" ] || ! git -C "$top" show-ref --verify --quiet "$base"; then
        # a record from before the start's snapshot was named: the oldest
        # one is the nearest there is, and is kept from now on
        UNDO_SNAP_BASE=$(git -C "$top" for-each-ref --sort=refname --count=1 --format='%(refname)' "refs/pulsar/undo/${s}/")
    fi
    while IFS= read -r old; do
        n=$((n + 1))
        [ "$n" -le "$UNDO_KEEP" ] || [ "$old" = "$UNDO_SNAP_BASE" ] || git -C "$top" update-ref -d "$old"
    done < <(git -C "$top" for-each-ref --sort=-refname --format='%(refname)' "refs/pulsar/undo/${s}/")
}

# undo_ignored_then <top> <commit>, the paths on stdin (NUL-separated):
# those git ignored by <commit>'s rules, its own .gitignore files with
# info/exclude and core.excludesFile, on stdout (NUL-separated)
undo_ignored_then() {
    local top=$1 c=$2 gd tmp f mode rc=0 bad=0
    gd=$(git -C "$top" rev-parse --path-format=absolute --git-dir) || return 2
    tmp=$(mktemp -d) || return 2
    while IFS= read -r -d '' f; do
        mode=${f%% *}; f=${f#*$'\t'}
        case "$mode" in 100644|100755) ;; *) continue ;; esac
        case "/${f}" in */.gitignore) ;; *) continue ;; esac
        mkdir -p -- "${tmp}/$(dirname -- "$f")"
        git -C "$top" cat-file blob "${c}:${f}" > "${tmp}/${f}" || bad=1
    done < <(git -C "$top" ls-tree -r -z "$c")
    if [ "$bad" = 0 ]; then
        git -C "$tmp" --git-dir="$gd" --work-tree="$tmp" check-ignore --no-index -z --stdin || rc=$?
    else
        rc=2
    fi
    rm -rf -- "$tmp"
    [ "$rc" -le 1 ]
}

# undo_plan <top> <now> <to>: what making the files match <to> takes, in
# UNDO_RESTORE and UNDO_REMOVE, and what it must leave in UNDO_SKIP
# ("path<TAB>why"). <now> is the copy --redo puts back: a file it does not
# hold is never overwritten, and a path git ignores is never touched.
undo_plan() {
    local top=$1 now=$2 to=$3 meta p out rc=0
    UNDO_RESTORE=(); UNDO_REMOVE=(); UNDO_SKIP=()
    local -a added=() gone=()
    while IFS= read -r -d '' meta && IFS= read -r -d '' p; do
        # gitlinks (submodules) are their own repositories
        case "$meta" in :160000\ *|:*\ 160000\ *) continue ;; esac
        case "${meta##* }" in
            A) added+=("$p") ;;      # made since: deleted
            D) gone+=("$p") ;;       # not in <now>: written from <to>
            *) UNDO_RESTORE+=("$p") ;;
        esac
    done < <(git -C "$top" diff-tree -r -z --no-renames --raw "$to" "$now")
    # keyed "x<path>": a path of @ or * is no subscript bash takes
    local -A then_ign=() now_ign=()
    out=$(mktemp) || return 1
    if [ ${#added[@]} -gt 0 ]; then
        printf '%s\0' "${added[@]}" | undo_ignored_then "$top" "$to" > "$out" || { rm -f "$out"; return 1; }
        while IFS= read -r -d '' p; do then_ign["x${p}"]=1; done < "$out"
    fi
    if [ ${#gone[@]} -gt 0 ]; then
        printf '%s\0' "${gone[@]}" | git -C "$top" check-ignore -z --stdin > "$out" || rc=$?
        [ "$rc" -le 1 ] || { rm -f "$out"; return 1; }
        while IFS= read -r -d '' p; do now_ign["x${p}"]=1; done < "$out"
    fi
    rm -f "$out"
    for p in "${added[@]}"; do
        if [ -n "${then_ign["x${p}"]:-}" ]; then
            UNDO_SKIP+=("${p}"$'\t'"git ignored it then, and it is not the snapshot's to delete")
        else
            UNDO_REMOVE+=("$p")
        fi
    done
    for p in "${gone[@]}"; do
        if [ -n "${now_ign["x${p}"]:-}" ]; then
            UNDO_SKIP+=("${p}"$'\t'"git ignores it now")
        elif [ -e "${top}/${p}" ] || [ -L "${top}/${p}" ]; then
            if [ -f "${top}/${p}" ] && [ "$(stat -c %s -- "${top}/${p}")" -gt "$UNDO_MAX_BYTES" ]; then
                UNDO_SKIP+=("${p}"$'\t'"over $((UNDO_MAX_BYTES / 1048576)) MB now, too big to keep a copy of to take back")
            else
                UNDO_SKIP+=("${p}"$'\t'"no copy of it as it is now to take back")
            fi
        else
            UNDO_RESTORE+=("$p")
        fi
    done
}

# undo_apply <top> <to>: carry out undo_plan's UNDO_RESTORE and UNDO_REMOVE
undo_apply() {
    local top=$1 to=$2 p
    if [ ${#UNDO_RESTORE[@]} -gt 0 ]; then
        printf '%s\0' "${UNDO_RESTORE[@]}" | GIT_LITERAL_PATHSPECS=1 git -C "$top" restore --source="$to" --worktree \
            --pathspec-from-file=- --pathspec-file-nul || return 1
    fi
    for p in "${UNDO_REMOVE[@]}"; do
        rm -f -- "${top:?}/${p:?}"
        rmdir -p --ignore-fail-on-non-empty -- "$(dirname -- "${top}/${p}")" 2>/dev/null || true
    done
}

# the running session, other than $1, whose folder is in the checkout $2
undo_busy() {
    local s=$1 top=$2 n d t
    while IFS=$'\t' read -r n _; do
        [ -n "$n" ] && [ "$n" != "$s" ] || continue
        d=$(session_get "$n" dir) || continue
        [ -d "$d" ] && t=$(undo_top "$d") && [ "$t" = "$top" ] || continue
        printf '%s\n' "$n"
        return 0
    done < <(atmux list-sessions -F '#{session_name}' 2>/dev/null | grep -v '~' || true)
    return 1
}

undo_print_skips() {
    [ ${#UNDO_SKIP[@]} -gt 0 ] || return 0
    local e i=0
    printf '  leaves %d file(s) as they are:\n' ${#UNDO_SKIP[@]}
    for e in "${UNDO_SKIP[@]}"; do
        i=$((i + 1))
        [ "$i" -le 20 ] || { printf '    ... and %d more\n' $(( ${#UNDO_SKIP[@]} - 20 )); break; }
        printf '  ! %s  (%s)\n' "${e%%$'\t'*}" "${e#*$'\t'}"
    done
}

agent_undo() {
    local s="" list=0 to="" yes=0 redo=0 dry=0 file="" unc=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --list) list=1 ;;
            --to) [ $# -ge 2 ] || die "--to wants a number from --list"; to=$2; shift ;;
            --yes|-y) yes=1 ;;
            --redo) redo=1 ;;
            --dry-run) dry=1 ;;
            --file) [ $# -ge 2 ] || die "--file wants a path in the project"; file=$2; shift ;;
            --uncommitted) unc=1 ;;
            -h|--help) printf 'usage: pulsar agent undo <session> [--list | --to <n> | --redo | --file <path> [--uncommitted]] [--yes | --dry-run]\n'; return 0 ;;
            -*) die "unknown option: $1 (pulsar agent undo <session> [--list | --to <n> | --redo] [--yes | --dry-run])" ;;
            *) [ -z "$s" ] || die "one session at a time"; s=$1 ;;
        esac
        shift
    done
    case "$s" in ''|*[!A-Za-z0-9_-]*) die "usage: pulsar agent undo <session> [--list | --to <n> | --redo] [--yes | --dry-run]" ;; esac
    [ -z "$to" ] || case "$to" in *[!0-9]*|0) die "--to wants a number from --list" ;; esac
    [ "${JSON:-0}" = 0 ] || [ "$list" = 1 ] || die "'agent undo' has --json output only with --list"
    local dir top
    dir=$(session_get "$s" dir) || die "no session called ${s} (pulsar agent sessions)"
    [ -d "$dir" ] || die "${s} ran in ${dir}, which is gone"
    top=$(undo_top "$dir") || die "${dir} is not in a git repository; there is nothing to undo to"
    [ "$unc" = 0 ] || [ -n "$file" ] || die "--uncommitted goes with --file <path>"
    if [ -n "$file" ]; then
        [ "$list" = 0 ] && [ -z "$to" ] && [ "$redo" = 0 ] || die "--file goes alone (with --uncommitted, --yes or --dry-run)"
        agent_undo_file "$s" "$top" "$file" "$unc" "$yes" "$dry"
        return
    fi
    local ns="refs/pulsar/undo/${s}/"
    [ "$redo" = 0 ] || ns="refs/pulsar/undone/${s}/"
    local -a refs=()
    mapfile -t refs < <(git -C "$top" for-each-ref --sort=-refname --format='%(refname)' "$ns")
    if [ ${#refs[@]} -eq 0 ]; then
        [ "$redo" = 1 ] && die "there is no undo of ${s} to take back"
        die "no snapshot of ${s} yet: one is taken each time the session starts"
    fi
    # where an undo goes by default: the snapshot of the session's start
    local base="" at=0 i=0 r
    [ "$redo" = 1 ] || base=$(session_get "$s" base) || base=""
    for r in "${refs[@]}"; do
        i=$((i + 1))
        [ "$r" != "$base" ] || at=$i
    done
    if [ "$list" = 1 ] && [ "${JSON:-0}" = 1 ]; then
        need jq
        # newest first, numbered as --to takes them
        i=0
        for r in "${refs[@]}"; do
            i=$((i + 1))
            git -C "$top" log -1 --format='%ct%x09%s' "$r" | jq -cR --argjson n "$i" --argjson start "$([ "$i" = "$at" ] && echo true || echo false)" \
                'split("\t") | {n: $n, time: (.[0] | tonumber), subject: (.[1:] | join("\t")), start: $start}'
        done | jq -cs .
        return 0
    fi
    if [ "$list" = 1 ]; then
        i=0
        for r in "${refs[@]}"; do
            i=$((i + 1))
            printf '%3d  %s%s\n' "$i" "$(git -C "$top" log -1 --format='%cd  %s' --date='format:%Y-%m-%d %H:%M' "$r")" \
                "$([ "$i" = "$at" ] && echo '  <- the session'"'"'s start, where undo goes')"
        done
        return 0
    fi
    if [ -z "$to" ]; then
        if [ "$redo" = 1 ]; then
            to=1
        elif [ "$at" -gt 0 ]; then
            to=$at
        else
            to=${#refs[@]}
            printf 'note: the snapshot of when %s started is not kept; this goes back to the oldest one there is\n' "$s" >&2
        fi
    fi
    [ "$to" -le ${#refs[@]} ] || die "there are ${#refs[@]} snapshots of ${s} (pulsar agent undo ${s} --list)"
    if have tmux; then
        if atmux_running "$s"; then
            die "${s} is running, and its agent could write again mid-undo; end it first (pulsar agent sessions --kill ${s})"
        fi
        local other
        if other=$(undo_busy "$s" "$top"); then
            die "${other} is running in this checkout (${top/#"$HOME"/\~}), and its agent could write here mid-undo; end it first (pulsar agent sessions --kill ${other})"
        fi
    fi
    local target now when
    target=$(git -C "$top" rev-parse "${refs[$((to - 1))]}")
    now=$(undo_tree "$top" "pulsar: ${s} before an undo $(date '+%Y-%m-%d %H:%M')") || die "git could not read the files as they are now"
    undo_plan "$top" "$now" "$target" || die "git could not tell which files it ignores; nothing changed"
    when=$(git -C "$top" log -1 --format=%cr "$target")
    local nr=${#UNDO_RESTORE[@]} nd=${#UNDO_REMOVE[@]}
    if [ $((nr + nd)) -eq 0 ]; then
        if [ ${#UNDO_SKIP[@]} -eq 0 ]; then
            printf 'nothing to do: the files are as they were %s\n' "$when"
        else
            printf 'nothing to do: what changed since %s is all left as it is\n' "$when"
            undo_print_skips
        fi
        return 0
    fi
    printf '%s, as of %s (%s):\n' "$([ "$redo" = 1 ] && echo 'Takes back the undo' || echo "Puts ${top/#"$HOME"/\~} back")" \
        "$(git -C "$top" log -1 --format='%cd' --date='format:%Y-%m-%d %H:%M' "$target")" "$when"
    [ "$nr" -eq 0 ] || printf '  restores %d file(s)\n' "$nr"
    [ "$nd" -eq 0 ] || printf '  deletes %d file(s) made since\n' "$nd"
    local p n=0
    for p in "${UNDO_RESTORE[@]}" "${UNDO_REMOVE[@]}"; do
        n=$((n + 1))
        [ "$n" -le 20 ] || { printf '  ... and %d more\n' $(( nr + nd - 20 )); break; }
        if [ "$n" -le "$nr" ]; then printf '  ~ %s\n' "$p"; else printf '  - %s\n' "$p"; fi
    done
    local parent head
    parent=$(git -C "$top" rev-parse -q --verify "${target}^") || parent=""
    head=$(git -C "$top" rev-parse -q --verify HEAD) || head=""
    if [ -n "$parent" ] && [ -n "$head" ] && [ "$parent" != "$head" ] && git -C "$top" merge-base --is-ancestor "$parent" "$head"; then
        printf '  commits made since stay on the branch (%d; git log %s..HEAD)\n' \
            "$(git -C "$top" rev-list --count "${parent}..${head}")" "$(git -C "$top" rev-parse --short "$parent")"
    fi
    undo_print_skips
    printf '  files git ignores are left as they are\n'
    [ "$dry" = 0 ] || return 0
    if [ "$yes" = 0 ]; then
        [ -t 0 ] || die "add --yes to do it without a terminal to ask on"
        local ans; read -r -p "Go ahead? [y/N] " ans
        case "$ans" in y|Y|yes) ;; *) printf 'nothing changed\n'; return 0 ;; esac
    fi
    [ "$redo" = 1 ] || git -C "$top" update-ref "refs/pulsar/undone/${s}/$(date +%s%N)" "$now"
    undo_apply "$top" "$target" || die "git could not restore every file; the state before this is ${now}"
    if [ "$redo" = 1 ]; then
        git -C "$top" update-ref -d "${refs[$((to - 1))]}"
        printf 'done: the undo is taken back\n'
    else
        printf 'done. pulsar agent undo %s --redo takes it back\n' "$s"
    fi
}

# agent diff -- what changed in a session's checkout since the session
# started: the snapshot undo goes back to, against the files as they are now
# (untracked ones too, as the snapshot holds them). Works while it runs.
# --uncommitted: against the last commit instead. --files --json: one row
# per file, for the Agents app's list. -- <path>: that file alone.

# agent_diff_base <session> <top> <1: the last commit> -> what to compare with
agent_diff_base() {
    local s=$1 top=$2 unc=$3 base
    if [ "$unc" = 1 ]; then
        # no commit yet: everything is new
        git -C "$top" rev-parse -q --verify 'HEAD^{commit}' || git -C "$top" hash-object -t tree /dev/null
        return 0
    fi
    base=$(session_get "$s" base) || base=""
    if [ -z "$base" ] || ! git -C "$top" show-ref --verify --quiet "$base"; then
        base=$(git -C "$top" for-each-ref --sort=refname --count=1 --format='%(refname)' "refs/pulsar/undo/${s}/")
    fi
    [ -n "$base" ] || die "no snapshot of ${s} yet: one is taken each time the session starts"
    printf '%s\n' "$base"
}

agent_diff() {
    local usage="usage: pulsar agent diff <session> [--uncommitted] [--stat | --files --json] [-- <path>]"
    local s="" stat=0 byfile=0 unc=0
    local -a paths=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --stat) stat=1 ;;
            --files) byfile=1 ;;
            --uncommitted) unc=1 ;;
            --) shift; [ $# -eq 1 ] || die "one path after --"; paths=("$1"); shift; continue ;;
            -h|--help) printf '%s\n' "$usage"; return 0 ;;
            -*) die "unknown option: $1 ($usage)" ;;
            *) [ -z "$s" ] || die "one session at a time"; s=$1 ;;
        esac
        shift
    done
    case "$s" in ''|*[!A-Za-z0-9_-]*) die "$usage" ;; esac
    [ "$byfile" = 1 ] || [ "${JSON:-0}" = 0 ] || die "'agent diff' has --json output only with --files"
    [ "$byfile" = 0 ] || [ "${JSON:-0}" = 1 ] || die "--files is for the Agents app; add --json"
    local dir top base now
    dir=$(session_get "$s" dir) || die "no session called ${s} (pulsar agent sessions)"
    [ -d "$dir" ] || die "${s} ran in ${dir}, which is gone"
    top=$(undo_top "$dir") || die "${dir} is not in a git repository; there is nothing to compare with"
    base=$(agent_diff_base "$s" "$top" "$unc") || exit 1
    now=$(undo_tree "$top" "pulsar: ${s} for a diff $(date '+%Y-%m-%d %H:%M')") || die "git could not read the files as they are now"
    [ ${#paths[@]} -eq 0 ] || paths=(-- "${paths[@]}")
    if [ "$byfile" = 1 ]; then
        need jq
        local code p old line a r
        local -A st=()
        while IFS= read -r -d '' code; do
            case "$code" in
                R*|C*) IFS= read -r -d '' old; IFS= read -r -d '' p; st["x${p}"]=renamed ;;
                A) IFS= read -r -d '' p; st["x${p}"]=added ;;
                D) IFS= read -r -d '' p; st["x${p}"]=deleted ;;
                *) IFS= read -r -d '' p; st["x${p}"]=modified ;;
            esac
        done < <(git -C "$top" diff -M --name-status -z "$base" "$now" "${paths[@]}")
        while IFS= read -r -d '' line; do
            a=${line%%$'\t'*}; line=${line#*$'\t'}; r=${line%%$'\t'*}; p=${line#*$'\t'}
            # a rename: the old and new paths follow on their own
            [ -n "$p" ] || { IFS= read -r -d '' old; IFS= read -r -d '' p; }
            jq -nc --arg p "$p" --arg s "${st["x${p}"]:-modified}" --arg a "$a" --arg r "$r" \
                'def n: if . == "-" then null else tonumber end;
                 {path: $p, status: $s, added: ($a | n), removed: ($r | n)}'
        done < <(git -C "$top" diff -M --numstat -z "$base" "$now" "${paths[@]}") | jq -cs .
    elif [ "$stat" = 1 ]; then
        git -C "$top" diff --no-color --stat "$base" "$now" "${paths[@]}"
    else
        git -C "$top" diff --no-color "$base" "$now" "${paths[@]}"
    fi
}

# agent undo <session> --file <path> [--uncommitted]: one file back as it
# was when the session started (or at the last commit), deleted if it was
# not there. Works while the session runs: one file is put back whole, and
# what the files were is kept, so --redo takes it back as it does an undo.
agent_undo_file() {
    local s=$1 top=$2 p=$3 unc=$4 yes=$5 dry=$6 target now what
    case "/${p}/" in //*|*/../*|*/./*) die "--file wants a path inside the project, as agent diff names it" ;; esac
    target=$(agent_diff_base "$s" "$top" "$unc") || exit 1
    if git -C "$top" check-ignore -q --no-index -- "$p"; then
        die "git ignores ${p}; undo leaves files git ignores as they are"
    fi
    now=$(undo_tree "$top" "pulsar: ${s} before an undo of ${p} $(date '+%Y-%m-%d %H:%M')") || die "git could not read the files as they are now"
    local had=0 has=0
    git -C "$top" cat-file -e "${target}:${p}" 2>/dev/null && had=1
    git -C "$top" cat-file -e "${now}:${p}" 2>/dev/null && has=1
    if [ "$had" = 0 ] && [ "$has" = 0 ]; then
        printf 'nothing to do: %s was not there then and is not now\n' "$p"; return 0
    fi
    if [ "$had" = 1 ] && [ "$has" = 1 ] \
        && [ "$(git -C "$top" rev-parse "${target}:${p}")" = "$(git -C "$top" rev-parse "${now}:${p}")" ]; then
        printf 'nothing to do: %s is as it was\n' "$p"; return 0
    fi
    if [ "$had" = 1 ]; then what="puts back ${p} as it was"; else what="deletes ${p}, made since"; fi
    printf '%s %s\n' "${what^}" "$([ "$unc" = 1 ] && echo 'at the last commit' || echo 'when the session started')"
    [ "$dry" = 0 ] || return 0
    if [ "$yes" = 0 ]; then
        [ -t 0 ] || die "add --yes to do it without a terminal to ask on"
        local ans; read -r -p "Go ahead? [y/N] " ans
        case "$ans" in y|Y|yes) ;; *) printf 'nothing changed\n'; return 0 ;; esac
    fi
    git -C "$top" update-ref "refs/pulsar/undone/${s}/$(date +%s%N)" "$now"
    if [ "$had" = 1 ]; then
        GIT_LITERAL_PATHSPECS=1 git -C "$top" restore --source="$target" --worktree -- "$p" \
            || die "git could not restore ${p}; the state before this is ${now}"
    else
        rm -f -- "${top:?}/${p:?}"
        rmdir -p --ignore-fail-on-non-empty -- "$(dirname -- "${top}/${p}")" 2>/dev/null || true
    fi
    printf 'done. pulsar agent undo %s --redo takes it back\n' "$s"
}
