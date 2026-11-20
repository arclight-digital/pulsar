# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): pulsar checkpoint: /etc and dotfiles, snapshotted and put back.

# ---------------------------------------------------------------------------
# checkpoint -- "undo what just happened to the system" as one command.
#
# The image half of that is already true: every system change is a new
# deployment, and the old one is a reboot away. What is NOT covered is /etc.
# It is writable, per-deployment, and merged forward into each new deployment,
# so an edit there follows you through updates, and rollback is no way to take
# one back -- it trades ALL /etc changes since for the old deployment's copy.
# ostree's own config-diff answers "how does /etc differ from the image", not
# "what changed since this morning", and the second is the question after an
# agent (or a person) has been at it.
#
# A checkpoint is three things, all under /var/lib/pulsar/checkpoints (root
# only, 0700 -- /etc holds shadow and private keys):
#
#   etc.tar        /etc as it was, with owners, modes, ACLs and SELinux labels
#   etc.manifest   type, mode, owner and sha256 per path, to diff against later
#   meta.json      the booted deployment, and whether this checkpoint pinned it
#
# plus a pin on the booted deployment, so the OS half cannot be garbage
# collected out from under the checkpoint.
#
# restore puts back files that were changed or deleted since, and discards a
# STAGED deployment that is not the checkpoint's. It deliberately does not
# delete files added since (it lists them: one of them may be the thing you
# wanted), and does not reboot.
#
# The home half. Rollback never covered $HOME, and an agent's changes land
# there as often as in /etc: a shell rc, a git or ssh config, a GNOME setting
# (dconf lives in ~/.config), a script in ~/.local/bin. So a checkpoint also
# keeps the SETTINGS of the user who ran sudo -- the top-level dotfiles,
# ~/.config without its caches, ~/.local/bin and ~/.ssh -- as home.tar and
# home.manifest, and diff and restore treat them the way they treat /etc.
# Documents, projects and ~/.local/share are not settings and are left out:
# they are what git and backups are for, and they would make every checkpoint
# gigabytes.
#
# Every read and write of the home half runs AS THAT USER, never as root. A
# home folder is the agent's to write; one that planted a symlink there would
# otherwise have root follow it, archiving a file it could not read or
# restoring over one it could not write. As the user, a symlink reaches only
# what the user could reach anyway.
# ---------------------------------------------------------------------------
CHECKPOINTS=${PULSAR_CHECKPOINTS:-/var/lib/pulsar/checkpoints}
ETC_ROOT=${PULSAR_ETC:-/etc}
# A snapshot over this is skipped with a note rather than filling the disk:
# settings are megabytes, and a gigabyte of them is an app keeping a cache
# where it should not.
HOME_MAX=${PULSAR_CHECKPOINT_HOME_MAX:-536870912}
TAR_META=(--numeric-owner --xattrs --xattrs-include='*' --acls --selinux)

# path <TAB> type <TAB> mode <TAB> uid:gid <TAB> sha256 or link target.
# mtime is left out on purpose: a file touched but unchanged is not a change.
etc_manifest() {
    local sums
    sums=$(mktemp)
    ( cd "$ETC_ROOT" && find . -xdev -type f -print0 | sort -z \
        | xargs -0 -r sha256sum 2>/dev/null ) > "$sums" || true
    ( cd "$ETC_ROOT" && find . -xdev -printf '%p\t%y\t%m\t%U:%G\t%l\n' 2>/dev/null ) \
        | awk -F'\t' -v OFS='\t' -v sums="$sums" '
            BEGIN { while ((getline l < sums) > 0) { h = substr(l, 1, 64); p = substr(l, 67); s[p] = h } }
            { print $1, $2, $3, $4, ($2 == "f" ? s[$1] : $5) }' \
        | sort
    rm -f "$sums"
}

