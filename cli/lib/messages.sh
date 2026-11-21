# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): sessions reading and messaging each other: send, inbox, mail, the log.

# ---------------------------------------------------------------------------
# agent read / send / whoami -- one session looking at, and talking to,
# another. What an agent reads is the session's screen, scrollback included:
# every agent has one, and it is what the user sees. What it sends goes into
# the other agent's prompt, labelled as from another session, between that
# agent's turns, never while someone is looking at it (it would land in the
# middle of what they're typing): it waits in <name>.inbox until the next
# turn end without a watcher (agent notify), or `agent send --now`.
# Every message is logged; one session may send another 10 in 10 minutes
# (message_cap in agent.conf), and messages = off stops them.
# ---------------------------------------------------------------------------
MSG_LOG="${AGENT_SESSIONS}/messages.log"
# The message log as JSON lines, one a line, a damaged line left out (an
# interrupted append mustn't stop the cap or blank every inbox).
msg_log_json() {
    [ -f "$MSG_LOG" ] || return 0
    jq -c -R 'fromjson? // empty | select(type == "object")' "$MSG_LOG"
}
# kept to the last 10000 messages once it passes 20000
msg_log_trim() {
    [ -f "$MSG_LOG" ] && [ "$(wc -l < "$MSG_LOG")" -gt 20000 ] || return 0
    tail -n 10000 "$MSG_LOG" > "${MSG_LOG}.tmp" && mv -f "${MSG_LOG}.tmp" "$MSG_LOG"
}

# agent.conf: messages = on|off, message_cap = N (Agents > Preferences)
agent_conf_get() {
    [ -r "$AGENT_CONF" ] || return 1
    awk -F' *= *' -v k="$1" '$1 == k { v = $2 } END { if (v == "") exit 1; print v }' "$AGENT_CONF"
}
msg_cap() {
    local c=${PULSAR_MSG_CAP:-}
    [ -n "$c" ] || c=$(agent_conf_get message_cap) || c=10
    case "$c" in ''|*[!0-9]*|0) c=10 ;; esac
    printf '%s\n' "$c"
}

# pulsar agent messages [on|off] [--cap N]: whether sessions may message each
# other, and how many in 10 minutes from one to another.
agent_messages() {
    local usage="usage: pulsar agent messages [on|off] [--cap N]" onoff="" cap=""
    while [ $# -gt 0 ]; do
        case "$1" in
            on|off) onoff=$1 ;;
            --cap) [ $# -ge 2 ] || die "$usage"; cap=$2; shift ;;
            -h|--help) printf '%s\n' "$usage"; return 0 ;;
            *) die "$usage" ;;
        esac
        shift
    done
    case "$cap" in '') ;; *[!0-9]*|0) die "--cap is a number from 1" ;; esac
    [ -z "$onoff" ] || setting_write messages "$onoff" 0 ""
    [ -z "$cap" ] || setting_write message_cap "$cap" 0 ""
    local now; now=$(agent_conf_get messages) || now=on
    if [ "${JSON:-0}" = 1 ]; then
        jq -n -c --arg m "$now" --argjson c "$(msg_cap)" '{messages: $m, message_cap: $c}'
    else
        printf 'messages between sessions: %s, at most %s from one to another in 10 minutes\n' "$now" "$(msg_cap)"
    fi
}

# What the Agents app's Preferences show: the default agent, the installed
# ones, the global sandbox and push settings, and messages.
agent_settings() {
    [ $# -eq 0 ] || die "usage: pulsar agent settings"
    need jq
    local def inst sb push msgs n
    def=$(agent_default_name 2>/dev/null) || def=""
    inst=""
    while IFS=$'\t' read -r n _; do agent_command "$n" >/dev/null && inst+="${inst:+ }${n}"; done < <(agent_rows)
    sb=$(setting_resolve sandbox ""); sb=${sb%%$'\t'*}
    push=$(setting_resolve push ""); push=${push%%$'\t'*}
    msgs=$(agent_conf_get messages) || msgs=on
    if [ "${JSON:-0}" = 1 ]; then
        jq -n -c --arg d "$def" --arg i "$inst" --arg s "$sb" --arg p "$push" --arg m "$msgs" --argjson c "$(msg_cap)" \
            '{default: (if $d == "" then null else $d end), installed: ($i | split(" ") | map(select(. != ""))),
              sandbox: $s, push: $p, messages: $m, message_cap: $c}'
    else
        printf 'default   %s\ninstalled %s\nsandbox   %s\npush      %s\nmessages  %s, at most %s in 10 minutes\n' \
            "${def:-none}" "${inst:-none}" "$sb" "$push" "$msgs" "$(msg_cap)"
    fi
}

