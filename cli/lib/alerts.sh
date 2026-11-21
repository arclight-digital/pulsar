# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): a session's turn: Claude's hooks, the bell, waiting, notifications.

# ---------------------------------------------------------------------------
# "Your agent is waiting": a desktop notification when an agent in a session
# you are not looking at needs you, with a button that opens a terminal on it.
#
# The signal is the terminal bell, because it is the one thing that reaches
# the host's tmux from wherever the agent runs: the agents box, the sandbox
# (which has no session bus and no way to the tmux socket, on purpose) or a
# native install. Any agent that rings the bell gets the notification.
#
# Claude Code gets hooks for it (--settings, beside the user's own): Stop
# (it finished) and Notification (it wants a permission or an answer). Claude
# runs a hook with no terminal of its own, so the hook rings the bell on
# Claude's: /proc/$CLAUDE_PID/fd/1. It also leaves what Claude said in
# ~/.local/state/pulsar/agent-alerts/<conversation>.json (the sandbox's home,
# when sandboxed), so the notification can say why. Claude's own "still
# waiting after 60 s" (idle_prompt) is skipped: Stop already said so.
# ---------------------------------------------------------------------------
AGENT_ALERTS_REL=.local/state/pulsar/agent-alerts
# how long a Claude session's mail waiter waits between turns, in seconds
MAIL_WAIT_TICKS=${PULSAR_MAIL_WAIT_TICKS:-3600}
case "$MAIL_WAIT_TICKS" in ''|*[!0-9]*) MAIL_WAIT_TICKS=3600 ;; esac
# the agents app: Open in a notification goes to the session there
AGENTS_APP=${PULSAR_AGENTS_APP:-/usr/libexec/pulsar/pulsar-agents}