# changed|added|removed <TAB> path, between two manifests.
manifest_diff() {
    awk -F'\t' -v OFS='\t' '
        NR == FNR { old[$1] = $0; next }
        { seen[$1] = 1
          if (!($1 in old)) print "added", $1
          else if (old[$1] != $0) print "changed", $1 }
        END { for (p in old) if (!(p in seen)) print "removed", p }' "$1" "$2" | sort -k2
}

# changed|added|removed <TAB> path, comparing a saved manifest with /etc now.
etc_changes() {
    local now
    now=$(mktemp)
    etc_manifest > "$now"
    manifest_diff "$1" "$now"
    rm -f "$now"
}

# ---- the home half ---------------------------------------------------------

# The user whose settings a checkpoint keeps: whoever ran sudo (or pkexec).
# Empty when there is none -- root logged in as itself has no one to protect.
home_user() {
    if [ -n "${PULSAR_CHECKPOINT_USER:-}" ]; then printf '%s\n' "$PULSAR_CHECKPOINT_USER"; return; fi
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then printf '%s\n' "$SUDO_USER"; return; fi
    if [ -n "${PKEXEC_UID:-}" ] && [ "$PKEXEC_UID" != 0 ]; then id -nu "$PKEXEC_UID" 2>/dev/null; return; fi
}

home_dir_of() {
    [ -n "${PULSAR_CHECKPOINT_HOME:-}" ] && { printf '%s\n' "$PULSAR_CHECKPOINT_HOME"; return; }
    getent passwd "$1" 2>/dev/null | cut -d: -f6
}

# Runs a command as the home's owner. When that is who we already are (the
# tests, in a user namespace where the tmpdir maps to root), runs it directly.
as_owner() {
    local home=$1 user=$2; shift 2
    if [ "$(stat -c %u "$home")" = "$(id -u)" ]; then "$@"
    else runuser -u "$user" -- "$@"; fi
}

# What counts as settings, NUL-separated and relative to the home: the
# top-level dotfiles, and ~/.config (less anything that is a cache),
# ~/.local/bin and ~/.ssh. Directories are listed too, so their modes come
# back; sockets and pipes are not files to keep.
# shellcheck disable=SC2016  # a script for the user's own sh, expanded there
HOME_LIST='cd "$1" || exit 1
find . -mindepth 1 -maxdepth 1 -name ".?*" \( -type f -o -type l \) -print0
for d in .config .local/bin .ssh; do
    [ -d "$d" ] || continue
    find "./$d" -xdev \( -type d \( -iname "*cache*" -o -name GPUCache -o -name CachedData \
            -o -name "Service Worker" -o -name Crashpad -o -name "blob_storage" \) -prune \) \
        -o \( ! -type s ! -type p -print0 \)
done'

# The same line format as etc_manifest, for the paths in the NUL list on stdin.
# shellcheck disable=SC2016  # a script for the user's own sh, expanded there
HOME_MANIFEST='cd "$1" || exit 1
list=$(mktemp); cat > "$list"
sums=$(mktemp)
tr "\0" "\n" < "$list" | while IFS= read -r p; do [ -f "$p" ] && [ ! -L "$p" ] && printf "%s\0" "$p"; done \
    | xargs -0 -r sha256sum 2>/dev/null > "$sums" || true
[ -s "$list" ] && find -files0-from "$list" -maxdepth 0 -printf "%p\t%y\t%m\t%U:%G\t%l\n" 2>/dev/null \
    | awk -F"\t" -v OFS="\t" -v sums="$sums" '"'"'
        BEGIN { while ((getline l < sums) > 0) { h = substr(l, 1, 64); p = substr(l, 67); s[p] = h } }
        { print $1, $2, $3, $4, ($2 == "f" ? s[$1] : $5) }'"'"' | sort
rm -f "$list" "$sums"'

