# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): agent sessions: one agent per tmux session, their records, attach, the list, usage.

# ---------------------------------------------------------------------------
# agent run --tmux -- one agent per named tmux session, on its own server.
#
# The server runs on the HOST, on its own socket (-L pulsar-agents) with its
# own config, so it never shares a server with the user's own tmux or one
# started in a toolbox (they all share /tmp/tmux-$UID). On the host because
# that is the one place every kind of start works from: each pane runs
# `pulsar agent run`, which steps into the agents box, starts the sandbox's
# podman, or runs a native install, and a toolbox that stops or is recreated
# takes no session with it.
#
# Each name is tied to one conversation, in AGENT_SESSIONS/<name>.session, so
# a session that died (logout, reboot) comes back on THAT conversation rather
# than "the most recent in this folder", which two sessions in one project
# would share. Claude Code (--session-id, --resume <id>) and opencode
# (--session <id>) take an ID up front. agy names its own, which the session
# learns while it runs (--conversation <id>), else resumes the last one in
# its folder (-c), as codex does (resume --last): exact for a worktree
# session, which has its folder to itself. gemini and aider start a new one.
# ---------------------------------------------------------------------------
AGENT_TMUX_SOCKET=${PULSAR_AGENT_TMUX_SOCKET:-pulsar-agents}
AGENT_TMUX_CONF=${PULSAR_AGENT_TMUX_CONF:-/usr/share/pulsar/agents-tmux.conf}
AGENT_SESSIONS=${PULSAR_AGENT_SESSIONS:-${XDG_STATE_HOME:-$HOME/.local/state}/pulsar/agents}
# A folder per session for what its agent makes and needn't keep (VM disks,
# builds, downloads): PULSAR_SCRATCH in its environment, on disk, mounted
# into the sandbox. Deleted with the session (--forget, --tidy), so an
# archived session's leftovers go a week later on their own.
AGENT_SCRATCH=${PULSAR_AGENT_SCRATCH:-/var/tmp/pulsar-agents}

# What a pane runs: the agent, then a shell in the same pane, so the
# scrollback stays and the session ends only when the user exits that shell.
# shellcheck disable=SC2016  # expanded by the pane's bash, not here
# Its command comes in a file (PULSAR_PANE_ARGV, NUL-separated), not as
# tmux arguments: tmux reads a word ending in ";" as the end of its own
# command, so a prompt or an argument like that never reached the agent.
AGENT_TMUX_PANE='PULSAR_TTY=$(tty 2>/dev/null) && export PULSAR_TTY
if [ -n "${PULSAR_PANE_ARGV:-}" ] && [ -f "$PULSAR_PANE_ARGV" ]; then
    mapfile -d "" -t _a < "$PULSAR_PANE_ARGV"; rm -f "$PULSAR_PANE_ARGV"; unset PULSAR_PANE_ARGV; set -- "${_a[@]}"
fi
"$@"; s=$?
[ -z "${PULSAR_SESSION_RECORD:-}" ] || touch -c "$PULSAR_SESSION_RECORD"
tmux set-option -w @pulsar-exited "$s" 2>/dev/null
printf "\n[%s exited with status %s. This shell keeps the scrollback; exit ends the session.]\n" "$0" "$s"
exec "${SHELL:-/bin/bash}" -l'

# tmux, on the agents' server. The config only matters when this starts it.
atmux_argv() {
    ATMUX=(tmux -L "$AGENT_TMUX_SOCKET")
    [ ! -r "$AGENT_TMUX_CONF" ] || ATMUX+=(-f "$AGENT_TMUX_CONF")
}
atmux() { atmux_argv; "${ATMUX[@]}" "$@"; }

atmux_running() { atmux has-session -t "=$1" 2>/dev/null; }

# Whether someone is looking at a session: a client on it (or on a view of
# it), in a focused terminal.
atmux_watched() {
    atmux list-clients -F $'#{?session_grouped,#{session_group},#{session_name}}\t#{client_flags}' 2>/dev/null \
        | awk -F'\t' -v n="$1" '$1 == n && $2 ~ /focused/ { f = 1 } END { exit !f }'
}

# The Agents app's view of a session: a session of its own in the same
# group (the same windows, so the same agent), named <session>~app<n>, with
# options of its own: no prefix key, an empty key table (so no tmux key or
# menu at all, every key is the agent's), no status line, and tmux's mouse
# off, so a drag is the app's own selection (the app scrolls tmux's history
# itself). A terminal attaches to the session itself and keeps tmux as it
# is. Gone when the app lets go (destroy-unattached). Attaches, in place of
# the caller.
atmux_view() {
    local v="${1}~app$$"
    # The table has to exist to be chosen. Here the app drives the wheel
    # itself (mouse off); seen from another machine (mouse on) this does: an
    # agent that tracks the mouse gets it, else tmux's history scrolls (never
    # arrow keys, which bring back an old prompt in an agent's input). Wheel
    # down is left unbound, so it goes to the pane, or to copy mode's table.
    atmux bind -T pulsar-app WheelUpPane if -F '#{||:#{pane_in_mode},#{mouse_any_flag}}' 'send -M' \
        "if -F '#{!:#{alternate_on}}' 'copy-mode -e'" 2>/dev/null || return 1
    # this server's hooks as this CLI sets them (one started by an older one)
    agent_tmux_hooks "$(realpath "$SELF")"
    unset TMUX
    atmux_argv
    # the app's tag for this view, when it is another machine's app: it
    # marks the view hidden by it (agent sizes --view)
    local -a tag=()
    case "${PULSAR_AGENT_VIEW_TAG:-}" in
        ''|*[!A-Za-z0-9_-]*) ;;
        *) tag=(\; set -t "=$v:" @pulsar-view "$PULSAR_AGENT_VIEW_TAG") ;;
    esac
    # created attached, so destroy-unattached never sees it without a client
    exec "${ATMUX[@]}" new-session -t "=$1" -s "$v" \; \
        set -t "=$v:" destroy-unattached on \; set -t "=$v:" prefix None \; set -t "=$v:" prefix2 None \; \
        set -t "=$v:" key-table pulsar-app \; set -t "=$v:" status off \; set -t "=$v:" mouse "${PULSAR_AGENT_VIEW_MOUSE:-off}" \
        "${tag[@]}"
}