agent_read() {
    local usage="usage: pulsar agent read <session> [--lines N] [--json]" n="" lines=80
    while [ $# -gt 0 ]; do
        case "$1" in
            --lines) [ $# -ge 2 ] || die "$usage"; lines=$2; shift ;;
            -h|--help) printf '%s\n' "$usage"; return 0 ;;
            -*) die "$usage" ;;
            *) [ -z "$n" ] || die "$usage"; n=$1 ;;
        esac
        shift
    done
    case "$n" in ''|*[!A-Za-z0-9_-]*) die "$usage" ;; esac
    case "$lines" in ''|*[!0-9]*) die "--lines wants a number" ;; esac
    [ "$lines" -le 2000 ] || lines=2000
    { have tmux && atmux_running "$n"; } || die "$n is not running (pulsar agent sessions)"
    local text
    text=$(atmux capture-pane -p -J -S "-${lines}" -t "=${n}:" 2>/dev/null | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}') \
        || die "could not read $n"
    if [ "${JSON:-0}" = 1 ]; then
        need jq
        jq -n -c --arg n "$n" --arg a "$(session_get "$n" agent || true)" --arg t "$text" \
            '{name: $n, agent: (if $a == "" then null else $a end), text: $t}'
    else
        printf '%s\n' "$text"
    fi
}

# Which session this is, for an agent (or its MCP server) asking: the pane's
# own record, else the tmux pane whose process this descends from.
agent_whoami() {
    local p pid name
    if [ -n "${PULSAR_SESSION_RECORD:-}" ]; then
        name=$(basename "$PULSAR_SESSION_RECORD" .session)
    elif have tmux; then
        local panes; panes=$(atmux list-panes -a -F '#{pane_pid} #{session_name}' 2>/dev/null | awk '$2 !~ /~/') || panes=""
        pid=$PPID
        while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
            name=$(awk -v p="$pid" '$1 == p { print $2; exit }' <<<"$panes")
            [ -z "$name" ] || break
            p=$(awk '/^PPid:/ { print $2 }' "/proc/${pid}/status" 2>/dev/null) || p=""
            pid=$p
        done
    fi
    [ -n "${name:-}" ] || die "not in an agent session"
    if [ "${JSON:-0}" = 1 ]; then jq -n -c --arg n "$name" '{name: $n}'; else printf '%s\n' "$name"; fi
}