# home_manifest HOME USER -> the manifest on stdout, measured as the user.
home_manifest() {
    as_owner "$1" "$2" bash -c "$HOME_LIST" _ "$1" \
        | as_owner "$1" "$2" bash -c "$HOME_MANIFEST" _ "$1"
}

# A scratch directory the home's owner can READ: the lists handed to its tar.
# Owned by root, never by the user: root writes and chmods files in it, and in
# a directory the user owned, something running as the user (an agent, say)
# could plant list -> /etc/shadow between mktemp and the write, and root
# would truncate and chmod the target. The user's tar only reads the list.
owner_tmp() {
    local t; t=$(mktemp -d)
    chmod 0755 "$t"
    printf '%s\n' "$t"
}

# The saved home's owner and path, from meta.json; empty for a checkpoint
# that has no home half (taken with no user, or before it existed).
checkpoint_home() {
    [ -r "${1}/home.tar" ] || return 0
    jq -r '.home // empty | "\(.user)\t\(.path)"' "${1}/meta.json" 2>/dev/null
}

# changed|added|removed <TAB> ./path in the home, since checkpoint $1.
home_changes() {
    local now; now=$(mktemp)
    home_manifest "$2" "$3" > "$now"
    manifest_diff "${1}/home.manifest" "$now"
    rm -f "$now"
}