# A session and every view of it: a view left behind would keep its windows,
# and so the agent, running.
atmux_end() {
    local v
    while IFS= read -r v; do
        case "$v" in "${1}~"*) atmux kill-session -t "=$v" 2>/dev/null || true ;; esac
    done < <(atmux list-sessions -F '#{session_name}' 2>/dev/null || true)
    atmux kill-session -t "=$1"
}

# The agents' server's hooks, set on every start (the CLI's path can move).
agent_tmux_hooks() {
    local cli=$1 hook h
    # A bell in any agent's session is the agent asking for you; the notice
    # goes away once you look. Quoted twice: for the shell run-shell starts,
    # then for tmux, whose own parser reads this string; ## is a # its
    # formats leave alone.
    # tmux runs alert-bell once for every session the window is in, the
    # Agents app's views (<name>~app<pid>) included: only the real one acts,
    # or one bell was handled as many times (a turn taken over by mail was
    # marked waiting again by the second run).
    hook="$(sq "$cli") agent notify"
    atmux set-hook -g alert-bell "if-shell -F '#{!:#{m:*~*,#{session_name}}}' $(tq "run-shell -b $(tq "${hook//\#/\#\#} #{session_name}")")"
    # "Waiting" means at its prompt, and goes when a turn starts (Claude's
    # UserPromptSubmit, a key into it from the app), not when someone looks:
    # an older Pulsar's hooks that cleared it on attach and focus go (only
    # those: hooks of your own stay).
    for h in client-focus-in client-attached client-session-changed; do
        case "$(atmux show-hooks -g "${h}[0]" 2>/dev/null)" in
            *" agent seen "*) atmux set-hook -gu "${h}[0]" 2>/dev/null || true ;;
        esac
    done
    # Window sizes while the app has a view on a session (agent sizes):
    # checked whenever a client comes, moves or a session goes. At an index
    # of their own: a plain set-hook replaces every hook of that name.
    local sizes; sizes="$(sq "$cli") agent sizes"
    for h in client-attached client-session-changed session-closed; do
        atmux set-hook -g "${h}[41]" "run-shell -b $(tq "${sizes//\#/\#\#}")"
    done
}

# session_get <session> <key>: agent, dir or id, from its record.
session_get() {
    local f="${AGENT_SESSIONS}/$1.session" k v
    [ -r "$f" ] || return 1
    while IFS='=' read -r k v; do
        [ "$k" != "$2" ] || { printf '%s\n' "$v"; return 0; }
    done < "$f"
    return 1
}