agent_send() {
    local usage="usage: pulsar agent send <session> [--from <session>] [--reply-to <id>] [--now] <text>"
    local to="" from="" now=0 text="" re="" job=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --from) [ $# -ge 2 ] || die "$usage"; from=$2; shift ;;
            # Pulsar's own notice that a job ended (job done), labelled so
            --job) [ $# -ge 2 ] || die "$usage"; job=$2; shift ;;
            --now) now=1 ;;
            --reply-to) [ $# -ge 2 ] || die "$usage"; re=$2; shift ;;
            -h|--help) printf '%s\n' "$usage"; return 0 ;;
            --) shift; text="$*"; break ;;
            *) if [ -z "$to" ]; then to=$1; else text="$*"; break; fi ;;
        esac
        shift
    done
    # <session>@<machine>: to a session on another of your machines, through
    # that machine's own `agent send` (its inbox, its rules, its cap); from
    # <you>@<this machine's name>, so it says where it came from
    if [[ "$to" == *@* ]]; then
        local rname=${to%@*} rm=${to##*@}
        case "$rname" in ''|*[!A-Za-z0-9_-]*) die "$usage" ;; esac
        case "$rm" in ''|*[!a-z0-9-]*) die "$usage" ;; esac
        case "$from" in *[!A-Za-z0-9_-]*) die "--from is a session's name here" ;; esac
        [ -n "${text//[[:space:]]/}" ] || die "$usage"
        if [ "$(agent_conf_get messages || true)" = off ]; then
            die "messages between sessions are off (Agents > Preferences, or pulsar agent messages on)"
        fi
        local here; here=$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-\n' '-') || here=""
        local -a fwd=(agent send "$rname")
        [ -z "$from" ] || fwd+=(--from "${from}@${here:-here}")
        [ "$now" = 0 ] || fwd+=(--now)
        [ -z "$re" ] || fwd+=(--reply-to "$re")
        need jq
        mkdir -p "$AGENT_SESSIONS"
        jq -n -c --arg f "$from" --arg t "$to" --arg x "$text" --argjson a "$(date +%s)" \
            '{at: $a, from: $f, to: $t, text: $x}' >> "$MSG_LOG"
        cmd_machine exec "$rm" -- "${fwd[@]}" -- "$text"
        return
    fi
    case "$to" in ''|*[!A-Za-z0-9_-]*) die "$usage" ;; esac
    # from another machine's session it reads <session>@<machine>
    case "$from" in *@*@*|@*|*@) die "--from is a session's name" ;; esac
    case "$from" in *[!A-Za-z0-9_@-]*) die "--from is a session's name" ;; esac
    [ -n "${text//[[:space:]]/}" ] || die "$usage"
    [ "$from" != "$to" ] || die "a session can't message itself"
    { have tmux && atmux_running "$to"; } || die "$to is not running (pulsar agent sessions)"
    # A sandboxed session's turn ends are told by files in the sandbox's
    # home, which every sandboxed session can write: Pulsar can't tell when
    # it's safe to type into one, so it doesn't take messages (yet).
    [ "$(session_get "$to" sandbox || true)" != on ] || die "${to} is sandboxed: sandboxed sessions don't take messages yet"
    # only agents whose turn ends Pulsar can tell (Claude's Stop, the
    # turn-end hooks it gives Codex and agy): another would be typed into blind
    case "$(session_get "$to" agent || true)" in
        claude|codex|agy) ;;
        *) die "${to} runs $(session_get "$to" agent || echo "an agent Pulsar can't follow"): only Claude Code, Codex and Antigravity CLI sessions take messages" ;;
    esac
    case "$job" in ''|[A-Za-z0-9_]*) ;; *) die "--job is a job's name" ;; esac
    case "$job" in *[!A-Za-z0-9_-]*) die "--job is a job's name" ;; esac
    need jq
    mkdir -p "$AGENT_SESSIONS"
    # one message at a time into a session's queue (sends, deliveries and
    # hooks run at once): the lock goes with this process
    exec {lockfd}>"${AGENT_SESSIONS}/${to}.lock"
    flock -w 10 "$lockfd" || die "${to}'s messages are busy; try again"
    local at; at=$(date +%s)
    # the switch and the cap hold for every sender, named or not; Pulsar's
    # own job notices are one per job and only to the session that asked
    if [ -z "$job" ] && [ "$(agent_conf_get messages || true)" = off ]; then
        die "messages between sessions are off (Agents > Preferences, or pulsar agent messages on)"
    fi
    local log; log=$(msg_log_json) || die "could not read the message log ${MSG_LOG}"
    if [ -z "$job" ]; then
        local cap recent; cap=$(msg_cap)
        recent=$(jq -s --arg f "$from" --arg t "$to" --argjson since $((at - 600)) \
            '[.[] | select(.from == $f and .to == $t and .job == null and .at >= $since)] | length' <<<"$log") \
            || die "could not read the message log ${MSG_LOG}"
        [ "$recent" -lt "$cap" ] || die "${from:-a sender that gave no name} has sent ${to} ${recent} messages in 10 minutes; that's the limit (a loop?)"
    fi
    if [ -n "$re" ]; then
        [[ "$re" =~ ^m[0-9]+-[0-9a-f]+$ ]] || die "--reply-to is a message's id (pulsar agent inbox)"
        jq -e -s --arg r "$re" 'any(.[]; .id == $r)' <<<"$log" >/dev/null || die "no message ${re} (pulsar agent inbox)"
    fi
    local id; id=$(printf 'm%s-%04x' "$at" "$((RANDOM % 65536))")
    local line
    line=$(jq -n -c --arg i "$id" --arg f "$from" --arg t "$to" --arg x "$text" --argjson a "$at" --arg r "$re" --arg j "$job" \
        '{id: $i, at: $a, from: $f, to: $t, text: $x} + (if $r == "" then {} else {re: $r} end)
         + (if $j == "" then {} else {job: $j} end)')
    printf '%s\n' "$line" >> "$MSG_LOG"
    printf '%s\n' "$line" >> "${AGENT_SESSIONS}/${to}.inbox"
    msg_log_trim
    if [ "$now" = 0 ] && [ "$(session_get "$to" agent || true)" = claude ] && mail_paths "$to" >/dev/null; then
        # Claude: its mail waiter takes it between turns, nothing typed
        agent_mail_render "$to"
        if mail_wait "$to"; then
            printf 'delivered to %s (%s)\n' "$to" "$id"; return 0
        fi
    fi
    # typed only at a turn's end: never into a permission question or a
    # pane mid-turn, --now or not; --now only goes ahead while you watch
    if at_prompt "$(alert_now "$to")" && { [ "$now" = 1 ] || ! atmux_watched "$to"; }; then
        # typed instead: take the mail back first, so it can't go twice
        mail_cancel "$to"
        agent_deliver "$to" && { printf 'delivered to %s (%s)\n' "$to" "$id"; return 0; }
    fi
    agent_mail_render "$to"
    printf 'queued for %s (%s): it goes in at the end of its turn, or when nobody is watching it\n' "$to" "$id"
}

