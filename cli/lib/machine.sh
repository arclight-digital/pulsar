# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): pulsar machine: your other Pulsar machines, over SSH.

# ---------------------------------------------------------------------------
# machine -- your other Pulsar machines, reached over SSH, so the Agents app
# (and later your agents) can see and attach to their sessions.
#
# A machine is a name and an ssh target ("magnetar", "nick@10.0.0.5"), in
# MACHINES. Every call goes through one shared connection per machine
# (ControlMaster, kept until it breaks or the user logs out), with BatchMode:
# a key that needs a passphrase prompt or a new host key fails here instead
# of asking; add the host with plain ssh once. An SSH agent (1Password's)
# still asks on screen for each new connection, BatchMode or not, so what
# runs by itself doesn't make one: `pulsar machine --no-connect ...` uses a
# connection that is already open, or fails. Nothing but `pulsar agent ...`
# runs on the other side through exec, and its own Pulsar decides what that
# may do.
# ---------------------------------------------------------------------------
MACHINES=${PULSAR_MACHINES:-${XDG_CONFIG_HOME:-$HOME/.config}/pulsar/machines}
REMOTE_PULSAR=${PULSAR_REMOTE_CLI:-/usr/bin/pulsar}
MACHINE_CONNECT=1   # 0: --no-connect

machine_target() {
    [ -r "$MACHINES" ] || return 1
    awk -F'\t' -v n="$1" '$1 == n { print $2; f = 1; exit } END { exit !f }' "$MACHINES"
}

# SSH_OPTS, for every call. The connection's socket lets whoever opens it
# run commands there, so it is only ever in the user's own runtime folder
# (which a sandbox doesn't see); with none, nothing is shared. The keepalive
# is what ends a connection that died in sleep: 45 s, then calls stop hanging.
machine_ssh_opts() {
    local d="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulsar"
    SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15)
    if (umask 077; mkdir -p "$d") 2>/dev/null; then
        SSH_OPTS+=(-o ControlMaster=auto -o "ControlPath=${d}/ssh-%C" -o ControlPersist=yes)
    else
        SSH_OPTS+=(-o ControlPath=none)
    fi
}

# machine_open <target>: whether its connection is open (never makes one)
machine_open() {
    local -a SSH_OPTS; machine_ssh_opts
    "${PULSAR_SSH:-ssh}" "${SSH_OPTS[@]}" -O check "$1" </dev/null >/dev/null 2>&1
}

# machine_close <target>: its connection ends, unless a machine still has that target
machine_close() {
    [ ! -r "$MACHINES" ] || ! awk -F'\t' -v t="$1" '$2 == t { f = 1 } END { exit !f }' "$MACHINES" || return 0
    local -a SSH_OPTS; machine_ssh_opts
    "${PULSAR_SSH:-ssh}" "${SSH_OPTS[@]}" -O exit "$1" </dev/null >/dev/null 2>&1 || true
}

# machine_key_refused <file>: ssh's errors say it got as far as the key and
# didn't get in. A prompt canceled or timed out, and an agent that quit, all
# print "signing failed ... from agent"; a key that isn't on that machine,
# "Permission denied (". A machine that's asleep or away fails before either.
machine_key_refused() {
    grep -qE 'signing failed for .* from agent|Permission denied \(|Too many authentication failures' "$1"
}

# mssh [-t] <target> <word>...: the words run on the other side as written
# (each quoted for its shell)
mssh() {
    local tty=() target line="" w
    [ "$1" != -t ] || { tty=(-t); shift; }
    target=$1; shift
    local -a SSH_OPTS; machine_ssh_opts
    if [ "$MACHINE_CONNECT" = 0 ]; then
        machine_open "$target" || { printf 'no open connection to %s\n' "$target" >&2; return 255; }
        # ssh makes a connection of its own when the shared one ends after
        # that check, or has no room for another session (sshd's MaxSessions):
        # that one gets no key, so it can't ask for one. ssh takes the first
        # of each option, so these go in front.
        SSH_OPTS=(-o ControlMaster=no -o IdentityAgent=none -o PubkeyAuthentication=no "${SSH_OPTS[@]}")
    fi
    for w in "$@"; do line+=" $(printf '%q' "$w")"; done
    local st=0
    "${PULSAR_SSH:-ssh}" "${SSH_OPTS[@]}" "${tty[@]}" "$target" -- "${line# }" || st=$?
    if [ "$st" = 255 ] && [ "$MACHINE_CONNECT" = 0 ] && machine_open "$target"; then
        printf 'the connection to %s is full: close a terminal or shell on it to open another (sshd allows 10 unless its MaxSessions says more)\n' "$target" >&2
    fi
    return "$st"
}

