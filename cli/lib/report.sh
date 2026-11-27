# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): pulsar report, crashes and GPU faults.

# ---------------------------------------------------------------------------
# report -- one bundle to paste, for an agent or a human.
#
# Every "what does your system say?" round trip in a bug thread asks for the
# same seven things. This gathers them once, in a shape a model can read
# without scraping terminal art, and it is built around what it LEAVES OUT:
#
#   - the journal is never dumped: only warning-and-worse lines, only from the
#     units this image ships or that are failed right now, and only the last N
#   - no environment variables are read beyond USER and HOME, and those only to
#     know what to redact
#   - the hostname, the username and the home path are rewritten out of every
#     string, followed by a best-effort pass over secret-shaped text
#
# The redaction runs over the finished document, not per source, so a source
# added later cannot forget it. It is still best effort -- a journal message is
# free text -- and --help says so rather than promising what it cannot check.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# crashes -- what systemd-coredump caught, for the person and for their agent.
#
# systemd-coredump already records every crash on Fedora, with a symbolized
# stack trace of the crashing thread, and coredumpctl hands a user their own
# crashes without root. Nothing needs adding to catch a crash; what was
# missing is someone telling you, and a way to hand it to the agent you
# already use. The core file itself never leaves the machine: only
# coredumpctl's summary and the crashing thread's frames go into the report.
#
# Only this user's crashes, only this boot. A crash from before the last
# reboot is still reachable by PID with --crash, just not announced.
# ---------------------------------------------------------------------------

# The user's "Ignore this": programs whose crashes are not announced (no
# notification, no doctor warning, not `--crash latest`). One pattern a line,
# '#' for comments, nothing in it by default. A bare name matches the
# executable's name, whatever directory it ran from (wine64-preloader, in
# every Proton version's tree); a pattern with a '/' matches the end of its
# path (wine/i386-unix/wine64-preloader). A crash asked for by PID is always
# found: ignoring stops the announcing, not the record.
CRASH_IGNORE_FILE=${PULSAR_CRASH_IGNORE:-${XDG_CONFIG_HOME:-$HOME/.config}/pulsar/crash-ignore}

crash_ignored() {
    local exe=$1 pat
    [ -r "$CRASH_IGNORE_FILE" ] || return 1
    while IFS= read -r pat || [ -n "$pat" ]; do
        pat=${pat%%#*}; pat=${pat#"${pat%%[![:space:]]*}"}; pat=${pat%"${pat##*[![:space:]]}"}
        [ -n "$pat" ] || continue
        case "$pat" in
            */*) case "$exe" in */"$pat"|"$pat") return 0 ;; esac ;;
            *)   [ "$(basename -- "$exe")" = "$pat" ] && return 0 ;;
        esac
    done < "$CRASH_IGNORE_FILE"
    return 1
}

# crash_rows without the ignored ones
crash_unignored() {
    local pid t sig exe
    while IFS=$'\t' read -r pid t sig exe; do
        [ -n "$pid" ] || continue
        crash_ignored "$exe" || printf '%s\t%s\t%s\t%s\n' "$pid" "$t" "$sig" "$exe"
    done
}

# pid <TAB> time (us) <TAB> signal <TAB> exe, oldest first. `all` drops the
# this-boot limit (an explicit PID may be from an earlier boot); `raw` keeps
# the ignored ones. Without `all` or `raw`, ignored programs are left out.
crash_rows() {
    case "${1:-}" in
        all|raw) crash_rows_raw "${1:-}" ;;
        *)       crash_rows_raw | crash_unignored ;;
    esac
}

crash_rows_raw() {
    have coredumpctl || return 0
    local -a since=()
    if [ "${1:-}" != all ]; then
        local btime
        btime=$(awk '$1 == "btime" { print $2 }' "${PULSAR_PROC_STAT:-/proc/stat}" 2>/dev/null) || btime=""
        [ -z "$btime" ] || since=(--since="@${btime}")
    fi
    # exits 1 with "No coredumps found" when there are none: not an error here
    coredumpctl list --json=short --no-pager "${since[@]}" 2>/dev/null \
        | jq -r --argjson u "$(id -u)" \
            '.[]? | select(.uid == $u) | [.pid, .time, .sig, .exe] | @tsv' 2>/dev/null || true
}

# latest | <pid> -> a pid of this user's that coredumpctl knows.
crash_resolve() {
    local want=$1 rows pid
    case "$want" in
        latest)
            rows=$(crash_rows)
            pid=$(printf '%s' "$rows" | tail -1 | cut -f1)
            [ -n "$pid" ] || die "no crashes this boot (older ones: coredumpctl list, then --crash <pid>)" ;;
        ''|*[!0-9]*) die "--crash wants a PID or 'latest' (got: ${want})" ;;
        *)
            rows=$(crash_rows all)
            printf '%s\n' "$rows" | cut -f1 | grep -qx "$want" \
                || die "no crash of yours with PID ${want} (see: coredumpctl list)"
            pid=$want ;;
    esac
    printf '%s\n' "$pid"
}