# session_put <session> <agent> <dir> <conversation> <sandbox on|off> [<repo, for a worktree>]
#             [<the undo snapshot of the session's start>]
session_put() {
    local tmp
    mkdir -p "$AGENT_SESSIONS"
    tmp=$(mktemp "${AGENT_SESSIONS}/.$1.XXXXXX")
    printf 'agent=%s\ndir=%s\nid=%s\nsandbox=%s\n' "$2" "$3" "$4" "$5" > "$tmp"
    [ -z "${6:-}" ] || printf 'repo=%s\n' "$6" >> "$tmp"
    [ -z "${7:-}" ] || printf 'base=%s\n' "$7" >> "$tmp"
    # what the user gave it stays across starts; a start brings an archived
    # session back to the list
    local title=${AGENT_RUN_TITLE:-}
    [ -n "$title" ] || title=$(session_get "$1" title) || title=""
    title=${title//$'\n'/ }
    [ -z "$title" ] || printf 'title=%s\n' "$title" >> "$tmp"
    local icon; icon=$(session_get "$1" icon) || icon=""
    [ -z "$icon" ] || printf 'icon=%s\n' "$icon" >> "$tmp"
    mv "$tmp" "${AGENT_SESSIONS}/$1.session"
}

# session_set <session> <key> <value>: one line of its record; an empty
# value takes the key out. The record's time is when the session was last
# active, so it is kept.
session_set() {
    local f="${AGENT_SESSIONS}/$1.session" tmp
    [ -e "$f" ] || return 1
    tmp=$(mktemp "${AGENT_SESSIONS}/.$1.XXXXXX")
    grep -v "^$2=" "$f" > "$tmp" || true
    [ -z "$3" ] || printf '%s=%s\n' "$2" "${3//$'\n'/ }" >> "$tmp"
    touch -r "$f" "$tmp"
    mv "$tmp" "$f"
}

# agent_worktree <session> <folder in the repo>: "main checkout <TAB> worktree".
# A git worktree of its own for the session, so agents working on one
# repository at once never edit each other's files: <main>/.worktrees/<name>,
# on the branch <name> (made from this checkout's HEAD if it is new). Inside
# the main checkout because that is the only place a sandboxed agent can
# have one (see worktree_main), and kept out of `git status` through
# .git/info/exclude, which is yours, not the repository's.
agent_worktree() {
    local s=$1 base=$2 main common wt excl
    common=$(git -C "$base" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
        || die "--worktree needs a git repository, and ${base} is not in one"
    [ "$(basename "$common")" = .git ] || die "--worktree needs a repository with a checkout (${common} is bare)"
    main=$(dirname "$common")
    wt="${main}/.worktrees/${s}"
    if [ -e "$wt" ]; then
        [ "$(worktree_main "$wt" | cut -f1)" = "$main" ] \
            || die "${wt} exists and is not one of this repository's worktrees"
    else
        excl=$(git -C "$main" rev-parse --path-format=absolute --git-path info/exclude)
        mkdir -p "$(dirname "$excl")"
        grep -qxF '/.worktrees/' "$excl" 2>/dev/null || printf '/.worktrees/\n' >> "$excl"
        # one removed by hand (rm -rf) is still registered, and git will not
        # add it again; with the folder gone this only drops that record
        # (and leaves a locked one alone)
        if git -C "$main" worktree list --porcelain | grep -qxF "worktree ${wt}"; then
            git -C "$main" worktree remove "$wt" >&2 \
                || die "git still has ${wt} registered (git worktree list says why; git worktree unlock, then prune, clears it)"
        fi
        if git -C "$main" show-ref --verify --quiet "refs/heads/${s}"; then
            git -C "$main" worktree add --quiet "$wt" "$s" >&2 \
                || die "git could not check out the branch ${s} in ${wt}"
        else
            git -C "$base" worktree add --quiet -b "$s" "$wt" >&2 \
                || die "git could not make the worktree ${wt}"
        fi
        printf 'worktree: %s, on the branch %s\n' "${wt/#"$HOME"/\~}" "$s" >&2
    fi
    printf '%s\t%s\n' "$main" "$wt"
}

# Whether Claude Code (config dir $1) has conversation $2. It writes the file
# at the first message, so an ID handed out and never used is not there yet,
# and --resume on it would fail where --session-id starts it.
claude_has_conversation() {
    local f
    for f in "$1"/projects/*/"$2".jsonl; do
        [ ! -e "$f" ] || return 0
    done
    return 1
}

# agent_tmux_refuse <agent args> -- <flags>: --tmux picks the conversation,
# so the agent's own flags for picking one are refused
agent_tmux_refuse() {
    local -a args=()
    while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
    shift
    local a f
    for a in "${args[@]}"; do
        for f in "$@"; do
            case "$a" in "$f"|"$f"=*) die "--tmux picks the conversation itself; drop ${a} (--new for a fresh one)" ;; esac
        done
    done
}

# agy_conversation <sandbox on|off> <folder>: the conversation agy had last
# in that folder, from its own cache (the sandbox's home when sandboxed)
agy_conversation() {
    local f="${HOME}/.gemini/antigravity-cli/cache/last_conversations.json" c
    [ "$1" != on ] || f="${SANDBOX_HOMES}/agy/.gemini/antigravity-cli/cache/last_conversations.json"
    [ -r "$f" ] && have jq || return 1
    c=$(jq -r --arg d "$2" '.[$d] // empty | strings' "$f" 2>/dev/null) || return 1
    case "$c" in ''|*[!0-9A-Za-z-]*) return 1 ;; esac
    printf '%s\n' "$c"
}

agent_tmux() {
    local tname=$1 name=$2 mode=$3 fresh=$4 dir=$5 worktree=$6
    shift 6
    # not -x: git and the CLI would read it as an option
    case "$tname" in
        ''|-*|*[!A-Za-z0-9_-]*) die "a session name is letters, digits, - and _, and does not start with - (got: '${tname}')" ;;
    esac
    have tmux || die "tmux is not on this system; newer Pulsar images include it (sudo pulsar update)"
    # One start of a name at a time (two Start clicks): the second waits,
    # then finds it running and attaches, so the record and the pane agree.
    # Closed for everything that could outlive this (the tmux server it
    # starts, git) and before attaching.
    local lk
    mkdir -p "$AGENT_SESSIONS"
    exec {lk}>>"${AGENT_SESSIONS}/.${tname}.lock"
    flock -w 60 "$lk" || die "another start of ${tname} is still under way"
    local saved_agent saved_dir id repo base had=0
    [ ! -e "${AGENT_SESSIONS}/${tname}.session" ] || had=1
    base=$(session_get "$tname" base) || base=""
    saved_agent=$(session_get "$tname" agent) || saved_agent=""
    saved_dir=$(session_get "$tname" dir) || saved_dir=""
    id=$(session_get "$tname" id) || id=""
    repo=$(session_get "$tname" repo) || repo=""
    if [ -n "$dir" ]; then
        dir=$(cd "$dir" 2>/dev/null && pwd -P) || die "not a folder: ${dir}"
    fi

    if atmux_running "$tname"; then
        [ "$fresh" = 0 ] || die "${tname} is running; end it first (pulsar agent sessions --kill ${tname})"
        [ -z "$saved_agent" ] || [ "$saved_agent" = "$name" ] \
            || die "${tname} is running ${saved_agent}, not ${name}"
        [ -z "$dir" ] || [ -z "$saved_dir" ] || [ "$dir" = "$saved_dir" ] \
            || die "${tname} is running in ${saved_dir}, not ${dir}"
        [ $# -eq 0 ] || printf 'note: %s is already running; the arguments after -- were not used\n' "$tname" >&2
        exec {lk}>&-
        agent_tmux_attach "$tname"
    fi

    if [ "$worktree" = 1 ] && { [ "$fresh" = 1 ] || [ -z "$saved_dir" ]; }; then
        local wtline
        wtline=$(agent_worktree "$tname" "${dir:-$(pwd -P)}" {lk}>&-) || exit 1
        repo=${wtline%%$'\t'*}; dir=${wtline#*$'\t'}
        saved_dir=$dir
    elif [ "$worktree" = 1 ] && [ -z "$repo" ]; then
        die "${tname} runs in ${saved_dir}, not in a worktree; --new --worktree starts it over in one"
    fi
    if [ "$fresh" = 1 ]; then
        id=""
        [ "$worktree" = 1 ] || repo=""
    else
        [ -z "$saved_agent" ] || [ "$saved_agent" = "$name" ] \
            || die "${tname} was a ${saved_agent} session; --new starts it over with ${name}"
        if [ -n "$saved_dir" ] && [ -n "$dir" ] && [ "$dir" != "$saved_dir" ]; then
            die "${tname}'s conversation is in ${saved_dir}; --new starts a fresh one in ${dir}"
        fi
    fi
    if [ -z "$dir" ]; then
        if [ "$fresh" = 0 ] && [ -n "$saved_dir" ]; then
            [ -d "$saved_dir" ] || [ -z "$repo" ] || die "${tname} ran in the worktree ${saved_dir}, which is gone; --new --worktree makes it again"
            [ -d "$saved_dir" ] || die "${tname} ran in ${saved_dir}, which is gone; --new --dir <path> starts it over"
            dir=$saved_dir
        else
            dir=$(pwd -P)
        fi
    fi
    case "$dir" in *$'\n'*) die "a folder name with a newline in it cannot hold a session" ;; esac

    # A session that ran sandboxed comes back sandboxed, whoever starts it
    # again (attach, Settings, a notification), unless told --no-sandbox.
    # One that ran unsandboxed follows the settings as they are now.
    [ -n "$mode" ] || [ "$(session_get "$tname" sandbox || true)" != on ] || mode=on
    # Decided here, once, so the conversation is looked for in the home the
    # agent will actually use: the sandbox's own, or the real one.
    mode=$(agent_mode "$mode" "$(settings_root "$dir")") || exit 1
    local -a conv=()
    if [ "$name" = claude ]; then
        local a cfg other
        for a in "$@"; do
            case "$a" in
                -c|--continue|-r|--resume|--resume=*|--session-id|--session-id=*|--fork-session)
                    die "--tmux picks the conversation itself; drop ${a} (--new for a fresh one)" ;;
            esac
        done
        if [ "$mode" = on ]; then
            cfg="${SANDBOX_HOMES}/claude/.claude"; other=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
        else
            cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}; other="${SANDBOX_HOMES}/claude/.claude"
        fi
        if [ -n "$id" ] && claude_has_conversation "$cfg" "$id"; then
            conv=(--resume "$id")
        else
            if [ -n "$id" ] && claude_has_conversation "$other" "$id"; then
                printf 'note: %s'"'"'s conversation was %s; this start is %s, so it begins a new one\n' \
                    "$tname" "$([ "$mode" = on ] && echo unsandboxed || echo sandboxed)" \
                    "$([ "$mode" = on ] && echo sandboxed || echo unsandboxed)" >&2
                id=""
            fi
            [ -n "$id" ] || id=$(cat /proc/sys/kernel/random/uuid)
            conv=(--session-id "$id")
        fi
        # Hooks that say "look at me" to the host's tmux (see agent_notify),
        # added beside the user's own settings, never written into them.
        local own=0
        for a in "$@"; do case "$a" in --settings|--settings=*) own=1 ;; esac; done
        if [ "$own" = 1 ]; then
            printf 'note: your --settings replaces the hooks that notify you when %s waits\n' "$tname" >&2
        elif have jq; then
            conv+=(--settings "$(agent_alert_settings "$id")")
        fi
    elif [ "$name" = opencode ]; then
        # opencode takes an ID up front too: it makes the session with it, or
        # resumes the one that has it
        agent_tmux_refuse "$@" -- -c --continue -s --session --fork
        [ -n "$id" ] || id="ses_$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
        conv=(--session "$id")
    elif [ "$name" = agy ]; then
        # agy names its conversation itself; the session learns it while it
        # runs (agent_session_json), else "the last one in this folder"
        agent_tmux_refuse "$@" -- -c --continue --conversation -r --resume
        agy_turn_hook >/dev/null
        if [ "$fresh" = 0 ] && [ "$had" = 1 ]; then
            [ -n "$id" ] || id=$(agy_conversation "$mode" "$dir") || id=""
            if [ -n "$id" ]; then conv=(--conversation "$id"); else conv=(-c); fi
        fi
    elif [ "$name" = codex ]; then
        # codex resumes by ID only from its own picker; --last is the newest
        # conversation in this folder, which a worktree session has to itself
        case "${1:-}" in resume|fork) die "--tmux picks the conversation itself; drop ${1} (--new for a fresh one)" ;; esac
        [ "$fresh" = 1 ] || [ "$had" = 0 ] || conv=(resume --last)
        # its turn-end program rings the pane's bell, as Claude's hooks do;
        # only when the user hasn't one of their own, which this would replace
        local -a bell=()
        mapfile -t bell < <(codex_turn_notify)
        conv=("${bell[@]}" "${conv[@]}")
    elif [ "$fresh" = 0 ] && [ -n "$saved_agent" ]; then
        printf 'note: %s comes back as a new %s conversation; %s cannot resume the one it had\n' \
            "$tname" "$name" "$name" >&2
    fi
    # what to start on: a new session's first message, sent as it starts
    local -a ask=()
    if [ -n "${AGENT_RUN_PROMPT:-}" ]; then
        if [ "$fresh" = 0 ] && [ "$had" = 1 ]; then
            printf 'note: %s picks up where it was, so --prompt was not sent; type it in the session\n' "$tname" >&2
        else
            # each agent's own way, as agent ask hands one over (AGENTS_TABLE)
            agent_row "$name"
            case "$A_PROMPT" in
                arg) ask=("$AGENT_RUN_PROMPT") ;;
                prompt) ask=(--prompt "$AGENT_RUN_PROMPT") ;;
                i) ask=(-i "$AGENT_RUN_PROMPT") ;;
                *) printf 'note: %s takes no first message from Pulsar; type it in the session\n' "$name" >&2 ;;
            esac
        fi
    fi
    # The files before the agent can touch them. A start that begins the
    # session (the first, or --new) is what undo goes back to; a restart of
    # it (reboot, attach) is a snapshot too, but never moves that.
    local newbase=0
    [ "$fresh" = 0 ] && [ "$had" = 1 ] || newbase=1
    undo_snapshot_start "$tname" "$dir" "$newbase" "$base" {lk}>&-

    # private: what an agent leaves here may be anything of the user's
    ( umask 077; mkdir -p "${AGENT_SCRATCH}/${tname}" ) 2>/dev/null || true
    local cli flag=--no-sandbox
    cli=$(realpath "$SELF")
    [ "$mode" = off ] || flag=--sandbox
    local argv; argv=$(umask 077; mktemp "${AGENT_SESSIONS}/.${tname}.argv.XXXXXX") || die "could not start ${tname}"
    printf '%s\0' "$cli" agent run "$name" "$flag" -- "${conv[@]}" "$@" "${ask[@]}" > "$argv"
    if ! atmux new-session -d -s "$tname" -c "$dir" -x "$(tput cols 2>/dev/null || echo 80)" -y "$(tput lines 2>/dev/null || echo 24)" \
        -e "PULSAR_SESSION_RECORD=${AGENT_SESSIONS}/${tname}.session" \
        -e "PULSAR_SCRATCH=${AGENT_SCRATCH}/${tname}" \
        -e "PULSAR_PANE_ARGV=${argv}" \
        -- bash -c "$AGENT_TMUX_PANE" "$name" {lk}>&-; then
        rm -f "$argv"
        [ -z "$UNDO_SNAP_REF" ] || git -C "$UNDO_SNAP_TOP" update-ref -d "$UNDO_SNAP_REF"
        die "tmux could not start ${tname}"
    fi
    # Only now that it runs: a start that failed leaves the record, and the
    # conversation it points to, as they were.
    session_put "$tname" "$name" "$dir" "$id" "$mode" "$repo" "$UNDO_SNAP_BASE"
    # a new agy conversation: agy names it, and until its cache says so the
    # cache still names the folder's last one, which isn't this session's
    # (agent_session_json waits for the cache to move past it)
    if [ "$name" = agy ] && [ -z "$id" ]; then
        session_set "$tname" agy_before "$(agy_conversation "$mode" "$dir" || echo none)"
    fi
    # A bell in any agent's session is the agent asking for you; the notice
    # goes away once you look. Set on every start: the CLI's path can move.
    # Quoted twice: for the shell run-shell starts, then for tmux, whose own
    # parser reads this string; ## is a # its formats leave alone.
    agent_tmux_hooks "$cli"
    exec {lk}>&-
    agent_tmux_attach "$tname"
}

# Onto the session: switch to it from inside the agents' server, attach from
# anywhere else (inside another tmux too: nested, which is what was asked).
# Without a terminal it stays running, detached.
agent_tmux_attach() {
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        printf '%s is running; attach with: pulsar agent attach %s\n' "$1" "$1"
        exit 0
    fi
    if [ "${PULSAR_AGENT_VIEW:-0}" = 1 ]; then
        atmux_view "$1" || die "tmux could not open ${1}"
    fi
    # this server's hooks as this CLI sets them (one started by an older one)
    agent_tmux_hooks "$(realpath "$SELF")" 2>/dev/null || true
    atmux_argv
    case "${TMUX:-}" in
        */"$AGENT_TMUX_SOCKET",*) exec "${ATMUX[@]}" switch-client -t "=$1" ;;
    esac
    unset TMUX
    exec "${ATMUX[@]}" attach-session -t "=$1"
}

# agent attach -- back onto a session, as `tmux attach` is: by name, or the
# running one you were on last. An ended session starts again from its
# record: its agent, its folder, its conversation, its sandbox.
agent_attach() {
    local usage="usage: pulsar agent attach [<session>]" s="" agent
    case "${1:-}" in
        -h|--help) printf '%s\n' "$usage"; return 0 ;;
        -*) die "$usage" ;;
    esac
    [ $# -le 1 ] || die "$usage"
    s=${1:-}
    if [ -z "$s" ]; then
        have tmux || die "no agent session is running"
        # last attached first; never-attached ones by when they started
        s=$(atmux list-sessions -F $'#{session_last_attached}\t#{session_created}\t#{session_name}' 2>/dev/null \
            | awk -F'\t' '$3 !~ /~/' \
            | sort -t $'\t' -k1,1nr -k2,2nr | head -n 1 | cut -f3) || s=""
        [ -n "$s" ] || die "no agent session is running; pulsar agent sessions lists the ended ones, and pulsar agent attach <name> brings one back"
    fi
    case "$s" in *[!A-Za-z0-9_-]*) die "not a session name: '${s}'" ;; esac
    if have tmux && atmux_running "$s"; then
        agent_tmux_attach "$s"
    fi
    agent=$(session_get "$s" agent) || die "no session called ${s} (pulsar agent sessions lists them)"
    agent_row "$agent" || die "${s} ran ${agent}, which Pulsar no longer knows"
    agent_tmux "$s" "$agent" "" 0 "" 0
}