agent_alert_settings() {
    local id=$1 cmd
    # quiet on stdout and always exit 0: a Stop hook's output and exit code
    # are instructions to Claude
    # shellcheck disable=SC2016  # expanded by the hook's sh
    cmd='d="$HOME/'"${AGENT_ALERTS_REL}"'"; mkdir -p "$d" && cat > "$d/'"${id}"'.json"; printf "\a" 2>/dev/null > "/proc/${CLAUDE_PID:-$PPID}/fd/1"; exit 0'
    # At a turn's end, mail from other sessions (agent_mail_render) keeps it
    # going: its first line is Stop's own answer, {"decision": "block",
    # "reason": <the messages>}. Taken by renaming it, so it goes once; the
    # bell after tells Pulsar which ones went (agent_notify).
    # shellcheck disable=SC2016  # expanded by the hook's sh
    stop='m="$HOME/'"${AGENT_ALERTS_REL}/${id}"'.mail"; [ -f "$m" ] && mv -f "$m" "$m.taken" 2>/dev/null && head -n 1 "$m.taken"; '"$cmd"
    # Between turns, mail wakes it: a background hook (asyncRewake) started
    # at each turn's end and at the session's start waits for the mail file,
    # takes it the same way, gives Claude the messages (lines 3 on) and exits
    # 2, which is what wakes it; the bell is for Pulsar, as above. It gives
    # up after an hour, and the next turn's end starts another.
    # shellcheck disable=SC2016  # expanded by the hook's sh
    # One waiter per conversation: each writes its PID to <id>.mail.waiter,
    # and an older one that finds another's there gives up. It also goes
    # when its Claude does (the session ended or was killed).
    wait_cmd='m="$HOME/'"${AGENT_ALERTS_REL}/${id}"'.mail"; w="$m.waiter"; cat > /dev/null; mkdir -p "${m%/*}"; echo $$ > "$w"; i=0; while [ $i -lt '"${MAIL_WAIT_TICKS}"' ]; do [ "$(cat "$w" 2>/dev/null)" = "$$" ] || exit 0; [ -d "/proc/${CLAUDE_PID:-$PPID}" ] || { rm -f "$w"; exit 0; }; if [ -f "$m" ] && mv -f "$m" "$m.taken" 2>/dev/null; then rm -f "$w"; tail -n +3 "$m.taken" >&2; printf "\a" 2>/dev/null > "/proc/${CLAUDE_PID:-$PPID}/fd/1"; exit 2; fi; sleep 1; i=$((i + 1)); done; rm -f "$w"; exit 0'
    # A turn starting clears "waiting": the prompt sent, or a tool run after
    # a permission question was answered (only then: PostToolUse runs after
    # every tool, and stays silent unless the last word was that question).
    # shellcheck disable=SC2016  # expanded by the hook's sh
    # Only the event's name is kept: these hooks' input is the prompt, or a
    # tool's input and output, and a sandboxed session's alert folder is in
    # the sandbox home every sandboxed session shares.
    # shellcheck disable=SC2016  # expanded by the hook's sh
    local prompt='d="$HOME/'"${AGENT_ALERTS_REL}"'"; cat > /dev/null; mkdir -p "$d" && echo "{\"hook_event_name\":\"UserPromptSubmit\"}" > "$d/'"${id}"'.json"; printf "\a" 2>/dev/null > "/proc/${CLAUDE_PID:-$PPID}/fd/1"; exit 0'
    # shellcheck disable=SC2016  # expanded by the hook's sh
    local after='grep -Eq "\"hook_event_name\" *: *\"Notification\"" "$HOME/'"${AGENT_ALERTS_REL}/${id}"'.json" 2>/dev/null || { cat > /dev/null; exit 0; }; '"${prompt//UserPromptSubmit/PostToolUse}"
    jq -cn --arg c "$cmd" --arg p "$prompt" --arg s "$stop" --arg w "$wait_cmd" --arg a "$after" --argjson t "$((MAIL_WAIT_TICKS + 60))" '
        {type: "command", command: $w, async: true, asyncRewake: true, timeout: $t} as $waiter
        | {hooks: {Stop: [{hooks: [{type: "command", command: $s}]}, {hooks: [$waiter]}],
                   SessionStart: [{hooks: [$waiter]}],
                   UserPromptSubmit: [{hooks: [{type: "command", command: $p}]}],
                   PostToolUse: [{hooks: [{type: "command", command: $a}]}],
                   Notification: [{hooks: [{type: "command", command: $c}]}]}}'
}