# One crash as JSON: what coredumpctl says about it, the crashing thread's
# frames (the first trace it prints), and that process's journal lines.
crash_json() {
    local pid=$1 info
    info=$(coredumpctl -1 info --no-pager "$pid" 2>/dev/null) || { printf 'null'; return 0; }
    local fields frames journal
    fields=$(printf '%s\n' "$info" | awk '
        /^ *[A-Z][A-Za-z ]*: / && !seen_msg {
            k = $0; sub(/^ */, "", k); v = k; sub(/: .*/, "", k); sub(/^[^:]*: /, "", v)
            if (k == "Message") { seen_msg = 1; next }
            printf "%s\t%s\n", k, v
        }')
    frames=$(printf '%s\n' "$info" | awk '
        /Stack trace of thread/ { if (done) exit; t = 1; next }
        t && /^ *$/ { done = 1; t = 0; exit }
        t && n < 40 { sub(/^ */, ""); print; n++ }')
    journal=$(journalctl -b --no-pager -o json "_PID=${pid}" -n 30 2>/dev/null \
        | jq -s -c 'map({
            time: ((.__REALTIME_TIMESTAMP // "0") | tonumber / 1000000 | floor | todate),
            priority: ((.PRIORITY // "?") | tostring),
            message: (.MESSAGE | if type == "string" then . else "<binary message>" end)})' 2>/dev/null) \
        || journal='[]'
    [ -n "$journal" ] || journal='[]'
    jq -n -c --arg fields "$fields" --arg frames "$frames" --argjson journal "$journal" '
        ($fields | split("\n") | map(select(length > 0) | split("\t") | {(.[0]): .[1]}) | add // {}) as $f
        | { executable: $f["Executable"], pid: ($f["PID"] // "" | split(" ")[0] | tonumber? // null),
            # "(2h ago)" is true once; a saved report outlives it
            signal: $f["Signal"], time: ($f["Timestamp"] // "" | sub(" \\([^)]*\\)$"; "")), package: $f["Package"],
            unit: ($f["User Unit"] // $f["Unit"]), command_line: $f["Command Line"],
            stack: ($frames | split("\n") | map(select(length > 0))),
            journal: $journal }'
}

check_crashes() {
    local rows raw ignored=""
    raw=$(crash_rows raw)
    rows=$(printf '%s\n' "$raw" | crash_unignored)
    # what "Ignore this" hid is still counted, so nothing vanishes unseen
    local nraw nrows
    nraw=$(printf '%s\n' "$raw" | grep -c . || true)
    nrows=$(printf '%s\n' "$rows" | grep -c . || true)
    [ "$nraw" -gt "$nrows" ] && ignored=" ($((nraw - nrows)) ignored: pulsar crashes ignore list)"
    if [ -z "$rows" ]; then
        have coredumpctl && record crashes ok "no crashes of yours this boot${ignored}"
        return 0
    fi
    local n summary latest
    n=$(printf '%s\n' "$rows" | grep -c .)
    # "wireplumber (5), chrome-headless (2)": most frequent first
    summary=$(printf '%s\n' "$rows" | cut -f4 | xargs -r -n1 basename | sort | uniq -c | sort -rn \
        | awk '{ printf "%s%s", (NR > 1 ? ", " : ""), ($1 > 1 ? $2 " (" $1 ")" : $2) }')
    latest=$(printf '%s\n' "$rows" | tail -1 | cut -f4)
    record crashes warn "${n} crash(es) of yours this boot: ${summary}${ignored}" \
        "latest: $(basename "$latest"). pulsar agent ask --crash latest, or pulsar report --crash latest --text"
}

# Once per program per boot, not once per crash: a service that aborts every
# hundred minutes is one piece of news, not fourteen. Only when there is an
# agent to hand it to -- without one this would be a crash nagger, and
# `pulsar doctor` already lists them.
crashes_notify() {
    local agent
    agent=$(agent_default_name 2>/dev/null) || return 0
    agent_row "$agent" || return 0
    local boot state="${UPDATE_STATE}/crash-notified" seen="" rows pid exe name
    boot=$(cat "${PULSAR_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null) || boot=unknown
    [ -r "$state" ] && seen=$(awk -v b="$boot" '$1 == b' "$state")
    rows=$(crash_rows)
    [ -n "$rows" ] || return 0
    local -a fresh=()
    # newest crash per program, newest first
    while IFS=$'\t' read -r pid _ _ exe; do
        printf '%s\n' "$seen" | awk -v e="$exe" '$2 == e { f = 1 } END { exit !f }' && continue
        case " ${fresh[*]-} " in *" ${exe} "*) continue ;; esac
        fresh+=("$exe")
        seen+=$'\n'"${boot} ${exe}"
        name=$(basename "$exe")
        crash_notify_one "$pid" "$name" "$exe"
    done < <(printf '%s\n' "$rows" | tac)
    [ ${#fresh[@]} -gt 0 ] || return 0
    mkdir -p "$UPDATE_STATE" && printf '%s\n' "$seen" | awk -v b="$boot" '$1 == b' > "$state"
}

crash_notify_one() {
    local pid=$1 name=$2 exe=${3:-$2} title body
    title="${name} crashed"
    body="Ask ${A_DESC%% (*} opens a terminal with a redacted report of the crash."
    have notify-send || return 0
    # The click has to outlive this oneshot unit, so the waiting notification
    # runs as a transient unit of its own. Without systemd-run it still says
    # so, just without the button.
    if ! have systemd-run; then
        notify-send --app-name="Pulsar" --icon=dialog-warning "$title" \
            "Details: pulsar agent ask --crash ${pid}" || true
        return 0
    fi
    local ask script self
    self=$(realpath "$SELF")
    ask="${self} agent ask --crash ${pid}"
    # "Ignore this": that program's crashes are not announced again (by its
    # name: a Proton update moves the path, not the name)
    # shellcheck disable=SC2016  # expanded by the transient unit's sh, not here
    script='a=$(notify-send --app-name=Pulsar --icon=dialog-warning --action=ask="$1" --action=ignore="Ignore this" "$2" "$3") || exit 0
case "$a" in
    ask) exec ptyxis -s --new-window -d "$HOME" -x "$4" ;;
    ignore) exec "$5" crashes ignore add "$6" ;;
esac'
    systemd-run --user --collect --quiet --unit="pulsar-crash-${pid}" \
        -- sh -c "$script" sh "Ask ${A_DESC%% (*}" "$title" "$body" "$ask" "$self" "$(basename -- "$exe")" 2>/dev/null || true
}

# pulsar crashes [ignore list | ignore add <pattern> | ignore remove <pattern>]
cmd_crashes() {
    case "${1:-}" in
        '') cmd_doctor crashes ;;
        ignore)
            shift
            local act=${1:-list} pat=${2:-}
            case "$act" in
                list)
                    if [ -s "$CRASH_IGNORE_FILE" ] && grep -qvE '^[[:space:]]*(#|$)' "$CRASH_IGNORE_FILE"; then
                        grep -vE '^[[:space:]]*(#|$)' "$CRASH_IGNORE_FILE"
                    else
                        echo "nothing ignored: every crash is announced"
                    fi ;;
                add)
                    [ -n "$pat" ] || die "usage: pulsar crashes ignore add <pattern>"
                    mkdir -p "$(dirname "$CRASH_IGNORE_FILE")"
                    if grep -qxF -- "$pat" "$CRASH_IGNORE_FILE" 2>/dev/null; then
                        echo "already ignored: ${pat}"
                    else
                        printf '%s\n' "$pat" >> "$CRASH_IGNORE_FILE"
                        echo "ignoring crashes of ${pat} (undo: pulsar crashes ignore remove ${pat})"
                    fi ;;
                remove)
                    [ -n "$pat" ] || die "usage: pulsar crashes ignore remove <pattern>"
                    grep -qxF -- "$pat" "$CRASH_IGNORE_FILE" 2>/dev/null || die "not on the list: ${pat}"
                    local tmp
                    tmp=$(mktemp "${CRASH_IGNORE_FILE}.XXXXXX")
                    grep -vxF -- "$pat" "$CRASH_IGNORE_FILE" > "$tmp" || true
                    mv -f "$tmp" "$CRASH_IGNORE_FILE"
                    echo "crashes of ${pat} are announced again" ;;
                *) die "usage: pulsar crashes [ignore [list | add <pattern> | remove <pattern>]]" ;;
            esac ;;
        -h|--help)
            echo "usage: pulsar crashes [ignore [list | add <pattern> | remove <pattern>]]"
            echo "  with no arguments: this boot's crashes (pulsar doctor crashes)"
            echo "  ignore: programs whose crashes and GPU faults are not announced. A name"
            echo "  matches that program wherever it ran from; a pattern with a / matches the"
            echo "  end of its path." ;;
        *) die "usage: pulsar crashes [ignore [list | add <pattern> | remove <pattern>]]" ;;
    esac
}

# ---------------------------------------------------------------------------
# gpu faults -- an NVIDIA "Xid" in the kernel log, said in words.
#
# When a game's GPU work faults, the NVIDIA driver writes an Xid line to the
# kernel log and stops that work. The game freezes or quits with no core dump
# and no message, so pulsar-crash-watch never hears of it. On cherenkov
# (2026-10-09, driver 615, RTX 5080 Laptop) Hell Is Us did this four runs in
# four (Xid 13 and Xid 109) until DLSS was turned off; nothing on screen said
# why. The line names the process ("pid=4242, name=GameThread"), but by the
# name of its thread, which is often not the game's.
# pulsar-gpu-fault-watch (`pulsar doctor gpu-faults --watch`) reads the kernel
# log as it is written, names the game while its process is still there to
# ask, and says what to try. NVIDIA's list: docs.nvidia.com/deploy/xid-errors
#
# Only the nvidia image: the vanilla one has no NVIDIA driver to log Xids.
# ---------------------------------------------------------------------------
GPU_FAULT_PROC=${PULSAR_PROC:-/proc}

# A kernel log line -> "xid<TAB>pid<TAB>name". pid and name are empty when the
# line names no process: the detail lines that follow an Xid 13, an Xid 79.
# pid is "?" when the driver logged a fault but not whose
# ("pid='<unknown>', name=<unknown>", common on Xid 31 and 13): still a fault.
# An Xid 154 whose recovery action is now 0x0 (None) asks for nothing: the
# driver logs it when a recovery is over, so it is not news.
xid_parse() {
    sed -nE '/NVRM: Xid /{
        /NVRM: Xid \([^)]*\): 154,.* 0x0+ \(None\)[.[:space:]]*$/d
        s/^.*NVRM: Xid \([^)]*\): ([0-9]+), pid=([0-9]+), name=([^,]*),.*$/\1\t\2\t\3/p
        t
        s/^.*NVRM: Xid \([^)]*\): ([0-9]+), pid=[^0-9,][^,]*, name=[^,]*,.*$/\1\t?\t/p
        t
        s/^.*NVRM: Xid \([^)]*\): ([0-9]+)[,:].*$/\1\t\t/p
    }'
}