# What waits in a session's inbox, into its prompt as one message, then Enter.
agent_deliver() {
    local to=$1 inbox="${AGENT_SESSIONS}/${1}.inbox" text
    [ -s "$inbox" ] || return 1
    # its agent exited: the pane is a shell now, where the text would run
    [ -z "$(atmux display -p -t "=${to}:" '#{@pulsar-exited}' 2>/dev/null)" ] || return 1
    # typed: the mail is taken back first, so a hook can't give it again
    mail_cancel "$to"
    text=$(inbox_text "$inbox") || return 1
    printf '%s' "$text" | atmux load-buffer -b pulsar-message - || return 1
    atmux paste-buffer -p -d -b pulsar-message -t "=${to}:" || return 1
    sleep 0.2
    atmux send-keys -t "=${to}:" Enter
    : > "$inbox"
    agent_mail_render "$to"
    # it has something to do now: not waiting any more
    atmux set-option -u -t "=${to}:" @pulsar-alert 2>/dev/null || true
}

# Queued messages as the agent reads them: each labelled with who sent it
# and its id, which a reply names.
inbox_text() {
    # a line in a message that starts with "[" gets a space before it, so no
    # message can pass a line of its own off as one of these headers
    jq -r -s 'map(
        (if .job then "[Pulsar: the job \(.job) has ended"
         elif .from == "" or .from == "you" then "[A message via Pulsar, from a sender that gave no name"
         else "[From the agent session \(.from), via Pulsar" end)
        + (if .id then ", id \(.id)" else "" end)
        + (if .re then ", answering \(.re)" else "" end) + "]\n"
        + (.text | split("\n") | map(if startswith("[") then " " + . else . end) | join("\n"))) | join("\n\n")' "$1"
}

# A Claude session with a conversation: where its Stop hook looks for mail,
# in your home and in its sandbox's.
mail_paths() {
    local n=$1 agent id
    agent=$(session_get "$n" agent) || return 1
    id=$(hook_id "$n") || id=""
    case "$agent" in
        claude)
            # never in a sandbox's home: all sandboxed sessions share it and
            # can write it (a link there would make the host write anywhere)
            [ -n "$id" ] && [ "$(session_get "$n" sandbox || true)" != on ] || return 1
            printf '%s\n' "${HOME}/${AGENT_ALERTS_REL}/${id}.mail" ;;
        agy)
            # its hook finds it beside the session's record, which a sandbox doesn't see
            [ "$(session_get "$n" sandbox || true)" != on ] || return 1
            printf '%s\n' "${AGENT_SESSIONS}/${n}.mail" ;;
        *) return 1 ;;
    esac
}