# agent notify <session>: tmux's alert-bell hook runs this, on the host.
agent_notify() {
    local tname=${1:-}
    case "$tname" in ''|*[!A-Za-z0-9_-]*) die "usage: pulsar agent notify <session> (tmux runs this)" ;; esac
    have tmux || return 0
    atmux_running "$tname" || return 0
    # the record's time is when it was last active (agent sessions --json)
    touch -c "${AGENT_SESSIONS}/${tname}.session"
    # one thing at a time on the session's queue: sends run alongside this
    # (the folder may not exist yet when the record was made by hand)
    mkdir -p "$AGENT_SESSIONS"
    exec {lockfd}>"${AGENT_SESSIONS}/${tname}.lock"
    flock -w 10 "$lockfd" || return 0
    # Claude's Stop hook took its mail and keeps going: what went comes off
    # the queue, and it isn't waiting for anyone
    if agent_mail_taken "$tname"; then
        return 0
    fi
    # looking at it already (a client on it, in a focused terminal): it still
    # waits for you, but needs no desktop notification, and nothing is typed
    # in under your fingers
    local watched=0
    ! atmux_watched "$tname" || watched=1
    local agent dir id f="" c event="" msg="" title body
    agent=$(session_get "$tname" agent) || agent=""
    dir=$(session_get "$tname" dir) || dir=""
    id=$(session_get "$tname" id) || id=""
    if [ "$agent" = claude ] && [ -n "$id" ] && have jq; then
        # where this session's own hook writes: your home, or (sandboxed) the
        # sandbox's, which every sandboxed session shares and can write, so
        # it's never read for a session that isn't sandboxed
        if [ "$(session_get "$tname" sandbox || true)" = on ]; then
            c="${SANDBOX_HOMES}/claude/${AGENT_ALERTS_REL}/${id}.json"
        else
            c="${HOME}/${AGENT_ALERTS_REL}/${id}.json"
        fi
        [ ! -f "$c" ] || [ -L "$c" ] || f=$c
        if [ -n "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f") )) -le 30 ]; then
            event=$(jq -r '.hook_event_name // empty' "$f" 2>/dev/null) || event=""
            case "$event" in
                UserPromptSubmit|PostToolUse)
                    # a turn started (or went on after a permission answer)
                    atmux set-option -u -t "=${tname}:" @pulsar-alert 2>/dev/null || true
                    return 0 ;;
            esac
            if [ "$(jq -r '.notification_type // empty' "$f" 2>/dev/null)" = idle_prompt ]; then
                # still at its prompt, a while after its turn: messages can go
                # in, unless you're looking at it (and may be typing)
                [ "$watched" = 1 ] || agent_deliver "$tname" >/dev/null 2>&1 || true
                return 0
            fi
            msg=$(jq -r '.message // empty' "$f" 2>/dev/null) || msg=""
        fi
    fi
    # agy's and Codex's bell is Pulsar's own turn-end hook (agy_turn_hook,
    # codex_turn_notify): the agent is waiting
    case "${event}:${agent}" in
        :agy|:codex|:opencode)
            local mark="${AGENT_SESSIONS}/${tname}.turn"
            if [ -f "$mark" ] && [ ! -L "$mark" ] && [ $(( $(date +%s) - $(stat -c %Y "$mark") )) -le 30 ]; then
                event=Waiting
                rm -f "$mark"
            elif [ "$(session_get "$tname" sandbox || true)" = on ]; then
                # can't be told apart from inside a sandbox; it takes no messages
                event=Waiting
            fi ;;
    esac
    # Messages from other sessions go in only at a turn's end, when the agent
    # sits at its own prompt: never on a Notification (a permission question,
    # where the Enter after the text would answer it) or a bare bell.
    if [ "$watched" = 0 ] && at_prompt "$event" && agent_deliver "$tname" >/dev/null 2>&1; then
        return 0
    fi
    local who="The agent"
    if [ -n "$agent" ] && agent_row "$agent"; then who=${A_DESC%% (*}; fi
    case "$event" in
        Stop)         title="${tname}: ${who} is done"; body="It is waiting for your next message." ;;
        Notification) title="${tname}: ${who} needs you"; body=${msg:-"It is waiting for you."} ;;
        Waiting)      title="${tname}: ${who} is waiting for you"; body="It finished its turn, or needs an answer." ;;
        *)            title="${tname}: ${who} wants your attention"; body="It rang the terminal bell." ;;
    esac
    [ -z "$dir" ] || body+=$'\n'"In ${dir/#"$HOME"/\~}"
    atmux set-option -t "=${tname}:" @pulsar-alert "${event:-bell}" 2>/dev/null || true
    # Codex says nothing when a turn starts (nor agy in a sandbox, which has
    # no tmux for its PreInvocation hook), so their "waiting" holds while the
    # screen stays the one the turn ended on (alert_now): taken a second on,
    # once the agent has drawn it, and without the session's lock. agy
    # outside one clears it itself (agy_turn_hook): until then it waits.
    if [ "$event" = Waiting ] && { [ "$agent" != agy ] || ! agy_start_hook "$tname"; }; then
        ( exec {lockfd}>&-
          sleep 1
          [ "$(atmux show-options -v -t "=${tname}:" @pulsar-alert 2>/dev/null)" = Waiting ] || exit 0
          k=$(screen_key "$tname") && atmux set-option -t "=${tname}:" @pulsar-alert-screen "$k"
        ) >/dev/null 2>&1 &
    else
        atmux set-option -u -t "=${tname}:" @pulsar-alert-screen 2>/dev/null || true
    fi
    [ "$watched" = 0 ] || return 0

    have notify-send || return 0
    export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
    if ! have systemd-run || [ -z "$agent" ]; then
        notify-send --app-name=Pulsar --icon=digital.arclight.Pulsar.Agents "$title" "$body" || true
        return 0
    fi
    # One notification per session at a time. The newer alert's unit takes
    # over from the last one's, and its notification REPLACES the last one
    # (--replace-id, the id kept in idf): stopping the old unit alone left
    # its notification on screen with nothing behind its button, and Claude
    # rings on every Stop and question, so the one people clicked was
    # usually such a dead one. The click's activation token goes to the
    # terminal, so its window comes to the front as it does from Pulsar
    # Settings, instead of opening behind or as "is ready".
    local unit="pulsar-agent-${tname}" self script app=""
    local idf="${XDG_RUNTIME_DIR}/pulsar-agent-${tname}.notification"
    self=$(realpath "$SELF")
    [ ! -x "$AGENTS_APP" ] || app=$AGENTS_APP
    # the agents app can take it: installed, or running from anywhere (a
    # copy started by hand answers on the session bus as well). Then Open
    # goes there, and the notification offers a terminal as well.
    local reach=0
    if [ -n "$app" ]; then reach=1
    elif have gdbus && gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
            --method org.freedesktop.DBus.NameHasOwner digital.arclight.Pulsar.Agents 2>/dev/null | grep -q true; then
        reach=1
    fi
    systemctl --user stop "${unit}.service" 2>/dev/null || true
    # shellcheck disable=SC2016  # expanded by the transient unit's sh
    script='rid=$(cat "$6" 2>/dev/null)