# xid -> "kind<TAB>words". game: one program's GPU work faulted; gpu: the GPU
# itself; skip: not news on its own.
xid_meaning() {
    case "$1" in
        13|69) printf 'game\ta fault in graphics work' ;;
        31)    printf "game\\ta GPU memory access outside the program's own memory" ;;
        32)    printf 'game\ta corrupted stream of GPU commands' ;;
        8|109) printf 'game\tGPU work that hung and had to be stopped' ;;
        43)    printf 'game\tGPU work the driver had to stop' ;;
        # the driver cleaning up after a program that ended mid-work: logged
        # when one is killed, and after the Xid that was the news
        45)    printf 'skip\t' ;;
        79)    printf 'gpu\tThe NVIDIA GPU stopped answering the system' ;;
        62|119|120) printf "gpu\\tThe NVIDIA GPU's firmware stopped responding" ;;
        # 154 carries the action the driver wants (a reset is one of several)
        154)   printf 'gpu\tThe NVIDIA driver says the GPU needs recovery' ;;
        *)     printf 'game\tan error Pulsar has no description for (see docs.nvidia.com/deploy/xid-errors)' ;;
    esac
}

# A Steam app id -> its name, from the app manifest in whichever library has
# it (Flatpak Steam, then a native one). libraryfolders.vdf lists every
# library, the one beside it included. Prints nothing when not found.
steam_app_name() {
    local id=$1 root lib f n
    for root in "${HOME:-/nonexistent}/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
                "${HOME:-/nonexistent}/.local/share/Steam" "${HOME:-/nonexistent}/.steam/steam"; do
        [ -r "${root}/steamapps/libraryfolders.vdf" ] || continue
        while IFS= read -r lib; do
            f="${lib}/steamapps/appmanifest_${id}.acf"
            [ -r "$f" ] || continue
            n=$(sed -nE '/^[[:space:]]*"name"[[:space:]]+"(.*)"[[:space:]]*$/{s//\1/p;q}' "$f")
            if [ -n "$n" ]; then printf '%s\n' "$n"; return 0; fi
        done < <(sed -nE 's/^[[:space:]]*"path"[[:space:]]+"(.*)"[[:space:]]*$/\1/p' "${root}/steamapps/libraryfolders.vdf")
    done
    return 0
}