machine_names() { [ ! -r "$MACHINES" ] || cut -f1 "$MACHINES"; }

# git over the same shared connection as mssh
machine_git() {
    local -a SSH_OPTS; machine_ssh_opts
    GIT_SSH_COMMAND="${PULSAR_SSH:-ssh} $(printf '%q ' "${SSH_OPTS[@]}")" \
        git "$@"
}

# The commit that is a folder's work as it stands: HEAD, plus one commit on
# top with what isn't committed (new files too, not ignored ones), made in a
# scratch index so the user's own index and checkout are left as they were.
wip_commit() {
    local dir=$1 msg=$2 idx tree head
    head=$(git -C "$dir" rev-parse --verify -q HEAD) || return 1
    idx=$(mktemp) || return 1
    cp "$(git -C "$dir" rev-parse --path-format=absolute --git-path index)" "$idx" 2>/dev/null || : > "$idx"
    if ! GIT_INDEX_FILE=$idx git -C "$dir" add -A :/ 2>/dev/null || ! tree=$(GIT_INDEX_FILE=$idx git -C "$dir" write-tree); then
        rm -f "$idx"; return 1
    fi
    rm -f "$idx"
    if [ "$tree" = "$(git -C "$dir" rev-parse "${head}^{tree}")" ]; then
        printf '%s\n' "$head"
    else
        git -C "$dir" -c user.name="${GIT_AUTHOR_NAME:-Pulsar}" -c user.email="${GIT_AUTHOR_EMAIL:-pulsar@localhost}" \
            commit-tree "$tree" -p "$head" -m "$msg"
    fi
}

