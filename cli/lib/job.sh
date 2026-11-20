# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): pulsar job: long commands in their own tmux, with a log.

# ---------------------------------------------------------------------------
# job -- a long command (a training run, a build, a benchmark) in a tmux
# session of its own, on a server of its own (so it is never taken for an
# agent session), with its output in a log and a notification when it ends.
# --notify <session> also tells that agent session, in its prompt, between
# its turns (agent send): what an agent uses to start something and hear
# back. The pane stays after the command ends, so `job attach` still shows it.
# ---------------------------------------------------------------------------
JOB_SOCKET=${PULSAR_JOB_TMUX_SOCKET:-pulsar-jobs}
JOBS=${PULSAR_JOBS:-${XDG_STATE_HOME:-$HOME/.local/state}/pulsar/jobs}
# shellcheck disable=SC2016  # the pane's bash expands these
JOB_PANE='mapfile -d "" -t _a < "$1"; set -- "${_a[@]}"; "$@"; s=$?; exec "$PULSAR_JOB_CLI" job done "$0" "$s" "$PULSAR_JOB_TOKEN"'
# The jobs' tmux server keeps the environment of whoever starts it: never an
# agent session's own (its record, its terminal), or every later job would
# look like that session to whoami, inbox and the bell.
jtmux() { env -u PULSAR_SESSION_RECORD -u PULSAR_TTY -u PULSAR_SCRATCH -u TMUX tmux -L "$JOB_SOCKET" -f /dev/null "$@"; }
# a job's name as given to a subcommand: never a path
job_name() { case "${1:-}" in ''|-*|*[!A-Za-z0-9_-]*) die "no job called '${1:-}' (pulsar job list)" ;; esac; }
job_get() {
    local f="${JOBS}/$1.job" k v
    [ -r "$f" ] || return 1
    while IFS='=' read -r k v; do [ "$k" != "$2" ] || { printf '%s\n' "$v"; return 0; }; done < "$f"
    return 1
}
job_set() {
    local f="${JOBS}/$1.job" tmp
    tmp=$(mktemp "${JOBS}/.$1.XXXXXX")
    { [ ! -f "$f" ] || grep -v "^$2=" "$f"; printf '%s=%s\n' "$2" "$3"; } > "$tmp" && mv "$tmp" "$f"
}
# The pane's whole history, into the job's log file, while the pane is there.
job_save() {
    jtmux capture-pane -p -J -S - -t "=${1}:" 2>/dev/null | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "${JOBS}/${1}.log.tmp" \
        && [ -s "${JOBS}/${1}.log.tmp" ] && mv "${JOBS}/${1}.log.tmp" "${JOBS}/${1}.log"
    rm -f "${JOBS}/${1}.log.tmp"
}

# a log as a person reads it: no terminal escapes, no carriage-return redraws
job_clean() { sed -e 's/\x1b\[[0-9;?]*[ -\/]*[@-~]//g' -e 's/\x1b\][^\x07]*\x07//g' -e 's/.*\r//' ; }

job_state() {
    local n=$1 st
    st=$(job_get "$n" status) || st=""
    if jtmux has-session -t "=$n" 2>/dev/null && [ "$(jtmux display -p -t "=${n}:" '#{pane_dead}' 2>/dev/null)" != 1 ]; then
        printf 'running\n'
    elif [ "$st" = stopped ]; then printf 'stopped\n'
    elif [ -n "$st" ]; then printf 'done\n'
    else printf 'gone\n'; fi
}