# pid comm -> "name<TAB>game", game 1 for a Steam game or a Windows one (an
# .exe on its command line: Proton, Faugus, any Wine). The name: Steam's for its app, else the .exe it runs, else the
# thread name the driver logged. Asked while the process is still running;
# after it has gone, the thread name is all there is.
gpu_fault_who() {
    local pid=$1 name="" game=0 env="" app="" a
    local -a args=()
    if [ -r "${GPU_FAULT_PROC}/${pid}/environ" ]; then
        env=$(tr '\0' '\n' < "${GPU_FAULT_PROC}/${pid}/environ" 2>/dev/null) || env=""
        app=$(printf '%s\n' "$env" | sed -n '/^SteamAppId=/{s///p;q}')
        case "$app" in ''|0|*[!0-9]*) app="" ;; *) game=1; name=$(steam_app_name "$app") ;; esac
    fi
    if [ -r "${GPU_FAULT_PROC}/${pid}/cmdline" ]; then
        mapfile -d '' -t args < "${GPU_FAULT_PROC}/${pid}/cmdline" 2>/dev/null || args=()
        for a in "${args[@]}"; do
            case "$a" in
                *.[eE][xX][eE])
                    game=1
                    if [ -z "$name" ]; then a=${a##*/}; a=${a##*\\}; name=${a%.[eE][xX][eE]}; fi ;;
            esac
        done
    fi
    [ -n "$name" ] || name=$2
    # "Ignore this" stores it as a pattern, where a / means a path
    printf '%s\t%s\n' "${name//\//-}" "$game"
}

GPU_FAULT_ADVICE="If a game keeps doing it, turn off DLSS in its settings if it has it. If its launch options set DXVK_CONFIG, that replaces Pulsar's dxvk.enableDescriptorHeap = False, so add that to yours."

# The advice, for the Xids the known cases tie to a cause: Hell Is Us faulted
# with Xid 13 and Xid 109 until DLSS was off (see above). Boltgun and Sins of
# a Solar Empire II (DirectX 11, no DLSS) hung with Xid 109, then Xid 31, on
# DXVK's descriptor heap, which steam-grants.sh turns off for Steam's and
# Faugus's games; a DXVK_CONFIG of the game's own replaces that. Nothing for
# other Xids.
gpu_fault_advice() {
    case "$1" in 13|109) printf '%s' "$GPU_FAULT_ADVICE" ;; esac
}

gpu_fault_boot() { cat "${PULSAR_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null || echo unknown; }

# One Xid as the watcher sees it: named, remembered for doctor, and announced
# once per program per boot (a game that faults every launch is one piece of
# news an evening). The state file holds this boot's faults, one per process:
# boot <TAB> pid <TAB> xid <TAB> name. pid is "-" for the GPU itself and "?"
# for a program the driver did not name.
gpu_fault_event() {
    local xid=$1 pid=$2 comm=$3 kind what name game boot state="${UPDATE_STATE}/gpu-faults" rows=""
    IFS=$'\t' read -r kind what <<<"$(xid_meaning "$xid")"
    [ "$kind" != skip ] || return 0
    # A program's fault without its pid is a detail line of one already seen.
    [ -n "$pid" ] || [ "$kind" = gpu ] || return 0
    if [ -z "$pid" ]; then
        pid=- name="the GPU" game=0
    elif [ "$pid" = "?" ]; then
        name="" game=0
    else
        IFS=$'\t' read -r name game <<<"$(gpu_fault_who "$pid" "$comm")"
    fi
    boot=$(gpu_fault_boot)
    [ -r "$state" ] && rows=$(awk -F'\t' -v b="$boot" '$1 == b' "$state")
    # Once per program: the Xid 43 after an Xid 13 is the same fault. By pid
    # as well as by name: once the game has gone, a later Xid from its pid
    # resolves only to its thread's name ("GameThread") and is still the same
    # program. The GPU itself, and a program the driver did not name, once
    # per Xid.
    local news=1
    printf '%s\n' "$rows" | awk -F'\t' -v n="$name" -v x="$xid" -v p="$pid" '
        p == "-" || p == "?" { if ($2 == p && $3 == x) f = 1; next }
        $2 == p || ($4 == n && n != "") { f = 1 }
        END { exit !f }' && news=0
    mkdir -p "$UPDATE_STATE" \
        && printf '%s\n%s\t%s\t%s\t%s\n' "$rows" "$boot" "$pid" "$xid" "$name" | awk 'NF' > "$state"
    [ "$news" = 1 ] || return 0
    case "$pid" in
        -|"?") pid="" ;;
        *) ! crash_ignored "$name" || return 0 ;;
    esac
    gpu_fault_notify_one "$xid" "$kind" "$what" "$name" "$game" "$pid"
}