tok=$(mktemp) || exit 0
term=""
[ "$8" != 1 ] || term="--action=terminal=Open in Terminal"
notify-send --app-name=Pulsar --icon=digital.arclight.Pulsar.Agents --print-id ${rid:+--replace-id="$rid"} \
    --action=attach=Open ${term:+"$term"} --activation-token-fd=3 "$1" "$2" 3>"$tok" | {
    read -r id && printf "%s\n" "$id" > "$6"
    read -r a
    # the token is written once notify-send is done: read it after its end
    cat > /dev/null
    t=$(cat "$tok"); rm -f "$tok"
    case "$a" in attach|terminal) ;; *) exit 0 ;; esac
    rm -f "$6"
    if [ "$a" = attach ]; then
        # the agents app running now, wherever it was started from; else
        # the installed one; else a terminal after all
        case "$t" in *[\"\\]*) t="" ;; esac
        if gdbus call --session --dest digital.arclight.Pulsar.Agents --object-path /digital/arclight/Pulsar/Agents \
            --method org.gtk.Actions.Activate open-session "[<\"$5\">]" "{\"activation-token\": <\"$t\">}" \
            >/dev/null 2>&1; then
            exit 0
        fi
        [ -z "$7" ] || XDG_ACTIVATION_TOKEN=$t exec "$7" "$5"
    fi
    XDG_ACTIVATION_TOKEN=$t exec ptyxis --new-window -- "$3" agent run "$4" --tmux "$5"
}'
    systemd-run --user --collect --quiet --unit="$unit" \
        -- sh -c "$script" sh "$title" "$body" "$self" "$agent" "$tname" "$idf" "$app" "$reach" 2>/dev/null || true
}

# A turn's end, with the agent at its own prompt: Claude's Stop, and the
# turn-end hooks Pulsar gives the others (Waiting).
at_prompt() { case "${1:-}" in Stop|Waiting) return 0 ;; *) return 1 ;; esac; }