cmd_job() {
    local usage="usage: pulsar job run [--name <name>] [--dir <folder>] [--notify <session>] -- <command>...
       pulsar job list | log <name> [--lines N] | wait <name> | stop <name> | rm <name> | attach <name>"
    local sub=${1:-list}; shift || true
    case "$sub" in
        -h|--help) printf '%s\n' "$usage"; return 0 ;;
        run)
            need tmux
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
            [ -d "$dir" ] || die "no folder $dir"
            dir=$(cd "$dir" && pwd -P)
            case "$notify" in *[!A-Za-z0-9_-]*) die "--notify is an agent session's name" ;; esac
            if [ -z "$name" ]; then
                name=$(basename -- "$1" | tr -c 'A-Za-z0-9_-' '-' | sed 's/-*$//'); name="${name:-job}-$(date +%H%M%S)"
            fi
            case "$name" in ''|-*|*[!A-Za-z0-9_-]*) die "a job's name is letters, digits, - and _: '$name'" ;; esac
            if jtmux has-session -t "=$name" 2>/dev/null; then
                # an ended one's pane stays for `job attach`; its name can be used again
                [ "$(job_state "$name")" != running ] || die "a job called $name is running"
                jtmux kill-session -t "=$name" 2>/dev/null || true
            fi
            mkdir -p "$JOBS"
            local log="${JOBS}/${name}.log" cmdline="" w
            for w in "$@"; do cmdline+=" $(printf '%q' "$w")"; done
            : > "$log"
            # only the job's own pane may say how it ended (job done): it
            # alone has this token
            local token; token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
            ( umask 077; printf 'dir=%s\ncommand=%s\nstarted=%s\nnotify=%s\ntoken=%s\n' "$dir" "${cmdline# }" "$(date +%s)" "$notify" "$token" > "${JOBS}/${name}.job" )
            # its words in a file, not as tmux arguments (a word ending in ";"
            # would end tmux's own command)
            printf '%s\0' "$@" > "${JOBS}/${name}.argv"
            # the pane's history is the log while it runs (a long one, set
            # before the pane exists), saved to the log file as it ends
            jtmux start-server \; set-option -g history-limit 200000 \; \
                new-session -d -s "$name" -x 200 -y 50 -c "$dir" \
                -e "PULSAR_JOB_CLI=$(realpath "$SELF")" -e "PULSAR_JOB_TOKEN=${token}" \
                -- bash -c "$JOB_PANE" "$name" "${JOBS}/${name}.argv" \
                || die "tmux could not start $name"
            jtmux set-option -t "=${name}:" remain-on-exit on 2>/dev/null || true
            printf '%s is running in %s: pulsar job log %s, pulsar job attach %s\n' "$name" "${dir/#"$HOME"/\~}" "$name" "$name" ;;
        done)
            # the pane's last word: the command ended with $2
            local n=${1:-} st=${2:-} tok=${3:-}
            case "$n" in ''|*[!A-Za-z0-9_-]*) die "usage: pulsar job done <name> <status> (the job's pane runs this)" ;; esac
            case "$st" in ''|*[!0-9]*) die "usage: pulsar job done <name> <status> (the job's pane runs this)" ;; esac
            [ -f "${JOBS}/${n}.job" ] || return 0
            [ -n "$tok" ] && [ "$tok" = "$(job_get "$n" token || true)" ] || die "only ${n}'s own pane says how it ended"
            rm -f "${JOBS}/${n}.argv"
            job_save "$n"
            [ "$(job_get "$n" status || true)" = stopped ] || job_set "$n" status "$st"
            job_set "$n" ended "$(date +%s)"
            local last; last=$(job_clean < "${JOBS}/${n}.log" 2>/dev/null | sed '/^[[:space:]]*$/d' | tail -n 5)
            local head="${n} finished" ; [ "$st" = 0 ] || head="${n} failed (exit ${st})"
            if have notify-send; then
                notify-send --app-name=Pulsar --icon=digital.arclight.Pulsar.Agents "Job ${head}" "${last##*$'\n'}" 2>/dev/null || true
            fi
            local to; to=$(job_get "$n" notify) || to=""
            if [ -n "$to" ]; then
                "$SELF" agent send "$to" --job "$n" -- "The job ${head}. Its last lines:
${last}
(pulsar job log ${n} for more)" >/dev/null 2>&1 || true
            fi ;;
        list)
            [ $# -eq 0 ] || die "$usage"
            local f n rows=()
            for f in "$JOBS"/*.job; do
                [ -e "$f" ] || continue
                n=$(basename "$f" .job)
                rows+=("$(jq -n -c --arg n "$n" --arg s "$(job_state "$n")" --arg d "$(job_get "$n" dir || true)" \
                    --arg c "$(job_get "$n" command || true)" --arg st "$(job_get "$n" status || true)" \
                    --arg t "$(job_get "$n" started || true)" --arg e "$(job_get "$n" ended || true)" \
                    --arg no "$(job_get "$n" notify || true)" \
                    '{name: $n, state: $s, dir: $d, command: $c, started: ($t | tonumber? // null),
                      ended: ($e | tonumber? // null), status: ($st | tonumber? // (if $st == "" then null else $st end)),
                      notify: (if $no == "" then null else $no end)}')")
            done
            if [ "${JSON:-0}" = 1 ]; then printf '%s\n' "${rows[@]}" | jq -s -c 'sort_by(-(.started // 0))'; return 0; fi
            [ ${#rows[@]} -gt 0 ] || { printf 'no jobs  (pulsar job run -- <command>)\n'; return 0; }
            printf '%s\n' "${rows[@]}" | jq -r '"\(.name)\t\(.state)\(if .status != null and .state == "done" then " (exit \(.status))" else "" end)\t\(.command)"' \
                | column -t -s $'\t' ;;
        log)
            local n=${1:-} lines=50; shift || true
            [ "${1:-}" != --lines ] || { lines=${2:-50}; }
            case "$lines" in ''|*[!0-9]*) die "--lines wants a number" ;; esac
            job_name "$n"; [ -f "${JOBS}/${n}.job" ] || die "no job called ${n} (pulsar job list)"
            local text
            if [ "$(job_state "$n")" = running ]; then
                text=$(jtmux capture-pane -p -J -S - -t "=${n}:" 2>/dev/null | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | tail -n "$lines")
            else
                text=$(job_clean < "${JOBS}/${n}.log" | tail -n "$lines")
            fi
            if [ "${JSON:-0}" = 1 ]; then
                jq -n -c --arg n "$n" --arg s "$(job_state "$n")" --arg t "$text" '{name: $n, state: $s, text: $t}'
            else printf '%s\n' "$text"; fi ;;
        wait)
            # until it ends: its last lines, and its exit status as ours
            local n=${1:-} lines=20
            job_name "$n"; [ -f "${JOBS}/${n}.job" ] || die "no job called ${n} (pulsar job list)"
            while [ "$(job_state "$n")" = running ]; do sleep "${PULSAR_JOB_POLL:-2}"; done
            sleep 0.5
            job_clean < "${JOBS}/${n}.log" | sed '/^[[:space:]]*$/d' | tail -n "$lines"
            local st; st=$(job_get "$n" status) || st=1
            case "$st" in stopped) return 143 ;; ''|*[!0-9]*) return 1 ;; *) return "$st" ;; esac ;;
        stop)
            local n=${1:-}
            job_name "$n"; [ -f "${JOBS}/${n}.job" ] || die "no job called ${n} (pulsar job list)"
            [ "$(job_state "$n")" = running ] || die "${n} is not running"
            job_set "$n" status stopped
            job_save "$n"
            jtmux kill-session -t "=$n"
            printf 'stopped %s\n' "$n" ;;
        rm)
            local n=${1:-}
            job_name "$n"; [ -f "${JOBS}/${n}.job" ] || die "no job called ${n} (pulsar job list)"
            [ "$(job_state "$n")" != running ] || die "${n} is running; pulsar job stop ${n} first"
            jtmux kill-session -t "=$n" 2>/dev/null || true
            rm -f "${JOBS}/${n}.job" "${JOBS}/${n}.log"
            printf 'removed %s\n' "$n" ;;
        attach)
            local n=${1:-}
            job_name "$n"; [ -f "${JOBS}/${n}.job" ] || die "no job called ${n} (pulsar job list)"
            jtmux has-session -t "=$n" 2>/dev/null || die "${n} has ended; pulsar job log ${n}"
            unset TMUX
            exec tmux -L "$JOB_SOCKET" attach-session -t "=$n" ;;
        *) die "$usage" ;;
    esac
}