checkpoint_dir() {
    local id=${1:-}
    if [ -z "$id" ]; then
        id=$(find "$CHECKPOINTS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -1)
        [ -n "$id" ] || die "no checkpoints yet (create one: sudo pulsar checkpoint)"
    fi
    case "$id" in */*|.*) die "not a checkpoint id: ${id}" ;; esac
    [ -r "${CHECKPOINTS}/${id}/meta.json" ] || die "no checkpoint ${id} (see: sudo pulsar checkpoint list)"
    printf '%s\n' "${CHECKPOINTS}/${id}"
}

# The index `ostree admin pin` wants for the deployment with checksum $2, in
# the order rpm-ostree reports -- the same order ostree numbers them in, staged
# first. NOT a hardcoded 0: with an update staged, 0 is the staged deployment.
deployment_index() {
    printf '%s' "$1" | jq -r --arg c "$2" \
        '[.deployments[]?.checksum] | index($c) // empty' 2>/dev/null
}

checkpoint_create() {
    local note=${1:-}
    [ $# -le 1 ] || die "usage: sudo pulsar checkpoint [--no-home] [note]"
    local js='{}' checksum="" version="" pinned=false idx=""
    if have rpm-ostree; then js=$(rpm-ostree status --json 2>/dev/null) || js='{}'; fi
    checksum=$(printf '%s' "$js" | jq -r '[.deployments[]? | select(.booted == true)][0].checksum // ""' 2>/dev/null) || checksum=""
    version=$(printf '%s' "$js" | jq -r '[.deployments[]? | select(.booted == true)][0].version // ""' 2>/dev/null) || version=""
    local already
    already=$(printf '%s' "$js" | jq -r '[.deployments[]? | select(.booted == true)][0].pinned // false' 2>/dev/null) || already=false

    local id dir
    id=$(date -u +%Y%m%dT%H%M%SZ)
    dir="${CHECKPOINTS}/${id}"
    [ ! -e "$dir" ] || die "checkpoint ${id} already exists; wait a second and retry"
    ( umask 077; mkdir -p "$dir" ) || die "could not create ${dir}"
    chmod 0700 "$CHECKPOINTS" "$dir" 2>/dev/null || true

    # tar exits 1 for "file changed as we read it", which on a live /etc is
    # expected and harmless; 2 is a real failure.
    local rc=0
    ( umask 077; tar --create --file "${dir}/etc.tar" "${TAR_META[@]}" -C "$ETC_ROOT" . ) 2>/dev/null || rc=$?
    [ "$rc" -le 1 ] || { rm -rf "$dir"; die "could not archive ${ETC_ROOT} (tar exit ${rc})"; }
    ( umask 077; etc_manifest > "${dir}/etc.manifest" )
    if have ostree; then
        ( umask 077; ostree admin config-diff > "${dir}/config-diff.txt" 2>/dev/null ) || true
    fi

    # The home half: read as its owner, written into this root-only directory.
    local huser hdir hjson=null hnote=""
    huser=$(home_user)
    if [ "${PULSAR_CHECKPOINT_NO_HOME:-0}" = 1 ]; then hnote="skipped (--no-home)"
    elif [ -z "$huser" ]; then hnote="skipped: no user ran sudo, so there is no home to keep"
    else
        hdir=$(home_dir_of "$huser")
        if [ -z "$hdir" ] || [ ! -d "$hdir" ]; then hnote="skipped: no home folder for ${huser}"
        else
            local t; t=$(owner_tmp "$hdir" "$huser")
            as_owner "$hdir" "$huser" bash -c "$HOME_LIST" _ "$hdir" > "${t}/list" 2>/dev/null || true
            chmod 0644 "${t}/list" 2>/dev/null || true
            rc=0
            # -C before the list: tar applies it only to the names after it
            ( umask 077; as_owner "$hdir" "$huser" tar --create --file - -C "$hdir" --no-recursion \
                --null --files-from "${t}/list" > "${dir}/home.tar" ) 2>/dev/null || rc=$?
            local size; size=$(stat -c %s "${dir}/home.tar" 2>/dev/null || echo 0)
            if [ "$rc" -gt 1 ]; then
                rm -f "${dir}/home.tar"; hnote="skipped: could not archive ${hdir} (tar exit ${rc})"
            elif [ "$size" -gt "$HOME_MAX" ]; then
                rm -f "${dir}/home.tar"
                hnote="skipped: ${huser}'s settings came to $((size / 1048576)) MB, over the $((HOME_MAX / 1048576)) MB limit (PULSAR_CHECKPOINT_HOME_MAX)"
            else
                ( umask 077; as_owner "$hdir" "$huser" bash -c "$HOME_MANIFEST" _ "$hdir" \
                    < "${t}/list" > "${dir}/home.manifest" )
                hjson=$(jq -n --arg u "$huser" --arg p "$hdir" '{user: $u, path: $p}')
            fi
            rm -rf "$t"
        fi
    fi

    if [ -n "$checksum" ] && [ "$already" != true ] && have ostree; then
        idx=$(deployment_index "$js" "$checksum")
        if [ -n "$idx" ] && ostree admin pin "$idx" >/dev/null 2>&1; then pinned=true; fi
    fi

    ( umask 077; jq -n --arg id "$id" --arg note "$note" --arg c "$checksum" --arg v "$version" \
        --argjson p "$pinned" --argjson home "$hjson" \
        '{id: $id, created: (now | floor | todate), note: $note,
          deployment: {checksum: $c, version: $v}, pinned_by_checkpoint: $p, home: $home}' > "${dir}/meta.json" )

    local n; n=$(wc -l < "${dir}/etc.manifest")
    printf 'checkpoint %s\n' "$id"
    printf '  /etc      %s paths saved\n' "$n"
    if [ "$hjson" != null ]; then
        printf '  home      %s paths saved from %s (dotfiles, ~/.config, ~/.local/bin, ~/.ssh)\n' \
            "$(wc -l < "${dir}/home.manifest")" "$hdir"
    else
        printf '  home      %s\n' "$hnote"
    fi
    if [ -n "$checksum" ]; then
        if [ "$pinned" = true ]; then printf '  deployment %s pinned\n' "${version:-?}"
        elif [ "$already" = true ]; then printf '  deployment %s was already pinned\n' "${version:-?}"
        else printf '  deployment %s not pinned (ostree refused); it can be deleted when old deployments are cleaned up\n' "${version:-?}"; fi
    fi
    printf 'see what changed: sudo pulsar checkpoint diff %s\n' "$id"
    printf 'undo it:          sudo pulsar checkpoint restore %s\n' "$id"
}

checkpoint_list() {
    if [ "${JSON:-0}" = 1 ]; then
        local -a metas=()
        [ -d "$CHECKPOINTS" ] && mapfile -t metas < <(find "$CHECKPOINTS" -mindepth 2 -maxdepth 2 -name meta.json | sort)
        if [ ${#metas[@]} -eq 0 ]; then printf '[]\n'; else jq -s -c '.' "${metas[@]}"; fi
        return 0
    fi
    [ -d "$CHECKPOINTS" ] || { printf 'no checkpoints\n'; return 0; }
    local m any=0
    for m in "$CHECKPOINTS"/*/meta.json; do
        [ -r "$m" ] || continue
        any=1
        jq -r '"\(.id)  \(.deployment.version // "?")  \(if .pinned_by_checkpoint then "pinned" else "-" end)  \(.note)"' "$m"
    done
    [ "$any" = 1 ] || printf 'no checkpoints\n'
}

# What happened to the OS since the checkpoint, in one line or none.
checkpoint_deployment_state() {
    local dir=$1 want js
    want=$(jq -r '.deployment.checksum // ""' "${dir}/meta.json")
    [ -n "$want" ] && have rpm-ostree || return 0
    js=$(rpm-ostree status --json 2>/dev/null) || return 0
    printf '%s' "$js" | jq -r --arg c "$want" '
      ([.deployments[]? | select(.booted == true)][0].checksum // "") as $b
      | ([.deployments[]? | select(.staged == true)][0] // null) as $s
      | (if $s != null and $s.checksum != $c then
           "staged\ta new deployment (\($s.version // "?")) is staged since the checkpoint" else empty end),
        (if $b != $c then
           (if any(.deployments[]?; .checksum == $c) then
              "booted\tthe booted deployment is not the checkpoint'"'"'s; that one is still present"
            else "gone\tthe checkpoint'"'"'s deployment is no longer on disk" end)
         else empty end)'
}

checkpoint_diff() {
    local dir; dir=$(checkpoint_dir "${1:-}")
    local changes; changes=$(etc_changes "${dir}/etc.manifest")
    if [ -z "$changes" ]; then printf '/etc: unchanged since %s\n' "${dir##*/}"
    else printf '/etc since %s:\n' "${dir##*/}"; printf '%s\n' "$changes" | sed 's|\t\./|  /etc/|; s|^|  |'; fi
    local h; h=$(checkpoint_home "$dir")
    if [ -n "$h" ]; then
        local huser=${h%%$'\t'*} hdir=${h#*$'\t'} hchanges
        hchanges=$(home_changes "$dir" "$hdir" "$huser")
        if [ -z "$hchanges" ]; then printf '%s: settings unchanged since %s\n' "$hdir" "${dir##*/}"
        else printf '%s since %s:\n' "$hdir" "${dir##*/}"; printf '%s\n' "$hchanges" | sed 's|\t\./|  ~/|; s|^|  |'; fi
    fi
    local dep; dep=$(checkpoint_deployment_state "$dir")
    if [ -n "$dep" ]; then printf 'deployment:\n'; printf '%s\n' "$dep" | cut -f2 | sed 's/^/  /'; fi
    return 0
}

checkpoint_restore() {
    [ $# -eq 1 ] || die "usage: sudo pulsar checkpoint restore <id>  (ids: sudo pulsar checkpoint list)"
    local dir; dir=$(checkpoint_dir "$1")
    local changes; changes=$(etc_changes "${dir}/etc.manifest")

    # Changed and removed paths come back from the archive, and ONLY those:
    # --no-recursion, so restoring a directory's mode does not also rewrite
    # everything under it.
    local list; list=$(mktemp)
    printf '%s\n' "$changes" | awk -F'\t' '$1 == "changed" || $1 == "removed" { print $2 }' \
        | tr '\n' '\0' > "$list"
    if [ -s "$list" ]; then
        local rc=0
        tar --extract --file "${dir}/etc.tar" "${TAR_META[@]}" -C "$ETC_ROOT" \
            --no-recursion --null --files-from "$list" 2>/dev/null || rc=$?
        rm -f "$list"
        [ "$rc" -eq 0 ] || die "restoring /etc failed part way (tar exit ${rc}); run: sudo pulsar checkpoint diff ${dir##*/}"
        printf 'restored in /etc:\n'
        printf '%s\n' "$changes" | awk -F'\t' '$1 != "added" { sub(/^\.\//, "/etc/", $2); print "  " $1 "  " $2 }'
    else
        rm -f "$list"
        printf '/etc: nothing changed or deleted since %s\n' "${dir##*/}"
    fi
    if grep -q '^added' <<<"$changes"; then
        printf 'added since the checkpoint, left in place (delete by hand if unwanted):\n'
        printf '%s\n' "$changes" | awk -F'\t' '$1 == "added" { sub(/^\.\//, "/etc/", $2); print "  " $2 }'
    fi

    checkpoint_restore_home "$dir"

    local dep; dep=$(checkpoint_deployment_state "$dir")
    if grep -q '^staged' <<<"$dep"; then
        # The one OS-side undo that needs no reboot and cannot lose anything
        # the checkpoint had: the staged deployment was made after it.
        rpm-ostree cleanup --pending >/dev/null 2>&1 \
            && printf 'discarded the deployment staged since the checkpoint\n' \
            || printf 'could not discard the staged deployment; run: sudo rpm-ostree cleanup --pending\n'
    fi
    if grep -q '^booted' <<<"$dep"; then
        printf 'a different deployment has booted since; to go back: sudo pulsar rollback, then restart\n'
    elif grep -q '^gone' <<<"$dep"; then
        printf "the checkpoint's deployment is gone; only /etc could be restored\n"
    fi
    printf 'services read /etc when they start: restart the ones whose files changed, or restart the computer\n'
}

# The home half of restore: the same rule as /etc -- changed and deleted
# settings come back, added ones are listed and left -- with every file
# written by the home's owner, from the archive on stdin.
checkpoint_restore_home() {
    local dir=$1 h; h=$(checkpoint_home "$dir")
    [ -n "$h" ] || return 0
    local huser=${h%%$'\t'*} hdir=${h#*$'\t'}
    [ -d "$hdir" ] || { printf '%s is gone; its settings were not restored\n' "$hdir"; return 0; }
    local changes; changes=$(home_changes "$dir" "$hdir" "$huser")
    local t; t=$(owner_tmp "$hdir" "$huser")
    printf '%s\n' "$changes" | awk -F'\t' '$1 == "changed" || $1 == "removed" { print $2 }' \
        | tr '\n' '\0' > "${t}/list"
    chmod 0644 "${t}/list" 2>/dev/null || true
    if [ -s "${t}/list" ]; then
        local rc=0
        as_owner "$hdir" "$huser" tar --extract --file - -C "$hdir" --no-recursion --null \
            --files-from "${t}/list" < "${dir}/home.tar" 2>/dev/null || rc=$?
        rm -rf "$t"
        [ "$rc" -eq 0 ] || die "restoring ${hdir} failed part way (tar exit ${rc}); run: sudo pulsar checkpoint diff ${dir##*/}"
        printf 'restored in %s:\n' "$hdir"
        printf '%s\n' "$changes" | awk -F'\t' '$1 != "added" { sub(/^\.\//, "~/", $2); print "  " $1 "  " $2 }'
        printf 'log out and back in so every app reads the restored settings\n'
    else
        rm -rf "$t"
        printf '%s: no settings changed or deleted since %s\n' "$hdir" "${dir##*/}"
    fi
    if grep -q '^added' <<<"$changes"; then
        printf 'added to %s since the checkpoint, left in place:\n' "$hdir"
        printf '%s\n' "$changes" | awk -F'\t' '$1 == "added" { sub(/^\.\//, "~/", $2); print "  " $2 }'
    fi
}

checkpoint_drop() {
    [ $# -eq 1 ] || die "usage: sudo pulsar checkpoint drop <id>"
    local dir; dir=$(checkpoint_dir "$1")
    # Unpin only a pin this checkpoint made. One the user set by hand, or one
    # an older checkpoint made, is not this checkpoint's to take away.
    if [ "$(jq -r '.pinned_by_checkpoint' "${dir}/meta.json")" = true ] && have ostree && have rpm-ostree; then
        local c js idx others
        c=$(jq -r '.deployment.checksum' "${dir}/meta.json")
        others=$(grep -l "\"${c}\"" "$CHECKPOINTS"/*/meta.json 2>/dev/null | grep -vc "^${dir}/meta.json$" || true)
        if [ "${others:-0}" -eq 0 ]; then
            js=$(rpm-ostree status --json 2>/dev/null) || js='{}'
            idx=$(deployment_index "$js" "$c")
            if [ -n "$idx" ] && ostree admin pin --unpin "$idx" >/dev/null 2>&1; then
                printf 'unpinned the deployment this checkpoint pinned\n'
            fi
        fi
    fi
    rm -rf "$dir"
    printf 'dropped %s\n' "${dir##*/}"
}

checkpoint_help() {
    cat <<'EOF'
usage: sudo pulsar checkpoint [--no-home] [note]
                                           snapshot /etc and your settings, and pin
                                           the booted deployment. --no-home, first
                                           on the line: /etc only
       sudo pulsar checkpoint list         id, build, whether it pinned, note
       sudo pulsar checkpoint diff [id]    what changed in /etc, your settings and
                                           the deployment since (default: the newest)
       sudo pulsar checkpoint restore <id> put back changed and deleted files,
                                           discard a deployment staged since
       sudo pulsar checkpoint drop <id>    delete it, unpinning what it pinned

"Your settings" are the dotfiles in your home folder, ~/.config (minus
folders with "cache" in the name, Service Worker, Crashpad and blob_storage),
~/.local/bin and ~/.ssh, for whoever ran sudo. Settings over 512 MB are
skipped. Documents, projects, ~/.local/share, /var and Flatpak data are not
included. restore does not reboot and does not delete files added since (it
lists them). Why to take one before an agent runs:
https://getpulsar.dev/docs/agents#guard
EOF
}

cmd_checkpoint() {
    case "${1:-}" in
        -h|--help|help) checkpoint_help; return 0 ;;
    esac
    if [ "${1:-}" = --no-home ]; then PULSAR_CHECKPOINT_NO_HOME=1; shift; fi
    local sub=${1:-create}
    case "$sub" in
        list) ;;
        *) no_json "checkpoint ${sub}" ;;
    esac
    case "$sub" in
        list|diff|restore|drop) need_root "checkpoint ${sub}" ;;
        *) need_root checkpoint ;;
    esac
    case "$sub" in
        create)  shift || true; checkpoint_create "$@" ;;
        list)    shift; [ $# -eq 0 ] || die "'checkpoint list' takes no arguments"; checkpoint_list ;;
        diff)    shift; [ $# -le 1 ] || die "usage: sudo pulsar checkpoint diff [id]"; checkpoint_diff "$@" ;;
        restore) shift; checkpoint_restore "$@" ;;
        drop)    shift; checkpoint_drop "$@" ;;
        -*)      die "unknown option: ${sub} (see: pulsar checkpoint --help)" ;;
        # Anything else is a note for a new checkpoint, so the common case is
        # `sudo pulsar checkpoint "before the agent"`.
        *)       checkpoint_create "$@" ;;
    esac
}