# The project a folder is in: its main checkout (a worktree's too), under $HOME.
handoff_project() {
    local common
    common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
        || die "$1 is not in a git repository: work goes to another machine by git"
    [ "$(basename "$common")" = .git ] || die "${common} is a bare repository"
    local main; main=$(dirname "$common")
    case "$main/" in "$HOME"/*) ;; *) die "${main} is not under your home, where the other machine would put it too" ;; esac
    printf '%s\n' "$main"
}

# machine_send <machine> <folder> <branch>: the folder's work, as it stands,
# onto <branch> in the same project (by its path under your home) on that
# machine, which makes the project there if it has none. Sets MS_PATH (the
# project there), MS_REL (its path under home, the same on both), MS_COMMIT,
# MS_TARGET.
machine_send() {
    local m=$1 dir=$2 branch=$3 t main rel commit there
    t=$(machine_target "$m") || die "no machine called $m (pulsar machine list)"
    main=$(handoff_project "$dir")
    rel=${main#"$HOME"/}
    commit=$(wip_commit "$dir" "Work in progress, handed to ${m} by Pulsar") \
        || die "${dir} has no commit yet: commit something first"
    there=$(mssh "$t" "$REMOTE_PULSAR" machine receive "$rel" 2>&1) \
        || die "${m} could not take ${rel}: ${there##*$'\n'}"
    there=${there##*$'\n'}
    case "$there" in /*) ;; *) die "${m} answered something that isn't a folder: ${there}" ;; esac
    local out
    if ! out=$(machine_git -C "$dir" push --quiet "${t}:${there}" "${commit}:refs/heads/${branch}" 2>&1); then
        case "$out" in
            *"[rejected]"*|*"already exists"*|*"non-fast-forward"*|*"fetch first"*)
                die "${m} has a branch ${branch} already: pick another --name" ;;
        esac
        die "could not send the work to ${m}: ${out##*$'\n'}"
    fi
    MS_PATH=$there MS_COMMIT=$commit MS_TARGET=$t MS_REL=$rel
}

# a name for a new session or job from words: the first few, as a slug, and the time
handoff_name() {
    local w; w=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' ' | awk '{ for (i = 1; i <= NF && i <= 3; i++) printf "%s%s", (i > 1 ? "-" : ""), $i }')
    printf '%s-%s\n' "${w:-work}" "$(date +%H%M)"
}

cmd_machine() {
    local usage="usage: pulsar machine add <name> <ssh target> | remove <name> | list | check [<name>] | sessions [--hold <name>]...
       pulsar machine run <name> <agent> [--name <session>] [--dir <folder>] [--prompt <text>] [--sandbox]
       pulsar machine job <name> [--name <job>] [--dir <folder>] [--notify <session>] -- <command>...
       pulsar machine fetch <name> <session> [--dir <folder>]
       pulsar machine exec <name> -- agent <args> | job wait|log|list|stop <args>
       pulsar machine shell <name> [--dir <folder>]
       pulsar machine discover | announce [on|off]
       pulsar machine --no-connect ...: only over a connection that is already open"
    local MACHINE_CONNECT=$MACHINE_CONNECT
    if [ "${1:-}" = --no-connect ]; then MACHINE_CONNECT=0; shift; fi
    local sub=${1:-list}; shift || true
    case "$sub" in
        -h|--help) printf '%s\n' "$usage"; return 0 ;;
        add)
            [ $# -eq 2 ] || die "$usage"
            case "$1" in
                local|'') die "'$1' can't be a machine's name" ;;
                *[!a-z0-9-]*|-*) die "a machine's name is lowercase letters, digits and -: '$1'" ;;
            esac
            case "$2" in -*|*[[:space:]]*|'') die "not an ssh target: '$2'" ;; esac
            local v was
            was=$(machine_target "$1") || was=""
            v=$(mssh "$2" "$REMOTE_PULSAR" --version 2>&1) \
                || die "could not reach Pulsar on $2 over ssh (BatchMode: no prompts; ssh $2 once to accept its key): ${v##*$'\n'}"
            mkdir -p "$(dirname "$MACHINES")"
            { [ ! -r "$MACHINES" ] || awk -F'\t' -v n="$1" '$1 != n' "$MACHINES"
              printf '%s\t%s\n' "$1" "$2"; } > "${MACHINES}.tmp" && mv "${MACHINES}.tmp" "$MACHINES"
            [ -z "$was" ] || machine_close "$was"
            printf 'added %s (%s): %s\n' "$1" "$2" "$v" ;;
        remove)
            [ $# -eq 1 ] || die "$usage"
            local t; t=$(machine_target "$1") || die "no machine called $1 (pulsar machine list)"
            awk -F'\t' -v n="$1" '$1 != n' "$MACHINES" > "${MACHINES}.tmp" && mv "${MACHINES}.tmp" "$MACHINES"
            machine_close "$t"
            printf 'removed %s\n' "$1" ;;
        list)
            [ $# -eq 0 ] || die "$usage"
            if [ "${JSON:-0}" = 1 ]; then
                { [ ! -r "$MACHINES" ] || cat "$MACHINES"; } \
                    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], target: .[1]})'
                return 0
            fi
            [ -s "$MACHINES" ] || { printf 'no machines  (pulsar machine add <name> <ssh target>)\n'; return 0; }
            column -t -s $'\t' "$MACHINES" ;;
        check)
            [ $# -le 1 ] || die "$usage"
            local n t out rows=()
            for n in ${1:-$(machine_names)}; do
                t=$(machine_target "$n") || die "no machine called $n (pulsar machine list)"
                if out=$(mssh "$t" "$REMOTE_PULSAR" manifest --json 2>&1) && jq -e . >/dev/null 2>&1 <<<"$out"; then
                    local agents
                    agents=$(mssh "$t" "$REMOTE_PULSAR" agent list --json 2>/dev/null) || agents='[]'
                    rows+=("$(jq -n -c --arg n "$n" --arg t "$t" --argjson m "$out" --argjson a "$agents" \
                        '{name: $n, target: $t, reachable: true, release: $m.release, version: $m.version,
                          variant: $m.variant, gpu: ($m.host.gpu // null),
                          agents: [$a[]? | select(.state == "installed" or .state == "native") | .name]}')")
                else
                    rows+=("$(jq -n -c --arg n "$n" --arg t "$t" --arg e "${out##*$'\n'}" \
                        '{name: $n, target: $t, reachable: false, error: $e}')")
                fi
            done
            if [ "${JSON:-0}" = 1 ]; then printf '%s\n' "${rows[@]}" | jq -s -c .; return 0; fi
            [ ${#rows[@]} -gt 0 ] || { printf 'no machines\n'; return 0; }
            printf '%s\n' "${rows[@]}" | jq -r 'if .reachable
                then "\(.name)\t\(.target)\tPulsar \(.release // "?") (\(.version // "?"))\t\(.agents | join(" "))"
                else "\(.name)\t\(.target)\tunreachable: \(.error)" end' | column -t -s $'\t' ;;
        sessions)
            # --hold <name>: no new connection to that one (its key was refused)
            local hold=" "
            while [ $# -gt 0 ]; do
                case "$1" in --hold) [ $# -ge 2 ] || die "$usage"; hold+="$2 "; shift ;; *) die "$usage" ;; esac
                shift
            done
            # every machine at once; a slow or gone one costs its timeout, not the others'
            local d n t; d=$(mktemp -d)
            while IFS= read -r n; do
                [ -n "$n" ] || continue
                t=$(machine_target "$n") || continue
                # kept only as a list of sessions with names: anything else
                # that machine says is its own problem, not every machine's
                ( case "$hold" in *" ${n} "*) MACHINE_CONNECT=0 ;; esac
                  # an open connection is only ever used: were it out of
                  # room, ssh would make another and ask for the key
                  ! machine_open "$t" || MACHINE_CONNECT=0
                  st=0
                  mssh "$t" "$REMOTE_PULSAR" agent sessions --json > "${d}/${n}.raw" 2> "${d}/${n}.err" || st=$?
                  why=unreachable
                  if [ "$st" = 255 ]; then
                      if [ "$MACHINE_CONNECT" = 0 ]; then
                          why=closed
                          ! machine_open "$t" || why=full
                      elif machine_key_refused "${d}/${n}.err"; then why=refused; fi
                  fi
                  printf '%s' "$why" > "${d}/${n}.why"
                  if [ "$st" = 0 ] \
                      && jq -c 'if type == "array" then map(select(type == "object" and (.name | type) == "string")) else error("not a list") end' \
                         "${d}/${n}.raw" > "${d}/${n}.out" 2>/dev/null; then :
                  else rm -f "${d}/${n}.out"; fi ) &
            done < <(machine_names)
            wait
            local res='{"machines": [], "sessions": []}'
            while IFS= read -r n; do
                [ -n "$n" ] || continue
                if [ -f "${d}/${n}.out" ]; then
                    res=$(jq -c --arg n "$n" --slurpfile s "${d}/${n}.out" \
                        '.machines += [{name: $n, ok: true}] | .sessions += [$s[0][] | .machine = $n]' <<<"$res")
                else
                    res=$(jq -c --arg n "$n" --arg e "$(tail -n 1 "${d}/${n}.err" 2>/dev/null)" \
                        --arg w "$(cat "${d}/${n}.why" 2>/dev/null)" \
                        '.machines += [{name: $n, ok: false, why: $w, error: $e}]' <<<"$res")
                fi
            done < <(machine_names)
            rm -rf "$d"
            if [ "${JSON:-0}" = 1 ]; then printf '%s\n' "$res"; return 0; fi
            jq -r '(.machines[] | select(.ok | not) | "\(.name): unreachable (\(.error))"),
                   (.sessions[] | "\(.machine)\t\(.name)\t\(.agent // "-")\t\(.state)\t\(.dir // "-")")' <<<"$res" ;;
        run)
            # your work to that machine, and an agent on it there in a worktree
            local n=${1:-} agent=${2:-}; shift 2 || die "$usage"
            local name="" dir=$PWD prompt="" sb=()
            while [ $# -gt 0 ]; do
                case "$1" in
                    --name) [ $# -ge 2 ] || die "$usage"; name=$2; shift ;;
                    --dir) [ $# -ge 2 ] || die "$usage"; dir=$2; shift ;;
                    --prompt) [ $# -ge 2 ] || die "$usage"; prompt=$2; shift ;;
                    --sandbox|--no-sandbox) sb=("$1") ;;
                    *) die "$usage" ;;
                esac
                shift
            done
            case "$agent" in ''|-*|*[!a-z0-9-]*) die "$usage" ;; esac
            [ -n "$name" ] || name=$(handoff_name "${prompt:-$(basename "$(handoff_project "$dir")")}")
            case "$name" in -*|*[!A-Za-z0-9_-]*) die "a session's name is letters, digits, - and _: '$name'" ;; esac
            machine_send "$n" "$dir" "$name"
            local -a pa=()
            [ -z "$prompt" ] || pa=(--prompt "$prompt")
            mssh "$MS_TARGET" "$REMOTE_PULSAR" agent run "$agent" --tmux "$name" --new --dir "$MS_PATH" --worktree "${sb[@]}" "${pa[@]}" >/dev/null \
                || die "${n} could not start ${agent} (pulsar machine exec ${n} -- agent sessions)"
            printf '%s is running on %s, on its branch %s (your work as of %s)\n' "$name" "$n" "$name" "$(git -C "$dir" rev-parse --short "$MS_COMMIT")"
            printf 'Agents shows it as %s@%s; pulsar machine fetch %s %s brings its branch back\n' "$name" "$n" "$n" "$name" ;;
        job)
            # your work to that machine, and a command run there as a job
            local n=${1:-}; shift || die "$usage"
            local name="" dir=$PWD notify=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --name) [ $# -ge 2 ] || die "$usage"; name=$2; shift ;;
                    --dir) [ $# -ge 2 ] || die "$usage"; dir=$2; shift ;;
                    --notify) [ $# -ge 2 ] || die "$usage"; notify=$2; shift ;;
                    --) shift; break ;;
                    *) die "$usage" ;;
                esac
                shift
            done
            [ $# -gt 0 ] || die "$usage"
            case "$notify" in *[!A-Za-z0-9_-]*) die "--notify is a session's name here" ;; esac
            [ -n "$name" ] || name=$(handoff_name "$(basename -- "$1")")
            case "$name" in -*|*[!A-Za-z0-9_-]*) die "a job's name is letters, digits, - and _: '$name'" ;; esac
            machine_send "$n" "$dir" "job-${name}"
            local wt
            wt=$(mssh "$MS_TARGET" "$REMOTE_PULSAR" machine receive "$MS_REL" --checkout "job-${name}" 2>&1) \
                || die "${n} could not check out the work: ${wt##*$'\n'}"
            wt=${wt##*$'\n'}
            mssh "$MS_TARGET" "$REMOTE_PULSAR" job run --name "$name" --dir "$wt" -- "$@" >/dev/null \
                || die "${n} could not start the job"
            printf '%s is running on %s in %s\n' "$name" "$n" "$wt"
            if [ -n "$notify" ]; then
                # here, a job that waits on that one, so how it ends reaches
                # the session here as any job's does; that machine never has
                # to reach this one
                "$SELF" job run --name "${n}-${name}" --notify "$notify" -- "$SELF" machine wait "$n" "$name" >/dev/null \
                    || die "started, but could not watch it for ${notify}"
                printf '%s hears how it ends\n' "$notify"
            fi ;;
        fetch)
            # a session's branch from that machine, its uncommitted work on
            # top, as <machine>/<session>; your checkout is left alone
            local n=${1:-} sname=${2:-}; shift 2 || die "$usage"
            local dir=$PWD
            while [ $# -gt 0 ]; do
                case "$1" in --dir) [ $# -ge 2 ] || die "$usage"; dir=$2; shift ;; *) die "$usage" ;; esac
                shift
            done
            case "$sname" in ''|-*|*[!A-Za-z0-9_-]*) die "$usage" ;; esac
            local t; t=$(machine_target "$n") || die "no machine called $n (pulsar machine list)"
            local main; main=$(handoff_project "$dir")
            local got
            got=$(mssh "$t" "$REMOTE_PULSAR" machine receive --snapshot "$sname" 2>&1) \
                || die "${n}: ${got##*$'\n'}"
            got=${got##*$'\n'}
            local there=${got%%$'\t'*} ref=${got#*$'\t'}
            # what came back is a project path and that session's ref, or nothing is fetched
            case "$there" in /*) ;; *) die "${n} answered something that isn't a folder: ${there}" ;; esac
            [ "$ref" = "refs/handoff/${sname}" ] || die "${n} answered something that isn't ${sname}'s branch: ${ref}"
            # --no-tags: that machine's tags stay there
            machine_git -C "$main" fetch --quiet --no-tags "${t}:${there}" "+${ref}:refs/remotes/${n}/${sname}" \
                || die "could not fetch ${sname} from ${n}"
            local ahead; ahead=$(git -C "$main" rev-list --count "HEAD..refs/remotes/${n}/${sname}" 2>/dev/null) || ahead="?"
            printf 'fetched %s/%s: %s commit(s) your HEAD does not have\n' "$n" "$sname" "$ahead"
            printf 'see them: git log HEAD..%s/%s   the change: git diff HEAD...%s/%s\n' "$n" "$sname" "$n" "$sname" ;;
        announce)
            # Off unless you turn it on: a user service that publishes this
            # machine on the local network over mDNS (_pulsar._tcp), with
            # your user name and release, so `machine discover` on your
            # other machines lists it. Nothing is published as root.
            local unit=pulsar-announce.service
            case "${1:-status}" in
                on)
                    systemctl --user enable --now "$unit" >/dev/null 2>&1 || die "could not start ${unit} (systemctl --user status ${unit})"
                    printf 'other Pulsar machines on this network can find this one now (pulsar machine announce off stops it)\n' ;;
                off)
                    systemctl --user disable --now "$unit" >/dev/null 2>&1 || true
                    printf 'this machine is no longer announced\n' ;;
                status)
                    local st="off"; systemctl --user is-active --quiet "$unit" 2>/dev/null && st=on
                    if [ "${JSON:-0}" = 1 ]; then jq -n -c --arg s "$st" '{announce: $s}'; else printf 'announce %s\n' "$st"; fi ;;
                --run)
                    # the service's own: publish until stopped
                    need avahi-publish
                    local host ssh=off
                    host=$(hostname -s 2>/dev/null) || host=pulsar
                    ! systemctl is-active --quiet sshd 2>/dev/null || ssh=on
                    exec avahi-publish -s "Pulsar on ${host}" _pulsar._tcp 22 \
                        "user=$(id -un)" "host=${host}" "release=${VERSION}" "ssh=${ssh}" ;;
                *) die "usage: pulsar machine announce [on|off|status]" ;;
            esac ;;
        discover)
            # Pulsar machines announcing themselves on this network: name,
            # where, whose, and whether it's added here already
            need jq
            command -v avahi-browse >/dev/null || die "avahi-browse is missing"
            local me; me=$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')
            local raw; raw=$(timeout "${PULSAR_DISCOVER_SECONDS:-4}" avahi-browse -rtp _pulsar._tcp 2>/dev/null) || true
            local added; added=$({ [ ! -r "$MACHINES" ] || cut -f2 "$MACHINES"; } | jq -R -s -c 'split("\n") | map(select(length > 0))')
            local rows
            rows=$(printf '%s\n' "$raw" | awk -F';' '$1 == "=" { print }' | jq -R -s -c --arg me "$me" --argjson added "$added" '
                split("\n") | map(select(length > 0) | split(";")
                  | {proto: .[2], address: .[7], mdns: .[6], txt: ((.[9] // "") | reduce (scan("\"([^\"]*)\"")[0] | capture("(?<k>[^=]+)=(?<v>.*)")) as $kv ({}; .[$kv.k] = $kv.v))})
                | group_by(.mdns)
                | map((map(select(.proto == "IPv4")) + .)[0])
                | map(select(((.txt.user // "") | test("^([a-z_][a-z0-9_-]*)?$"))
                             and ((.txt.host // "x") | ascii_downcase | test("^[a-z0-9][a-z0-9-]*$"))
                             and (.mdns | test("^[A-Za-z0-9][A-Za-z0-9-]*\\.local$"))))
                | map({name: (.mdns | sub("\\.local$"; "") | ascii_downcase),
                       mdns: .mdns, address: .address, user: (.txt.user // null),
                       release: (.txt.release // null), ssh: (.txt.ssh == "on")}
                      | . + {target: ((if .user then .user + "@" else "" end) + .mdns),
                             self: (.name == $me)}
                      | . + {added: (([.target, .mdns, .address, .name, ((.user // "") + "@" + .address)] - ([.target, .mdns, .address, .name, ((.user // "") + "@" + .address)] - $added)) | length > 0)})
                | sort_by(.name)')
            if [ "${JSON:-0}" = 1 ]; then printf '%s\n' "$rows"; return 0; fi
            [ "$(jq length <<<"$rows")" -gt 0 ] || { printf 'no Pulsar machines announcing on this network (pulsar machine announce on, on each)\n'; return 0; }
            jq -r '.[] | "\(.name)\t\(.target)\tPulsar \(.release // "?")\(if .self then "\t(this machine)" elif .added then "\tadded" else "\tpulsar machine add \(.name) \(.target)" end)"' <<<"$rows" \
                | column -t -s $'\t' ;;
        receive)
            # the other side of run, job and fetch: this machine's end
            case "${1:-}" in
                --snapshot)
                    # a session's worktree as it stands, as refs/handoff/<session>
                    local sname=${2:-}
                    case "$sname" in ''|-*|*[!A-Za-z0-9_-]*) die "usage: pulsar machine receive --snapshot <session>" ;; esac
                    local wd; wd=$(session_get "$sname" dir) || die "no session called ${sname} here"
                    [ -d "$wd" ] || die "${sname}'s folder ${wd} is gone"
                    local c; c=$(wip_commit "$wd" "Work in progress in ${sname}, fetched by Pulsar") || die "${wd} has no commit"
                    local mn; mn=$(handoff_project "$wd")
                    git -C "$mn" update-ref "refs/handoff/${sname}" "$c"
                    printf '%s\trefs/handoff/%s\n' "$mn" "$sname"
                    return 0 ;;
            esac
            local rel=${1:-}; shift || true
            case "$rel" in ''|/*|*..*|-*) die "usage: pulsar machine receive <path under home> [--checkout <branch>]" ;; esac
            local p="${HOME}/${rel}"
            if [ "${1:-}" = --checkout ]; then
                local br=${2:-}
                case "$br" in ''|-*|*[!A-Za-z0-9_-]*) die "--checkout takes a branch" ;; esac
                git -C "$p" show-ref --verify --quiet "refs/heads/${br}" || die "no branch ${br} in ${p}"
                local wt="${p}/.worktrees/${br}"
                if [ ! -e "$wt" ]; then
                    local excl; excl=$(git -C "$p" rev-parse --path-format=absolute --git-path info/exclude)
                    mkdir -p "$(dirname "$excl")"
                    grep -qxF '/.worktrees/' "$excl" 2>/dev/null || printf '/.worktrees/\n' >> "$excl"
                    git -C "$p" worktree add --quiet "$wt" "$br" >&2 || die "git could not check out ${br}"
                fi
                printf '%s\n' "$wt"
                return 0
            fi
            if [ ! -e "${p}/.git" ]; then
                [ ! -e "$p" ] || [ -z "$(ls -A "$p" 2>/dev/null)" ] || die "${p} is there and isn't a git repository"
                { mkdir -p "$p" && git -C "$p" init --quiet; } || die "could not make ${p}"
            fi
            printf '%s\n' "$p" ;;
        wait)
            # a job there, until it ends, through any number of dropped
            # connections (the laptop sleeping, Wi-Fi): only the job's own end
            # is its result; ssh failing (255) is waited out, for a day at most
            local n=${1:-} j=${2:-}
            case "$j" in ''|-*|*[!A-Za-z0-9_-]*) die "usage: pulsar machine wait <machine> <job>" ;; esac
            machine_target "$n" >/dev/null || die "no machine called $n (pulsar machine list)"
            local tries=0 st
            while :; do
                st=0; cmd_machine exec "$n" -- job wait "$j" || st=$?
                [ "$st" = 255 ] || return "$st"
                tries=$((tries + 1)); [ "$tries" -lt 2880 ] || die "lost ${n} for a day; the job may still be running there (pulsar machine exec ${n} -- job list)"
                sleep "${PULSAR_MACHINE_RETRY:-30}"
            done ;;
        shell)
            # a login shell there, in a folder: the Agents app's shell panel
            # under a session on that machine
            local n=${1:-} dir=""; shift || true
            while [ $# -gt 0 ]; do
                case "$1" in
                    --dir) [ $# -ge 2 ] || die "$usage"; dir=$2; shift ;;
                    *) die "$usage" ;;
                esac
                shift
            done
            local t; t=$(machine_target "$n") || die "no machine called $n (pulsar machine list)"
            local -a tt=()
            [ ! -t 0 ] || [ ! -t 1 ] || tt=(-t)
            # shellcheck disable=SC2016  # expanded there
            mssh "${tt[@]}" "$t" sh -c '{ [ -n "$1" ] && cd "$1" 2>/dev/null; } || cd; exec "${SHELL:-/bin/bash}" -l' sh "$dir" ;;
        exec)
            local n=${1:-}; shift || true
            if [ "${1:-}" = -- ] && [ "${2:-}" = job ]; then
                # a job's state from there: wait (the --notify watcher), log, list, stop
                case "${3:-}" in wait|log|list|stop) ;; *) die "$usage" ;; esac
                shift 2
                local t; t=$(machine_target "$n") || die "no machine called $n (pulsar machine list)"
                [ "${JSON:-0}" != 1 ] || set -- --json "$@"
                mssh "$t" "$REMOTE_PULSAR" job "$@"
                return
            fi
            [ "${1:-}" = -- ] && [ "${2:-}" = agent ] || die "$usage"
            shift 2
            local t; t=$(machine_target "$n") || die "no machine called $n (pulsar machine list)"
            # the app's own view of a session, there as here; with the mouse
            # on, since the app can't drive that machine's tmux to scroll; and
            # the view's tag, by which the app later marks it hidden there
            # (agent sizes --view)
            local -a pre=()
            if [ "${PULSAR_AGENT_VIEW:-0}" = 1 ]; then
                pre=(env PULSAR_AGENT_VIEW=1 PULSAR_AGENT_VIEW_MOUSE=on)
                case "${PULSAR_AGENT_VIEW_TAG:-}" in
                    ''|*[!A-Za-z0-9_-]*) ;;
                    *) pre+=("PULSAR_AGENT_VIEW_TAG=$PULSAR_AGENT_VIEW_TAG") ;;
                esac
            fi
            local -a tt=()
            [ ! -t 0 ] || [ ! -t 1 ] || tt=(-t)
            [ "${JSON:-0}" != 1 ] || set -- --json "$@"
            mssh "${tt[@]}" "$t" "${pre[@]}" "$REMOTE_PULSAR" agent "$@" ;;
        *) die "$usage" ;;
    esac
}