# A session's screen: its size, and a hash of what's on it.
screen_key() {
    local size
    size=$(atmux display -p -t "=${1}:" '#{pane_width}x#{pane_height}' 2>/dev/null) || return 1
    [ -n "$size" ] || return 1
    printf '%s:%s\n' "$size" "$(atmux capture-pane -p -t "=${1}:" 2>/dev/null | md5sum | cut -c1-16)"
}

# The session's alert as it stands. A Codex or agy one (a turn's end has no
# matching start there) lasts while the screen is the one the turn ended on:
# an agent at its prompt redraws the same screen, and typing or working
# changes it. A new size only moves that baseline.
# agy_start_hook <session>: whether this agy session clears its own
# "waiting" when a turn starts (agy_turn_hook's PreInvocation): not in a
# sandbox, and started after a hooks.json with it was written (agy reads
# the file when it starts). One started before keeps the screen check.
agy_start_hook() {
    local f="${HOME}/.gemini/config/hooks.json" made
    [ "$(session_get "$1" sandbox || true)" != on ] || return 1
    [ -f "$f" ] && have jq || return 1
    jq -e '.pulsar.PreInvocation[0].command // empty | strings' "$f" >/dev/null 2>&1 || return 1
    made=$(atmux display -p -t "=${1}:" '#{session_created}' 2>/dev/null) || return 1
    [ -n "$made" ] && [ "$(stat -c %Y "$f")" -le "$made" ]
}

# agent_quiet <session> <agent>: a Claude or Codex session not marked
# waiting whose screen has stood still for PULSAR_QUIET_SECONDS (20) is at
# its prompt, so it is marked waiting, and prints it. Both draw a ticking
# counter while they work (Claude's spinner, Codex's "Working (12s"),
# through tool runs and compaction alike, so a still screen means neither
# is at work: a turn cancelled at once (Claude runs no Stop hook for an
# interrupt), a first screen before any turn, a trust question. Claude's
# mark goes at its next prompt (UserPromptSubmit); Codex's holds while the
# screen does (alert_now). The screen as last seen, and since when, is kept
# in @pulsar-quiet, and dropped once it has marked the session.
agent_quiet() {
    local k now t
    case "${2:-}" in claude|codex) ;; *) return 1 ;; esac
    k=$(screen_key "$1") || return 1
    now=$(date +%s)
    t=$(atmux show-options -qv -t "=${1}:" @pulsar-quiet 2>/dev/null) || t=""
    if [ "${t#* }" != "$k" ]; then
        atmux set-option -t "=${1}:" @pulsar-quiet "${now} ${k}" 2>/dev/null || true
        return 1
    fi
    [ $(( now - ${t%% *} )) -ge "${PULSAR_QUIET_SECONDS:-20}" ] || return 1
    atmux set-option -u -t "=${1}:" @pulsar-quiet 2>/dev/null || true
    if [ "$2" = claude ]; then
        atmux set-option -t "=${1}:" @pulsar-alert Stop 2>/dev/null || return 1
        printf 'Stop\n'
    else
        atmux set-option -t "=${1}:" @pulsar-alert-screen "$k" 2>/dev/null || return 1
        atmux set-option -t "=${1}:" @pulsar-alert Waiting 2>/dev/null || return 1
        printf 'Waiting\n'
    fi
}

alert_now() {
    local a k now
    a=$(atmux show-options -v -t "=${1}:" @pulsar-alert 2>/dev/null) || a=""
    [ -n "$a" ] || return 0
    k=$(atmux show-options -v -t "=${1}:" @pulsar-alert-screen 2>/dev/null) || k=""
    if [ -n "$k" ] && now=$(screen_key "$1"); then
        if [ "${now%%:*}" != "${k%%:*}" ]; then
            atmux set-option -t "=${1}:" @pulsar-alert-screen "$now" 2>/dev/null || true
        elif [ "$now" != "$k" ]; then
            return 0
        fi
    fi
    printf '%s\n' "$a"
}