# Archived sessions older than this many days are forgotten by --tidy (the
# Agents app runs it at each start). --forget's rules hold: a worktree with
# work in it stays, and so does every branch.
SESSION_TIDY_DAYS=${PULSAR_SESSION_TIDY_DAYS:-7}

agent_sessions_tidy() {
    local days=$1 now f n at running out
    local -a gone=()
    now=$(date +%s)
    for f in "$AGENT_SESSIONS"/*.session; do
        [ -e "$f" ] || continue
        n=$(basename "$f" .session)
        at=$(session_get "$n" archived) || continue
        case "$at" in ''|*[!0-9]*) continue ;; esac
        [ $(( now - at )) -ge $(( days * 86400 )) ] || continue
        running=0
        have tmux && atmux_running "$n" && running=1
        [ "$running" = 0 ] || continue
        out=$(JSON=1 agent_sessions --forget "$n") || continue
        gone+=("$out")
    done
    if [ "${JSON:-0}" = 1 ]; then
        need jq
        printf '%s\n' "${gone[@]}" | jq -cs .
        return 0
    fi
    local g
    for g in "${gone[@]}"; do
        jq -r '"forgot \(.name)" + (if .worktree == "kept" then "; kept its worktree \(.dir) (git worktree remove said: \(.reason))" else "" end)' <<<"$g"
    done
}

agent_sessions() {
    local usage="usage: pulsar agent sessions [--kill|--forget|--archive|--unarchive <name> | --title <name> <text> | --tidy [--days <n>]] [--json]"
    case "${1:-}" in
        -h|--help) printf '%s\n' "$usage"; return 0 ;;
        --kill|--forget|--archive|--unarchive)
            [ $# -eq 2 ] || die "$usage"
            case "$2" in ''|*[!A-Za-z0-9_-]*) die "not a session name: '$2'" ;; esac ;;
        --title)
            [ $# -eq 3 ] || die "$usage"
            case "$2" in ''|*[!A-Za-z0-9_-]*) die "not a session name: '$2'" ;; esac ;;
        --tidy)
            case "$#:${2:-}" in
                1:) ;;
                3:--days) case "$3" in ''|*[!0-9]*) die "--days wants a number of days" ;; esac ;;
                *) die "$usage" ;;
            esac
            agent_sessions_tidy "${3:-$SESSION_TIDY_DAYS}"
            return ;;
        "") [ $# -eq 0 ] || die "$usage" ;;
        *) die "$usage" ;;
    esac
    local running=0
    have tmux && atmux_running "${2:-}" && running=1
    case "${1:-}" in
        --archive)
            [ -e "${AGENT_SESSIONS}/$2.session" ] || die "no session called $2"
            # an archived session is one that is done with: it stops
            [ "$running" = 0 ] || atmux_end "$2"
            local at; at=$(date +%s)
            session_set "$2" archived "$at"
            if [ "${JSON:-0}" = 1 ]; then
                need jq; jq -nc --arg n "$2" --argjson a "$at" '{name: $n, archived: $a}'
            else
                printf 'archived %s%s; its files, worktree and undo snapshots stay (pulsar agent sessions --unarchive %s)\n' \
                    "$2" "$([ "$running" = 1 ] && echo ' and ended it')" "$2"
            fi
            return 0 ;;
        --unarchive)
            [ -e "${AGENT_SESSIONS}/$2.session" ] || die "no session called $2"
            session_set "$2" archived ""
            if [ "${JSON:-0}" = 1 ]; then
                need jq; jq -nc --arg n "$2" '{name: $n, archived: null}'
            else
                printf 'unarchived %s\n' "$2"
            fi
            return 0 ;;
        --title)
            [ -e "${AGENT_SESSIONS}/$2.session" ] || die "no session called $2"
            no_json "agent sessions --title"
            # a new name is a new face: the app draws the session's icon from
            # this seed when there is one (else from its name)
            local was; was=$(session_get "$2" title) || was=""
            session_set "$2" title "$3"
            if [ "$(session_get "$2" title || true)" != "$was" ]; then
                session_set "$2" icon "${2}:$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
            fi
            if [ -n "$3" ]; then printf '%s is titled: %s\n' "$2" "$(session_get "$2" title)"
            else printf '%s has no title\n' "$2"; fi
            return 0 ;;
        --kill)
            [ "$running" = 1 ] || die "$2 is not running"
            atmux_end "$2"
            if [ "$(session_get "$2" agent || true)" = claude ]; then
                printf 'ended %s; pulsar agent attach %s brings it back on the same conversation\n' "$2" "$2"
            else
                printf 'ended %s; pulsar agent attach %s starts it again\n' "$2" "$2"
            fi
            return 0 ;;
        --forget)
            [ "$running" = 0 ] || die "$2 is running; end it first (pulsar agent sessions --kill $2)"
            [ -e "${AGENT_SESSIONS}/$2.session" ] || die "no session called $2"
            local repo dir top="" r snaps=none wt=none why=""
            repo=$(session_get "$2" repo) || repo=""
            dir=$(session_get "$2" dir) || dir=""
            # the snapshots, so a later session of this name starts clean;
            # a worktree's are in its repository's refs, gone folder or not
            if [ -d "$dir" ] && top=$(undo_top "$dir"); then :
            elif [ -n "$repo" ] && [ -d "$repo" ] && top=$(undo_top "$repo"); then :
            else top=""; fi
            if [ -n "$top" ]; then
                while IFS= read -r r; do git -C "$top" update-ref -d "$r"; done \
                    < <(git -C "$top" for-each-ref --format='%(refname)' "refs/pulsar/undo/$2/" "refs/pulsar/undone/$2/")
                snaps=dropped
            elif [ -n "$dir" ] && [ ! -d "$dir" ]; then
                snaps=left
            fi
            if [ -n "$repo" ] && [ -d "$dir" ]; then
                # never forced: what is in it might be the only copy. git's
                # own refusal is the reason, so it is passed on as it is.
                if why=$(git -C "$repo" worktree remove "$dir" 2>&1); then
                    wt=removed; why=""
                else
                    wt=kept
                    why=$(printf '%s\n' "$why" | sed '/^[[:space:]]*$/d' | paste -sd ';' - | sed 's/;/; /g')
                fi
            fi
            rm -f "${AGENT_SESSIONS}/$2.session"
            # its scratch folder: made for leftovers, so it goes whole
            local scratch="${AGENT_SCRATCH}/$2" freed=0
            if [ -d "$scratch" ]; then
                freed=$(du -sb "$scratch" 2>/dev/null | cut -f1) || freed=0
                rm -rf -- "$scratch"
            fi
            # --json: what was left behind, for Pulsar Settings to say so
            # (snapshots: dropped|left|none, worktree: removed|kept|none)
            if [ "${JSON:-0}" = 1 ]; then
                need jq
                jq -n -c --arg n "$2" --arg s "$snaps" --arg w "$wt" --arg d "$dir" --arg r "$why" \
                    --argjson f "${freed:-0}" \
                    '{name: $n, snapshots: $s, worktree: $w, dir: $d, reason: $r, scratch_freed: $f}'
                return 0
            fi
            [ "${freed:-0}" -eq 0 ] || printf 'deleted its scratch folder (%s)\n' "$(human_bytes "$freed")"
            [ "$snaps" != left ] || printf 'note: %s is gone, so its undo snapshots could not be dropped; if it was in a git repository, git for-each-ref refs/pulsar/undo/%s/ refs/pulsar/undone/%s/ there lists them (git update-ref -d each)\n' \
                "${dir/#"$HOME"/\~}" "$2" "$2"
            case "$wt" in
                removed) printf 'removed the worktree %s; the branch %s stays\n' "${dir/#"$HOME"/\~}" "$2" ;;
                kept)    if [ -n "$why" ]; then
                             printf 'kept the worktree %s; git worktree remove said: %s\n' "${dir/#"$HOME"/\~}" "$why"
                         else
                             printf 'kept the worktree %s; git worktree remove failed and gave no reason\n' "${dir/#"$HOME"/\~}"
                         fi ;;
            esac
            printf 'forgot %s (the agent'"'"'s own history is not touched)\n' "$2"
            return 0 ;;
    esac
    local live="" names n f row
    ! have tmux || live=$(atmux list-sessions -F $'#{session_name}\t#{session_created}\t#{session_activity}\t#{?@pulsar-alert,#{@pulsar-alert},-}\t#{?@pulsar-exited,#{@pulsar-exited},-}' 2>/dev/null \
        | awk -F'\t' '$1 !~ /~/') || live=""
    # a Codex or agy session's "waiting" as it stands (alert_now)
    local ln lc la lal le
    live=$(while IFS=$'\t' read -r ln lc la lal le; do
               [ -n "$ln" ] || continue
               if [ "$lal" != - ]; then lal=$(alert_now "$ln"); lal=${lal:--}; fi
               printf '%s\t%s\t%s\t%s\t%s\n' "$ln" "$lc" "$la" "$lal" "$le"
           done <<<"$live")
    names=$( { cut -f1 <<<"$live"
               for f in "$AGENT_SESSIONS"/*.session; do
                   [ ! -e "$f" ] || basename "$f" .session
               done; } | sed '/^$/d' | sort -u)
    if [ "${JSON:-0}" = 1 ]; then
        need jq
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            row=$(awk -F'\t' -v n="$n" '$1 == n' <<<"$live")
            agent_session_json "$n" "$row"
        done <<<"$names" | jq -s '.'
        return 0
    fi
    if [ -z "$names" ]; then
        printf 'no agent sessions  (pulsar agent run <name> --tmux <session>)\n'
        return 0
    fi
    local state since ctx agent dir u now
    now=$(date +%s)
    printf '%-16s %-9s %-8s %-8s %-8s %s\n' NAME AGENT STATE SINCE CONTEXT FOLDER
    while IFS= read -r n; do
        row=$(awk -F'\t' -v n="$n" '$1 == n' <<<"$live")
        agent=$(session_get "$n" agent) || agent=-
        dir=$(session_get "$n" dir) || dir=-
        state=ended; since=-; ctx=-
        if [ -n "$row" ]; then
            IFS=$'\t' read -r _ since _ state _ <<<"$row"
            since=$(human_age $(( now - since )))
            case "$state" in ""|-) state=running ;; *) state=waiting ;; esac
        fi
        if [ "$agent" = claude ] && u=$(session_usage "$n"); then
            ctx=$(jq -r '.context' <<<"$u" | human_tokens)
        fi
        printf '%-16s %-9s %-8s %-8s %-8s %s\n' "$n" "$agent" "$state" "$since" "$ctx" "${dir/#"$HOME"/\~}"
    done <<<"$names"
}

# ---------------------------------------------------------------------------
# agent usage -- what a session's conversation has cost in tokens, read from
# the agent's own transcript (Claude Code only: the one whose conversation a
# session can name). A message is written once per content block, all with
# the same usage, so each counts once (by its id, taking the largest output
# seen), and the subagents' own transcripts count too.
#
# No money: on a subscription there is no per-token price, and a price
# table in the OS would be wrong the day prices move.
# ---------------------------------------------------------------------------

# session_usage <session> -> one JSON object, or fail when there is nothing
session_usage() {
    local s=$1 id f="" c t
    [ "$(session_get "$s" agent 2>/dev/null)" = claude ] || return 1
    id=$(session_get "$s" id) || return 1
    [ -n "$id" ] || return 1
    have jq || return 1
    for c in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "${SANDBOX_HOMES}/claude/.claude"; do
        for t in "$c"/projects/*/"${id}.jsonl"; do
            [ -f "$t" ] || continue
            if [ -z "$f" ] || [ "$t" -nt "$f" ]; then f=$t; fi
        done
    done
    [ -n "$f" ] || return 1
    local -a files=("$f")
    for t in "${f%.jsonl}"/subagents/*.jsonl; do [ ! -f "$t" ] || files+=("$t"); done
    # An API error is written as an assistant message of the model
    # "<synthetic>", with no usage: no request, no model, no context.
    jq -c 'select(.type == "assistant" and .message.usage != null and .message.id != null
                  and .message.model != "<synthetic>")
           | .message.usage as $u
           | [.message.id, (.isSidechain // false), (.message.model // ""), (.timestamp // ""),
              ($u.input_tokens // 0), ($u.cache_creation_input_tokens // 0),
              ($u.cache_read_input_tokens // 0), ($u.output_tokens // 0)]' "${files[@]}" 2>/dev/null \
    | jq -s -c 'reduce .[] as $r ({}; .[$r[0]] = (if .[$r[0]] == null or $r[7] > .[$r[0]][7] then $r else .[$r[0]] end))
        | [.[]] as $m
        | if ($m | length) == 0 then null else
          ([$m[] | select(.[1] | not)] | max_by(.[3])) as $last
          | {model: ($last[2] // ""),
             requests: ([$m[] | select(.[1] | not)] | length),
             subagent_requests: ([$m[] | select(.[1])] | length),
             context: (if $last then $last[4] + $last[5] + $last[6] else 0 end),
             read: ([$m[] | .[4] + .[5] + .[6]] | add),
             read_cached: ([$m[] | .[6]] | add),
             written: ([$m[] | .[7]] | add)}
          end' | grep -v '^null$'
}

agent_usage() {
    local s=${1:-}
    case "$s" in ''|*[!A-Za-z0-9_-]*) die "usage: pulsar agent usage <session> [--json]" ;; esac
    [ $# -eq 1 ] || die "usage: pulsar agent usage <session> [--json]"
    need jq
    local agent u
    agent=$(session_get "$s" agent) || die "no session called ${s} (pulsar agent sessions)"
    [ "$agent" = claude ] || die "${s} runs ${agent}; usage is read from Claude Code's transcripts only"
    u=$(session_usage "$s") || die "${s} has no conversation on disk yet"
    if [ "${JSON:-0}" = 1 ]; then printf '%s\n' "$u"; return 0; fi
    printf '%s  %s\n' "$s" "$(jq -r .model <<<"$u")"
    printf '  context now  %s tokens\n' "$(jq -r .context <<<"$u" | human_tokens)"
    printf '  requests     %s' "$(jq -r .requests <<<"$u")"
    [ "$(jq -r .subagent_requests <<<"$u")" = 0 ] || printf ', and %s by subagents' "$(jq -r .subagent_requests <<<"$u")"
    printf '\n  read         %s tokens (%s of them from the cache)\n' \
        "$(jq -r .read <<<"$u" | human_tokens)" "$(jq -r .read_cached <<<"$u" | human_tokens)"
    printf '  written      %s tokens\n' "$(jq -r .written <<<"$u" | human_tokens)"
}

# one session, as `agent sessions --json` lists it. $2: its tmux row, if live
agent_session_json() {
    local n=$1 row=$2 created="" activity="" alert="" exited="" top="" snaps=0 u
    # a field tmux has no value for comes as -: read merges empty tab fields
    [ -z "$row" ] || IFS=$'\t' read -r _ created activity alert exited <<<"$row"
    [ "$alert" != - ] || alert=""
    [ "$exited" != - ] || exited=""
    local dir repo agent conv project="" last=""
    dir=$(session_get "$n" dir) || dir=""
    repo=$(session_get "$n" repo) || repo=""
    agent=$(session_get "$n" agent) || agent=""
    conv=$(session_get "$n" id) || conv=""
    if [ -d "$dir" ] && top=$(undo_top "$dir"); then
        snaps=$(git -C "$top" for-each-ref --format=x "refs/pulsar/undo/${n}/" | wc -l)
    fi
    # the project it belongs to: a worktree's repository, else its checkout
    project=${repo:-${top:-$dir}}
    # agy names its conversation itself; while this session runs it is the
    # last one in its folder, so that is the one to resume. Not while the
    # folder's cache still names the one it had before a fresh start: agy
    # hasn't written its new one there yet.
    if [ "$agent" = agy ] && [ -z "$conv" ] && [ -n "$row" ] && [ -n "$dir" ] \
        && conv=$(agy_conversation "$(session_get "$n" sandbox || echo off)" "$dir"); then
        if [ "$conv" = "$(session_get "$n" agy_before || true)" ]; then
            conv=""
        else
            session_set "$n" id "$conv"
            session_set "$n" agy_before ""
        fi
    fi
    if [ -n "$row" ]; then last=${activity:-$created}
    elif [ -e "${AGENT_SESSIONS}/${n}.session" ]; then last=$(stat -c %Y "${AGENT_SESSIONS}/${n}.session"); fi
    u=$(session_usage "$n") || u=null
    jq -n -c --arg name "$n" --arg agent "$agent" --arg dir "$dir" \
        --arg conv "$conv" --arg repo "$repo" \
        --arg live "$([ -n "$row" ] && echo 1)" --arg created "$created" --arg alert "$alert" \
        --arg archived "$(session_get "$n" archived || true)" --arg title "$(session_get "$n" title || true)" \
        --arg last "$last" --arg project "$project" --arg exited "$exited" \
        --arg sandbox "$(session_get "$n" sandbox || true)" --arg icon "$(session_get "$n" icon || true)" \
        --argjson snaps "$snaps" --argjson usage "$u" \
        'def num: if . == "" then null else tonumber end;
         def str: if . == "" then null else . end;
         {name: $name, agent: ($agent | str),
          state: (if $live == "" then "ended" elif $alert != "" then "waiting" else "running" end),
          waiting_for: ($alert | str),
          started: ($created | num),
          dir: ($dir | str),
          worktree_of: ($repo | str),
          conversation: ($conv | str),
          snapshots: $snaps, usage: $usage,
          archived: ($archived | num), title: ($title | str),
          last_active: ($last | num), project: ($project | str),
          exited: (if $live == "" then null else ($exited | num) end),
          sandbox: ($sandbox | str), icon: ($icon | str)}'
}