gpu_fault_notify_one() {
    local xid=$1 kind=$2 what=$3 name=$4 game=$5 title body q
    # $6: the pid, when a program faulted
    have notify-send || return 0
    if [ "$kind" = gpu ]; then
        title=$what
        body="Xid ${xid}. If apps stop drawing, save what you can and restart. Details: pulsar doctor gpu-faults"
        q="The NVIDIA driver logged Xid ${xid} (${what}). Explain what it means on this machine and whether it points to the driver, the GPU or its power, and what I should do."
    elif [ -z "$name" ]; then
        # The driver did not log which program: say what happened, name none.
        title="A program hit a GPU fault"
        body="Xid ${xid}: ${what}. The NVIDIA driver did not log which program."
        [ -z "$(gpu_fault_advice "$xid")" ] || body+=" $(gpu_fault_advice "$xid")"
        body+=" Details: pulsar doctor gpu-faults"
        q="A program hit an NVIDIA GPU fault (Xid ${xid}, ${what}) and the driver did not log which; pulsar doctor gpu-faults lists this boot's. Explain what this Xid means, how to find which program it was, and what to try."
    else
        title="${name} hit a GPU fault"
        body="Xid ${xid}: ${what}."
        [ "$game" != 1 ] || [ -z "$(gpu_fault_advice "$xid")" ] || body+=" $(gpu_fault_advice "$xid")"
        body+=" Details: pulsar doctor gpu-faults"
        q="${name} hit an NVIDIA GPU fault (Xid ${xid}, ${what}); pulsar doctor gpu-faults lists this boot's. Explain what this Xid means, search for reports of it with ${name} and this driver, and tell me what to try."
    fi
    if ! have systemd-run; then
        notify-send --app-name="Pulsar" --icon=dialog-warning "$title" "$body" || true
        return 0
    fi
    local self agent="" ask="" unit
    self=$(realpath "$SELF")
    if agent=$(agent_default_name 2>/dev/null) && agent_row "$agent"; then
        ask="Ask ${A_DESC%% (*}"
    fi
    # one unit per fault: the pid, or for the GPU itself the Xid and this run
    unit=pulsar-gpu-fault-${6:-xid${xid}-$$}
    # The buttons outlive the watcher's own work, as crash_notify_one's do.
    # Each button only when it has something to act on: Ask when an agent is
    # installed ($1), Ignore when there is a program to ignore ($6). The GPU
    # itself and a program the driver did not name have none, and `crashes
    # ignore add ""` is an error.
    # shellcheck disable=SC2016  # expanded by the transient unit's sh, not here
    local script='if [ -n "$1" ] && [ -n "$6" ]; then
    a=$(notify-send --app-name=Pulsar --icon=dialog-warning --action=ask="$1" --action=ignore="Ignore this" "$2" "$3") || exit 0
elif [ -n "$1" ]; then
    a=$(notify-send --app-name=Pulsar --icon=dialog-warning --action=ask="$1" "$2" "$3") || exit 0
elif [ -n "$6" ]; then
    a=$(notify-send --app-name=Pulsar --icon=dialog-warning --action=ignore="Ignore this" "$2" "$3") || exit 0
else
    exec notify-send --app-name=Pulsar --icon=dialog-warning "$2" "$3"
fi
case "$a" in
    ask) [ -z "$1" ] || exec ptyxis -s --new-window -d "$HOME" -- "$5" agent ask "$4" ;;
    ignore) [ -z "$6" ] || exec "$5" crashes ignore add "$6" ;;
esac'
    local ign=$name
    [ "$kind" != gpu ] || ign=""
    systemd-run --user --collect --quiet --unit="$unit" \
        -- sh -c "$script" sh "$ask" "$title" "$body" "$q" "$self" "$ign" 2>/dev/null || true
}

# Follow the kernel log for the length of the desktop session.
gpu_faults_watch() {
    gpu_faults_apply || return 0
    have journalctl || return 0
    local line xid pid comm
    while IFS= read -r line; do
        case "$line" in *"NVRM: Xid "*) ;; *) continue ;; esac
        IFS=$'\t' read -r xid pid comm <<<"$(printf '%s\n' "$line" | xid_parse)"
        [ -n "$xid" ] || continue
        gpu_fault_event "$xid" "$pid" "$comm" || true
    done < <(journalctl -k -f -n 0 -o cat --no-pager 2>/dev/null)
}

# the nvidia image, with the driver loaded
gpu_faults_apply() {
    case "$(mf variant)" in *nvidia*) ;; *) return 1 ;; esac
    grep -q '^nvidia ' "${PULSAR_PROC_MODULES:-/proc/modules}" 2>/dev/null
}

check_gpu_faults() {
    gpu_faults_apply || return 0
    have journalctl || return 0
    local out err
    err=$(mktemp)
    out=$(journalctl -k -b -o cat --no-pager 2>"$err" | xid_parse) || true
    if grep -qi 'insufficient permissions\|permission denied\|not seeing messages' "$err"; then
        rm -f "$err"
        record gpu-faults warn "cannot read the kernel log" \
            "join the wheel, adm or systemd-journal group, or run: sudo pulsar doctor gpu-faults"
        return 0
    fi
    rm -f "$err"
    # names the watcher found while the programs were running
    local boot names="" state="${UPDATE_STATE}/gpu-faults"
    boot=$(gpu_fault_boot)
    [ -r "$state" ] && names=$(awk -F'\t' -v b="$boot" '$1 == b { print $2 "\t" $4 }' "$state")
    local list
    list=$(printf '%s\n' "$out" | while IFS=$'\t' read -r xid pid comm; do
        [ -n "$xid" ] || continue
        IFS=$'\t' read -r kind what <<<"$(xid_meaning "$xid")"
        case "$kind" in skip) continue ;; gpu) ;; *) [ -n "$pid" ] || continue ;; esac
        if [ -z "$pid" ] || { [ "$pid" = "?" ] && [ "$kind" = gpu ]; }; then
            printf -- '-\t%s\t%s\t%s\n' "$xid" "GPU" "$what"
        elif [ "$pid" = "?" ]; then
            printf '?\t%s\t%s\t%s\n' "$xid" "an unnamed program" "$what"
        else
            n=$(printf '%s\n' "$names" | awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }')
            printf '%s\t%s\t%s\t%s\n' "$pid" "$xid" "${n:-$comm}" "$what"
        fi
    # One per process. An unnamed program's: one per run of the same Xid, as
    # every line of one such fault carries the "<unknown>".
    done | awk -F'\t' '$1 == "-" { last = ""; print; next }
        $1 == "?" { if (last != $2) print; last = $2; next }
        { last = "" } !seen[$1]++')
    if [ -z "$list" ]; then
        record gpu-faults ok "no GPU faults this boot"
        return 0
    fi
    local n summary detail
    n=$(printf '%s\n' "$list" | grep -c .)
    summary=$(printf '%s\n' "$list" | awk -F'\t' '{ k = $3 " (Xid " $2 ")"; if (!c[k]++) o[++m] = k }
        END { for (i = 1; i <= m; i++) printf "%s%s%s", (i > 1 ? ", " : ""), o[i], (c[o[i]] > 1 ? " x" c[o[i]] : "") }')
    detail=$(printf '%s\n' "$list" | awk -F'\t' '{ k = "Xid " $2 ": " $4; if (!s[k]++) printf "%s%s", (n++ ? "; " : ""), k }')
    local advice=""
    if printf '%s\n' "$list" | awk -F'\t' '$2 == 13 || $2 == 109 { f = 1 } END { exit !f }'; then
        advice=" ${GPU_FAULT_ADVICE}"
    fi
    record gpu-faults warn "${n} GPU fault(s) this boot: ${summary}" "${detail}.${advice}"
}