# The queue, as the answer Claude's Stop hook gives: line 1 Stop's JSON,
# line 2 the ids it carries. None when nothing waits.
agent_mail_render() {
    local n=$1 inbox="${AGENT_SESSIONS}/${1}.inbox" m json ids text
    local -a paths
    mapfile -t paths < <(mail_paths "$n") || true
    [ ${#paths[@]} -gt 0 ] || return 0
    if [ -s "$inbox" ]; then
        text=$(inbox_text "$inbox") || return 0
        # Claude's Stop says "block" to keep going, agy's says "continue"
        local word="block"; [ "$(session_get "$n" agent || true)" != agy ] || word="continue"
        json=$(jq -n -c --arg r "$text" --arg d "$word" '{decision: $d, reason: $r}') || return 0
        ids=$(jq -r -s 'map(.id // empty) | join(" ")' "$inbox")
    fi
    for m in "${paths[@]}"; do
        [ -d "$(dirname "$m")" ] || [ "$m" = "${paths[0]}" ] || continue
        if [ -s "$inbox" ]; then
            mkdir -p "$(dirname "$m")"
            printf '%s\n%s\n%s\n' "$json" "$ids" "$text" > "${m}.tmp" && mv -f "${m}.tmp" "$m"
        else
            rm -f "$m"
        fi
    done
}

# Whether a Claude session's mail waiter took the mail within a few seconds.
mail_wait() {
    local m left=$(( ${PULSAR_MAIL_WAIT:-3} * 10 ))
    local -a paths
    mapfile -t paths < <(mail_paths "$1") || true
    while :; do
        local pending=0
        for m in "${paths[@]}"; do [ ! -f "$m" ] || pending=1; done
        [ "$pending" = 1 ] || return 0
        [ "$left" -gt 0 ] || return 1
        sleep 0.1; left=$((left - 1))
    done
}
# Mail taken back before typing: renamed away, so a hook can't take it too.
mail_cancel() {
    local m
    local -a paths
    mapfile -t paths < <(mail_paths "$1") || true
    for m in "${paths[@]}"; do mv -f "$m" "${m}.cancel" 2>/dev/null && rm -f "${m}.cancel"; done
    return 0
}

# After Claude's Stop hook took mail: those messages are delivered.
agent_mail_taken() {
    local n=$1 inbox="${AGENT_SESSIONS}/${1}.inbox" m took=1 ids
    local -a paths
    mapfile -t paths < <(mail_paths "$n") || true
    for m in "${paths[@]}"; do
        [ -f "${m}.taken" ] || continue
        took=0
        ids=$(sed -n 2p "${m}.taken")
        rm -f "${m}.taken"
        [ -s "$inbox" ] || continue
        jq -c --arg ids " $ids " 'select((.id // "") as $i | ($i == "" or ($ids | contains(" \($i) "))) | not)' "$inbox" > "${inbox}.tmp" \
            && mv -f "${inbox}.tmp" "$inbox"
    done
    [ "$took" = 0 ] || return 1
    agent_mail_render "$n"
    atmux set-option -u -t "=${n}:" @pulsar-alert 2>/dev/null || true
    return 0
}

# pulsar agent inbox [<session>] [--unread] [--keep]: the messages to and from
# a session (default: the one this runs in), oldest first. Reading marks the
# ones to it as read, unless --keep.
agent_inbox() {
    local usage="usage: pulsar agent inbox [<session>] [--unread] [--keep] [--json]" n="" unread=0 keep=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --unread) unread=1 ;;
            --keep) keep=1 ;;
            -h|--help) printf '%s\n' "$usage"; return 0 ;;
            -*) die "$usage" ;;
            *) [ -z "$n" ] || die "$usage"; n=$1 ;;
        esac
        shift
    done
    [ -n "$n" ] || n=$(JSON=0 agent_whoami 2>/dev/null) || die "which session? pulsar agent inbox <session>"
    case "$n" in *[!A-Za-z0-9_-]*) die "$usage" ;; esac
    need jq
    local read="${AGENT_SESSIONS}/${n}.read" rows
    # reading another session's inbox doesn't mark its messages read
    local me; me=$(JSON=0 agent_whoami 2>/dev/null) || me=""
    [ "$n" = "$me" ] || [ -z "$me" ] || keep=1
    rows=$(msg_log_json | jq -c -s --arg n "$n" --rawfile r <(cat "$read" 2>/dev/null || true) --argjson u "$unread" '
        ($r | split("\n") | map(select(. != ""))) as $seen
        | map(select(.id and (.to == $n or .from == $n))
              | . + {read: (.to != $n or ((.id) as $i | $seen | index($i)) != null)})
        | if $u == 1 then map(select(.read | not)) else . end') || rows='[]'
    if [ "$keep" = 0 ]; then
        mkdir -p "$AGENT_SESSIONS"
        jq -r --arg n "$n" '.[] | select(.to == $n and (.read | not)) | .id' <<<"$rows" >> "$read"
    fi
    if [ "${JSON:-0}" = 1 ]; then printf '%s\n' "$rows"; return 0; fi
    [ "$(jq length <<<"$rows")" -gt 0 ] || { printf 'no messages%s for %s\n' "$([ "$unread" = 1 ] && echo ' unread')" "$n"; return 0; }
    jq -r --arg n "$n" '.[] | "\(if .to == $n then "from \(if .from == "" then "outside a session" else .from end)" else "to \(.to)" end)  \(.at | strftime("%b %d %H:%M"))  \(.id)\(if .re then "  answering \(.re)" else "" end)\(if .read then "" else "  new" end)\n\(.text)\n"' <<<"$rows"
}