report_help() {
    cat <<'EOF'
usage: pulsar report [--text] [--lines N] [--crash <pid|latest>]

A diagnosis bundle to paste into an issue or hand to a coding agent. JSON by
default; --text renders the same data for people. No root needed, though
without it (or wheel, adm or systemd-journal membership) the system journal may be
unreadable, which the report then says.

Included
  doctor      `pulsar doctor --json`
  status      deployments from `rpm-ostree status --json`: booted, staged,
              pinned, version, timestamp, checksum, image and digest, and
              layered packages
  manifest    `pulsar manifest --json`, host facts included
  units       failed system units and failed user units, by name
  journal     this boot's warning+ lines, last N (default 50, max 500), from
              pulsar-*, greenboot*, akmods*, gamescale* and the failed units:
              time, unit, priority and message only
  graphics    kernel release, taint, command line, loaded NVIDIA driver
              version, GPU names, display devices and the driver bound to
              each, Secure Boot state
  flatpak     remotes with their options, app IDs with branch, origin and
              installation, runtime count
  crash       with --crash: one of your crashes as systemd-coredump recorded
              it: program, signal, package, unit, command line, the crashing
              thread's stack trace (up to 40 frames), and that process's last
              30 journal lines. Never the core file itself

Not included
  the full journal, anything from a previous boot, environment variables,
  the machine ID, file contents from $HOME or /etc, Flatpak app data

Redacted, best effort
  the hostname (not a stock one: fedora, localhost, pulsar, silverblue,
  toolbox), your username and home path (as ~), MAC and IPv4 addresses,
  email addresses, values after words like token=, password:, api_key=,
  Authorization and Bearer, and tokens recognizable by their prefix (GitHub
  ghp_/github_pat_, GitLab glpat-, sk- API keys, Slack xox*-, AWS AKIA,
  JWTs). Journal messages are free text: read the report before posting it.
EOF
}

# Failed units as a JSON array of names. --plain drops the bullet, so the name
# is the first field; --no-legend drops the header and footer.
failed_units_json() {
    have systemctl || { printf '[]'; return 0; }
    # `|| true`: with no user bus (ssh, a bare TTY, a container)
    # `systemctl --user` exits nonzero, pipefail carries that out of the
    # pipeline, and set -e ended the whole report in silence at the caller.
    # jq has still printed its (empty) array by then.
    systemctl "$@" --failed --plain --no-legend --no-pager 2>/dev/null \
        | awk '$1 ~ /\./ { print $1 }' | jq -R -s -c 'split("\n") | map(select(length > 0))' || true
}

# $1 = system|user, $2 = line cap, $3 = JSON array of extra units.
# -o json and a field pick rather than -o short: the short format leads every
# line with the hostname, and redacting it afterwards would be cleaning up a
# leak this can simply not make.
journal_json() {
    local scope=$1 lines=$2 extra=$3
    have journalctl || { printf '{"lines":[],"note":"journalctl not available"}'; return 0; }
    local -a args=(--no-pager -b -p warning -n "$lines" -o json)
    # -u matches the SYSTEM unit field; a user unit's lines carry its name in
    # _SYSTEMD_USER_UNIT, which only --user-unit matches.
    local sel=-u u
    if [ "$scope" = user ]; then args+=(--user); sel=--user-unit; fi
    for u in 'pulsar-*' 'greenboot*' 'akmods*' 'gamescale*'; do args+=("$sel" "$u"); done
    while IFS= read -r u; do
        if [ -n "$u" ]; then args+=("$sel" "$u"); fi
    done < <(printf '%s' "$extra" | jq -r '.[]')
    local out err note=""
    err=$(mktemp)
    out=$(journalctl "${args[@]}" 2>"$err") || true
    # A user outside wheel/adm/systemd-journal does not get an error: journalctl
    # opens their own journal and only hints that the rest is hidden. That
    # hint counts too, or an empty section reads as "no warnings".
    if grep -qi 'insufficient permissions\|permission denied\|not seeing messages from other users' "$err"; then
        note="the ${scope} journal is not readable by this user; run as root or join the wheel, adm or systemd-journal group"
    fi
    rm -f "$err"
    printf '%s' "$out" | jq -s -c --arg note "$note" '{
        lines: map({
            time: ((.__REALTIME_TIMESTAMP // "0") | tonumber / 1000000 | floor | todate),
            # UNIT/USER_UNIT name the unit a systemd message is ABOUT; without
            # them every "Failed to start x" is attributed to init.scope.
            unit: (.UNIT // .USER_UNIT // ._SYSTEMD_USER_UNIT // ._SYSTEMD_UNIT // .SYSLOG_IDENTIFIER // "?"),
            priority: ((.PRIORITY // "?") | tostring),
            message: (.MESSAGE | if type == "string" then . else "<binary message>" end)
        })
      } + (if $note == "" then {} else {note: $note} end)' 2>/dev/null \
      || printf '{"lines":[],"note":"journal output could not be parsed"}'
}

graphics_json() {
    local kernel taint cmdline nv sb=""
    kernel=$(uname -r 2>/dev/null) || kernel=""
    taint=$(cat /proc/sys/kernel/tainted 2>/dev/null) || taint=""
    cmdline=$(cat /proc/cmdline 2>/dev/null) || cmdline=""
    nv=$(cat /sys/module/nvidia/version 2>/dev/null) || nv=""
    if have mokutil; then sb=$(mokutil --sb-state 2>/dev/null | head -1) || sb=""; fi
    # One entry per display-class device with the driver actually bound to it,
    # which is the fact lspci alone does not give and the first question in
    # every "which GPU is rendering" thread.
    local d devs="" cls
    for d in /sys/bus/pci/devices/*; do
        cls=$(cat "$d/class" 2>/dev/null) || continue
        case "$cls" in
            0x03*)
                devs+=$(jq -n -c --arg slot "${d##*/}" \
                    --arg id "$(cat "$d/vendor" 2>/dev/null):$(cat "$d/device" 2>/dev/null)" \
                    --arg drv "$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)" \
                    '{slot: $slot, id: $id, driver: $drv}'),
                ;;
        esac
    done
    local names
    names=$(gpu_names 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length > 0))') || names='[]'
    jq -n -c --arg k "$kernel" --arg t "$taint" --arg c "$cmdline" --arg nv "$nv" --arg sb "$sb" \
          --argjson devs "[${devs%,}]" --argjson names "${names:-[]}" '
        { kernel: $k, tainted: ($t | tonumber? // $t), cmdline: $c,
          nvidia_driver: (if $nv == "" then null else $nv end),
          secure_boot: (if $sb == "" then null else $sb end),
          gpu_names: $names, display_devices: $devs }'
}

flatpak_json() {
    have flatpak || { printf 'null'; return 0; }
    local remotes apps runtimes
    remotes=$(flatpak remotes --columns=name,url,options 2>/dev/null | jq -R -s -c '
        split("\n") | map(select(length > 0) | split("\t")
          | {name: .[0], url: (.[1] // ""), options: (.[2] // "")})') || remotes='[]'
    apps=$(flatpak list --app --columns=application,branch,origin,installation 2>/dev/null | jq -R -s -c '
        split("\n") | map(select(length > 0) | split("\t")
          | {id: .[0], branch: (.[1] // ""), origin: (.[2] // ""), installation: (.[3] // "")})') || apps='[]'
    runtimes=$(flatpak list --runtime --columns=application 2>/dev/null | grep -c . || true)
    jq -n -c --argjson r "${remotes:-[]}" --argjson a "${apps:-[]}" --argjson n "${runtimes:-0}" \
        '{remotes: $r, apps: $a, app_count: ($a | length), runtime_count: $n}'
}

# The redaction pass, over every string in the finished document. Literal
# split/join rather than regex for the identifying values: a hostname carries
# dots, and a regex built from one would match more than the hostname.
# shellcheck disable=SC2016  # a jq program: its $names are jq's, not the shell's
JQ_REDACT='
  def lit(a; b): if (a | length) == 0 then . else split(a) | join(b) end;
  def scrub:
      # Secrets by shape, first, before the username pass can split an
      # address or a token around "<user>". An HTTP credential keeps its
      # scheme: "Authorization: Bearer abc" used to lose only the word
      # "Bearer" to the key rule below, and the token after it survived.
      gsub("(?<k>\\b(bearer|basic)\\s+)[A-Za-z0-9._~+/=-]{8,}"; "\(.k)<redacted>"; "i")
    # Tokens whose prefix says what they are, wherever they sit: GitHub,
    # GitLab, OpenAI/Anthropic-style sk- keys, Slack, AWS access key ids.
    | gsub("\\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16})"; "<redacted>")
    # A JWT: three base64url parts, the first always "eyJ" ({"...).
    | gsub("\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}"; "<redacted>")
    # An email address needs a dotted domain ending in letters. A systemd
    # instance unit has the same shape (user@1000.service, getty@tty1.service),
    # so a unit-type suffix is never a top-level domain here; and user@host
    # with no dot, as a shell prompt prints it, is left alone.
    | gsub("[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\\.)+(?!(?:service|socket|timer|target|mount|automount|slice|scope|path|device|swap)\\b)[A-Za-z]{2,}\\b"; "<email>")
      # a HOME of "/" would otherwise turn every slash into a tilde
    | lit(if ($home | length) > 1 then $home else "" end; "~")
    | reduce ($users[] | select(length > 0)) as $u (.;
        lit("/var/home/" + $u; "~") | lit("/home/" + $u; "~")
        | if ($u | length) >= 3 and ($u | test("^[a-z_][a-z0-9_-]*$"))
          then gsub("\\b" + $u + "\\b"; "<user>") else . end)
    # The hostname as a whole name only, never inside another word: a machine
    # called "pulsar" must not turn "pulsar-nvidia" into "<hostname>-nvidia".
    # Names that identify nobody and occur all over this report (the Fedora
    # fallback "fedora", localhost) are not redacted at all: on a stock
    # install they mangled the base image, the remotes and the manifest.
    | if ($host | length) == 0 or ($host | ascii_downcase | IN("fedora", "localhost", "localhost.localdomain", "pulsar", "silverblue", "toolbox"))
      then .
      else gsub("(?<![A-Za-z0-9_-])" + ($host | gsub("(?<c>[.*+?^${}()|\\[\\]\\\\])"; "\\\(.c)")) + "(?![A-Za-z0-9_-])"; "<hostname>")
      end
    # The value after a key, unless it is a credential scheme the first rule
    # already handled ("Authorization: Bearer <redacted>" stays readable).
    | gsub("(?<k>(token|secret|passw(or)?d|api[_-]?key|authorization|bearer)[\"'"'"'=: ]+)(?!<redacted>)(?!(?:bearer|basic)\\s)[^\\s\"'"'"',;]+"; "\(.k)<redacted>"; "i")
    | gsub("\\b([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\\b"; "<mac>")
    | gsub("\\b(?!127\\.)([0-9]{1,3}\\.){3}[0-9]{1,3}\\b"; "<ipv4>");
  walk(if type == "string" then scrub else . end)'

cmd_report() {
    local text=0 lines=50 crash=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --text) text=1 ;;
            --crash) [ $# -ge 2 ] || die "--crash wants a PID or 'latest'"; shift; crash=$1 ;;
            --crash=*) crash=${1#--crash=} ;;
            --lines) [ $# -ge 2 ] || die "--lines wants a number"; shift; lines=$1 ;;
            --lines=*) lines=${1#--lines=} ;;
            -h|--help) report_help; return 0 ;;
            *) die "'report' does not take '$1' (see: pulsar report --help)" ;;
        esac
        shift
    done
    case "$lines" in ''|*[!0-9]*) die "--lines wants a number" ;; esac
    # A cap, not a default: the point is a summary someone will read, and a
    # thousand lines of journal is where tokens and addresses hide.
    [ "$lines" -ge 1 ] && [ "$lines" -le 500 ] || die "--lines must be 1..500"

    local doctor status manifest fsys fusr jsys jusr gfx fp
    doctor=$(json_or_null env NO_COLOR=1 "$SELF" doctor --json)
    if have rpm-ostree; then
        status=$(json_or_null rpm-ostree status --json)
        status=$(printf '%s' "$status" | jq -c "if . == null then null else ${STATUS_JQ} end")
    else
        status=null
    fi
    manifest=$(json_or_null "$SELF" manifest --json --no-logo)
    fsys=$(failed_units_json)
    fusr=$(failed_units_json --user)
    jsys=$(journal_json system "$lines" "$fsys")
    jusr=$(journal_json user "$lines" "$fusr")
    gfx=$(graphics_json)
    fp=$(flatpak_json)
    # Resolved on a line of its own: a die inside a nested $(...) would only
    # end that subshell, and the report would go out with no crash in it.
    local cr=null cpid
    if [ -n "$crash" ]; then
        cpid=$(crash_resolve "$crash") || exit 1
        cr=$(crash_json "$cpid")
    fi

    local host users
    host=${PULSAR_REPORT_HOSTNAME:-$(cat /proc/sys/kernel/hostname 2>/dev/null || true)}
    # Never "root": under sudo it is id -un, and redacting the word turned
    # `root=UUID=...` on the kernel command line into `<user>=UUID=...`.
    users=$(printf '%s\n%s\n' "$(id -un 2>/dev/null || true)" "${SUDO_USER:-}" \
            | jq -R -s -c 'split("\n") | map(select(length > 0 and . != "root")) | unique')

    local js
    js=$(jq -n -c \
        --arg version "$VERSION" --argjson lines "$lines" \
        --argjson doctor "$doctor" --argjson status "$status" --argjson manifest "$manifest" \
        --argjson fsys "$fsys" --argjson fusr "$fusr" \
        --argjson jsys "$jsys" --argjson jusr "$jusr" \
        --argjson gfx "$gfx" --argjson fp "$fp" --argjson cr "$cr" '
        { report: { schema: 1, tool: ("pulsar " + $version),
                    generated: (now | floor | todate), journal_lines: $lines,
                    note: "hostname, username, home path, MAC/IPv4, email addresses and secret-shaped values are redacted; best effort" },
          doctor: $doctor, status: $status, manifest: $manifest,
          units: { failed_system: $fsys, failed_user: $fusr },
          journal: { system: $jsys, user: $jusr },
          graphics: $gfx, flatpak: $fp }
        + (if $cr == null then {} else {crash: $cr} end)' \
      | jq -c --arg home "${HOME:-}" --arg host "$host" --argjson users "$users" "$JQ_REDACT") \
      || die "could not assemble the report"

    if [ "$text" = 0 ]; then printf '%s\n' "$js" | jq .; return 0; fi
    printf '%s\n' "$js" | jq -r '
      def rows(f): if (f | length) == 0 then "  (none)" else (f[] | "  " + .) end;
      "pulsar report  \(.report.generated)  (\(.report.tool))",
      "", "doctor: \(if .doctor.ok then "no failures" elif .doctor == null then "unavailable" else "failures" end)",
      rows([.doctor.checks[]? | "\(.status)\t\(.id)\t\(.summary)"]),
      "", "deployments",
      rows([.status.deployments[]? | "\(if .booted then "booted" elif .staged then "staged" else "-" end)\t\(.version // "?")\t\(if .pinned then "pinned" else "" end)"]),
      "", "image: \(.manifest.image // "?") \(.manifest.variant // "") \(.manifest.version // "?")",
      "kernel: \(.graphics.kernel)  tainted: \(.graphics.tainted)  nvidia: \(.graphics.nvidia_driver // "-")",
      rows([.graphics.display_devices[]? | "\(.slot)  \(.id)  driver=\(.driver)"]),
      "", "failed units",
      rows([(.units.failed_system[]? | "system  " + .), (.units.failed_user[]? | "user    " + .)]),
      "", "journal (warning+, this boot)",
      rows([(.journal.system.lines[]?, .journal.user.lines[]?) | "\(.time)  \(.unit)  \(.message)"]),
      (if .journal.system.note then "  note: \(.journal.system.note)" else empty end),
      "", "flatpak: \(.flatpak.app_count // 0) apps, \(.flatpak.runtime_count // 0) runtimes",
      rows([.flatpak.remotes[]? | "remote \(.name)  \(.url)  \(.options)"]),
      (if .crash then
        "", "crash: \(.crash.executable // "?")  pid \(.crash.pid // "?")  \(.crash.signal // "")",
        "  \(.crash.time // "")  package: \(.crash.package // "-")  unit: \(.crash.unit // "-")",
        rows(.crash.stack // []),
        rows([.crash.journal[]? | "\(.time)  \(.message)"])
       else empty end),
      "", .report.note'
}
