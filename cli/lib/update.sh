# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): pulsar update, rollback and pin, and the update notifications.

# ---------------------------------------------------------------------------
# Lifecycle. These mutate, so they need root. rollback, pin and unpin hand
# straight to the tool that owns the deployment; update has to pick one.
# ---------------------------------------------------------------------------
# update -- the same intent, through whichever tool can actually honour it.
#
# bootc's model is the container image and nothing else. It does not know that
# `rpm-ostree install 1password` added a layer on top of that image, so an
# upgrade through bootc does not carry the layer forward: the packages you
# installed are not in the deployment it stages. rpm-ostree does know, because
# it wrote the origin, and its upgrade re-pulls the same container image and
# re-applies the layer on top.
#
# So this asks the deployment which it is, rather than making the user
# remember. An unlayered system -- the shipped default -- still goes through
# bootc, which is the tool that owns it.
#
# Unreadable status is fatal rather than a guess. Guessing bootc on a layered
# system throws the layer away, and you find out at the next boot.
# ---------------------------------------------------------------------------
# `update --check` answers the question itself instead of handing it to bootc
# or rpm-ostree, and that is the entire reason it lives here.
#
# On a deployment with layered packages, `rpm-ostree upgrade --check` reports
# "No updates available" no matter what the registry holds. Its container
# query reads ostree.manifest-digest off the deployment's own commit, and the
# merge commit layering produces does not carry that key -- only the base
# commit underneath it does. The query fails, the transaction still reports
# success, and the result is a false negative. GNOME Software reaches the same
# dead end through the same AutomaticUpdateTrigger call, which is why a
# layered system can sit on a stale image for weeks with nothing on screen
# ever saying so.
#
# Nothing about the comparison is hard, and rpm-ostree hands over both halves
# unprivileged: container-image-reference-digest is the manifest the booted
# deployment was built from, and it stays correct under layering. So ask the
# registry what the tag resolves to now and compare. One HTTP round trip, no
# root, no daemon.
#
# Exit status IS the answer, because a timer reads it: 0 up to date (or the
# update is already staged), 10 an update is available, 1 the question could
# not be answered. `bootc upgrade --check` needs root even to read and would
# be wrong here anyway, so --check never routes there.
# ---------------------------------------------------------------------------
UPDATE_STATE=${PULSAR_UPDATE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/pulsar}

# NVIDIA HELD BACK. Since 2026-11-11 a night whose nvidia image did not build
# ships vanilla alone, and an nvidia machine's own tag does not move: asked
# alone, it would say "up to date" while every other machine updated. So an
# nvidia image also asks what the vanilla tag beside it carries, and vanilla
# ahead means this machine was held back. The reason comes from the published
# changelog (held.nvidia), trusted only when that changelog describes the
# vanilla build the tag points at; otherwise the versions alone.
#
# $1 this image's ref, $2 its version. Prints "<vanilla version>\t<vanilla
# digest>\t<reason>" when held back, nothing otherwise, and never fails: the
# answer to the update question does not depend on it.
held_nvidia() {
    local ref=$1 mine=$2 sib inspect v d url reason=""
    case "$ref" in *-nvidia|*-nvidia:*) ;; *) return 0 ;; esac
    sib=$(printf '%s' "$ref" | sed 's|-nvidia\(:[^/]*\)\{0,1\}$|\1|')
    inspect=$(skopeo inspect --no-tags "docker://${sib}" 2>/dev/null) || return 0
    v=$(printf '%s' "$inspect" | jq -r '.Labels["org.opencontainers.image.version"] // ""')
    d=$(printf '%s' "$inspect" | jq -r '.Digest // ""')
    [ -n "$v" ] && [ "$v" != "$mine" ] || return 0
    [ "$(printf '%s\n%s\n' "$mine" "$v" | sort -V | tail -n1)" = "$v" ] || return 0
    url=$(mf changelog_url 2>/dev/null || true)
    if [ -n "$url" ] && have curl; then
        reason=$(curl -fsSL --max-time 10 "$url" 2>/dev/null \
            | jq -r --arg d "$d" 'if (.to.digest // "") == $d then (.held.nvidia // "") else "" end' 2>/dev/null || true)
    fi
    printf '%s\t%s\t%s\n' "$v" "$d" "$reason"
}

# The sentence a person reads, from held_nvidia's line and the booted version.
held_nvidia_sentence() {
    local v=$1 reason=$2 mine=$3
    if [ -n "$reason" ]; then
        printf 'Build %s shipped for other machines, but %s. This machine stays on %s until an nvidia image builds.' \
            "$v" "$reason" "$mine"
    else
        printf 'Build %s shipped without its nvidia image. This machine stays on %s until one builds.' "$v" "$mine"
    fi
}

cmd_update_check() {
    local notify=0 f
    for f in "$@"; do
        case "$f" in
            --check)  ;;
            --notify) notify=1 ;;
            *) die "'update --check' takes no other flags (got: ${f})" ;;
        esac
    done

    need rpm-ostree; need jq; need skopeo
    local js; js=$(rpm-ostree status --json 2>/dev/null) \
        || die "could not read deployment status"

    local booted='[ .deployments[]? | select(.booted == true) ][0]'
    local ref local_digest local_version
    # Same whole-transport strip as `status`: a single sub() left "docker://"
    # behind on "ostree-image-signed:docker://ghcr.io/...".
    ref=$(printf '%s' "$js" | jq -r "${booted} | (.\"container-image-reference\" // \"\") | sub(\"^([a-z-]+:)+(//)?\"; \"\")")
    local_digest=$(printf '%s' "$js" | jq -r "${booted} | .\"container-image-reference-digest\" // \"\"")
    local_version=$(printf '%s' "$js" | jq -r "${booted} | .version // \"?\"")

    [ -n "$ref" ] || die "the booted deployment is not container-native; there is no registry to ask"
    [ -n "$local_digest" ] || die "rpm-ostree reports no image digest for the booted deployment"
    # Asking the registry what a digest points at always answers "itself".
    local fix; fix=$(pinned_origin_fix "$js")
    [ -z "$fix" ] || die "this system follows one image digest, so no update can ever arrive; run: ${fix}"

    local inspect
    inspect=$(skopeo inspect --no-tags "docker://${ref}" 2>/dev/null) \
        || die "could not reach ${ref} to ask what it points at now"
    local remote_digest remote_version
    remote_digest=$(printf '%s' "$inspect" | jq -r '.Digest // ""')
    remote_version=$(printf '%s' "$inspect" | jq -r '.Labels["org.opencontainers.image.version"] // "?"')
    [ -n "$remote_digest" ] || die "${ref} returned a manifest with no digest"

    # --json: one object whatever the answer; the exit code still carries it.
    # $2, when given, is held_nvidia's line.
    check_json() {
        local hv="" hr=""
        [ -z "${2:-}" ] || IFS=$'\t' read -r hv _ hr <<<"$2"
        jq -n -c --arg s "$1" --arg b "$local_version" --arg l "$remote_version" --arg r "$ref" \
            --arg hv "$hv" --arg hr "$hr" \
            '{status: $s, booted: $b, latest: $l, image: $r, staged: ($s == "staged")}
             + (if $hv == "" then {} else {held: {vanilla: $hv, reason: (if $hr == "" then null else $hr end)}} end)'
    }

    if [ "$remote_digest" = "$local_digest" ]; then
        local held hv hr
        held=$(held_nvidia "$ref" "$local_version")
        if [ -n "$held" ]; then
            IFS=$'\t' read -r hv _ hr <<<"$held"
            # Once per build this machine is held on, not once a night.
            [ "$notify" = 0 ] || held_notify_once "$local_digest" "$(held_nvidia_sentence "$hv" "$hr" "$local_version")"
        fi
        if [ "${JSON:-0}" = 1 ]; then check_json current "$held"; return 0; fi
        printf 'up to date: %s (%s)\n' "$local_version" "$ref"
        [ -z "$held" ] || printf 'nvidia held back: %s\n' "$(held_nvidia_sentence "$hv" "$hr" "$local_version")"
        return 0
    fi

    # An update already fetched is not an update to nag about. Without this the
    # timer would keep announcing the thing sitting in slot 0 waiting to boot.
    local staged_digest
    staged_digest=$(printf '%s' "$js" | jq -r '[ .deployments[]? | select(.staged == true) ][0] | ."container-image-reference-digest" // ""')
    if [ "$staged_digest" = "$remote_digest" ]; then
        # Staged by the background unit or the Update button: the one thing
        # left is a restart, so that is what the notification offers.
        [ "$notify" = 0 ] || update_notify_once staged "$remote_digest" "$remote_version" "$local_version" \
            "$(staged_release "$js")"
        if [ "${JSON:-0}" = 1 ]; then check_json staged; return 0; fi
        printf 'staged: %s (restart to use it)\n' "$remote_version"
        return 0
    fi

    if [ "${JSON:-0}" = 1 ]; then
        check_json available
    else
        printf 'update available: %s -> %s\n' "$local_version" "$remote_version"
    fi

    [ "$notify" = 0 ] || update_notify_once available "$remote_digest" "$remote_version" "$local_version"
    return 10
}

# ---------------------------------------------------------------------------
# The update notifications, once per published build each.
#
# "available" offers an Update button, which starts pulsar-update-stage.service
# (no password for a local admin: 50-pulsar-update.rules). "staged" offers a
# Restart button, which opens GNOME's own restart dialog -- the user confirms
# there, and nothing here ever reboots.
#
# With background staging on, "available" waits a day first. The background
# unit will usually have staged the build by then, and the user hears about it
# once, as "ready", instead of twice. A build that is still not staged after a
# day -- a laptop that lives on battery, a metered connection -- gets the
# Update button after all.
# ---------------------------------------------------------------------------
UPDATE_AUTO_GRACE=${PULSAR_UPDATE_AUTO_GRACE:-86400}

# The release (YY.M.N) the staged deployment carries, read from its own tree:
# the registry label is the build, and only the image knows its release.
# Prints nothing when that tree cannot be read.
staged_release() {
    local d
    d=$(printf '%s' "$1" | jq -r '[ .deployments[]? | select(.staged == true) ][0] // {}
        | if .osname and .checksum then "\(.osname)/deploy/\(.checksum).\(.serial // 0)" else "" end' 2>/dev/null) || d=""
    [ -n "$d" ] || return 0
    cat "${PULSAR_OSTREE_DEPLOY:-/ostree/deploy}/${d}/usr/share/pulsar/release" 2>/dev/null || true
}

update_auto_enabled() {
    have systemctl || return 1
    [ "$(systemctl is-enabled pulsar-update-auto.timer 2>/dev/null)" = enabled ]
}

# $1 kind (available|staged) $2 digest $3 new version $4 booted version
# $5 the staged release, when it could be read
# One notification per booted build that is held back: the hold can last a
# week of nights, and nothing about it changes from one to the next.
held_notify_once() {
    local digest=$1 body=$2 state_file="${UPDATE_STATE}/notified-held-digest" seen=""
    if [ -r "$state_file" ]; then seen=$(cat "$state_file"); fi
    [ "$seen" != "$digest" ] || return 0
    have notify-send || return 0
    mkdir -p "$UPDATE_STATE"
    notify-send --app-name="Pulsar" --icon=software-update-available "Nvidia update held back" "$body" || true
    printf '%s\n' "$digest" > "$state_file"
}

update_notify_once() {
    local kind=$1 digest=$2 version=$3 booted=$4 release=${5:-} state_file seen=""
    # "notified-digest" is the file every earlier release wrote for the
    # available notice; keeping the name keeps an upgraded machine from
    # announcing the same build again.
    case "$kind" in
        available) state_file="${UPDATE_STATE}/notified-digest" ;;
        staged)    state_file="${UPDATE_STATE}/notified-staged-digest" ;;
    esac
    if [ -r "$state_file" ]; then seen=$(cat "$state_file"); fi
    [ "$seen" != "$digest" ] || return 0
    mkdir -p "$UPDATE_STATE"

    if [ "$kind" = available ] && update_auto_enabled; then
        local since="${UPDATE_STATE}/available-since" first="" now d=""
        now=$(date +%s)
        if [ -r "$since" ]; then read -r d first < "$since" || true; [ "${d:-}" = "$digest" ] || first=""; fi
        if [ -z "$first" ]; then
            printf '%s %s\n' "$digest" "$now" > "$since"
            return 0
        fi
        [ $((now - first)) -ge "$UPDATE_AUTO_GRACE" ] || return 0
    fi

    update_notify_send "$kind" "$digest" "$version" "$booted" "$release"
    printf '%s\n' "$digest" > "$state_file"
}

# Stages the update through pulsar-update-stage.service and says how it
# ended, in a notification: the notification's Update button runs this, and
# so does `update --download` (Pulsar Settings' Download), each in a
# transient unit of its own, so the report comes whether or not whoever
# started it is still there. $1 the CLI, $2 the build, when known.
#
# A cancelled password prompt is the user saying no, not a failure. After a
# stage, the check runs again and posts "ready" itself, so there is one place
# that words it. Exits 1 when the stage failed, for `update --download`.
# shellcheck disable=SC2016  # expanded by the transient unit's sh
UPDATE_STAGE_SCRIPT='if err=$(systemctl start pulsar-update-stage.service 2>&1); then "$1" update --check --notify; exit 0; fi
case "$err" in *[Aa]uthenticat*|*"Access denied"*|*[Cc]ancel*) exit 0 ;; esac
if [ -n "${2:-}" ]; then what="Build $2"; else what="The update"; fi
notify-send --app-name=Pulsar --icon=dialog-warning "Pulsar update failed" "$what did not install. See why: journalctl -u pulsar-update-stage"
exit 1'

update_notify_send() {
    local kind=$1 digest=$2 version=$3 booted=$4 release=${5:-} title body
    have notify-send || return 0
    if [ "$kind" = available ]; then
        # The registry says only the build; the release is inside the image.
        title="Pulsar update available"
        body="Build ${version} is out. You have ${booted}. Update downloads it."
    else
        title="Pulsar update ready"
        # The release only when it differs from the booted one (VERSION);
        # unread, the build alone, which is true either way.
        if [ -n "$release" ] && [ "$release" != "$VERSION" ]; then
            body="Restart to use ${release} (build ${version})."
        else
            body="Restart to use build ${version}."
        fi
    fi
    # The click has to outlive this oneshot unit, so the waiting notification
    # runs as a transient unit of its own, as crash_notify_one's does. Without
    # systemd-run it still says what to do, just without the button.
    if ! have systemd-run || { [ "$kind" = staged ] && ! have gnome-session-quit; }; then
        if [ "$kind" = available ]; then
            body="Build ${version} is out. You have ${booted}. To download it, run: sudo pulsar update"
        fi
        notify-send --app-name="Pulsar" --icon=software-update-available "$title" "$body" || true
        return 0
    fi
    local script unit="pulsar-update-${kind}-${digest#sha256:}"
    unit=${unit:0:48}
    if [ "$kind" = available ]; then
        # shellcheck disable=SC2016  # expanded by the transient unit's sh
        script='a=$(notify-send --app-name=Pulsar --icon=software-update-available --action=update=Update "$1" "$2") || exit 0
[ "$a" = update ] || exit 0
shift 2
'"$UPDATE_STAGE_SCRIPT"
    else
        # gnome-session-quit shows GNOME's restart dialog; the user confirms
        # there. This never reboots on its own.
        # shellcheck disable=SC2016
        script='a=$(notify-send --app-name=Pulsar --icon=software-update-available --action=restart=Restart "$1" "$2") || exit 0
[ "$a" = restart ] || exit 0
exec gnome-session-quit --reboot'
    fi
    systemd-run --user --collect --quiet --unit="$unit" \
        -- sh -c "$script" sh "$title" "$body" "$(realpath "$SELF")" "$version" 2>/dev/null || true
}

# update --download: what the notification's Update button does, for Pulsar
# Settings' Download button. The stage runs in a transient unit, so closing
# the window neither stops it nor loses its report; this waits for it, so a
# window still open can show the result too. Exit 0 staged (or the password
# prompt dismissed), 1 failed.
update_download() {
    need_user "update --download"
    have systemd-run || die "'update --download' needs systemd-run; run: sudo pulsar update"
    systemd-run --user --wait --collect --quiet --unit="pulsar-update-download-$$" \
        -- sh -c "$UPDATE_STAGE_SCRIPT" sh "$(realpath "$SELF")"
}

# ---------------------------------------------------------------------------
# update --background -- pulsar-update-auto.service's job: stage a newer image
# if there is one and now is a good time, and otherwise say in one line why
# not. Every "not now" exits 0; the next run asks again.
# ---------------------------------------------------------------------------
POWER_SUPPLY_DIR=${PULSAR_POWER_SUPPLY_DIR:-/sys/class/power_supply}

# Prints why not to stage right now, or nothing (and fails) if it is fine.
update_background_blocker() {
    # On battery: systemd's ConditionACPower reading. A machine with no AC
    # connector at all (most desktops report none) counts as plugged in; one
    # with connectors counts as on battery only when none of them is online.
    local d type connectors=0 online=0
    for d in "$POWER_SUPPLY_DIR"/*; do
        [ -r "$d/type" ] || continue
        type=$(cat "$d/type" 2>/dev/null) || continue
        case "$type" in Mains|USB*) ;; *) continue ;; esac
        [ "$(cat "$d/scope" 2>/dev/null)" = Device ] && continue
        connectors=$((connectors + 1))
        [ "$(cat "$d/online" 2>/dev/null)" = 1 ] && online=1
    done
    if [ "$connectors" -gt 0 ] && [ "$online" = 0 ]; then
        echo "on battery power"; return 0
    fi
    # Metered: NetworkManager's own verdict for the primary connection.
    # 1 = yes, 3 = guessed yes (a phone hotspot); 0 unknown and 2/4 no.
    local m
    if have busctl && m=$(busctl get-property org.freedesktop.NetworkManager \
            /org/freedesktop/NetworkManager org.freedesktop.NetworkManager Metered 2>/dev/null); then
        case "${m##* }" in 1|3) echo "the network connection is metered"; return 0 ;; esac
    fi
    return 1
}

update_background() {
    need_root "update --background"
    local why out rc=0
    if why=$(update_background_blocker); then
        printf 'pulsar: not staging now: %s\n' "$why"
        return 0
    fi
    out=$(JSON=1 cmd_update_check --check 2>&1) || rc=$?
    case "$rc" in
        0)  printf 'pulsar: nothing to stage: %s\n' "$(printf '%s' "$out" | jq -r '.status + " (" + .latest + ")"' 2>/dev/null || echo current)"
            return 0 ;;
        10) ;;
        *)  printf 'pulsar: not staging now: could not tell whether a newer image exists: %s\n' \
                "$(printf '%s' "$out" | sed $'s/\033\\[[0-9;]*m//g; s/^pulsar: //' | tail -1)"
            return 0 ;;
    esac
    printf 'pulsar: staging %s for the next boot\n' "$(printf '%s' "$out" | jq -r .latest 2>/dev/null)"
    cmd_update
}

update_help() {
    cat <<'EOF'
usage: sudo pulsar update [--apply]   download and stage the newest image; it
                                      takes effect on the next boot. --apply
                                      also reboots into it
       pulsar update --check          is a newer image published? no root.
                                      exit 0 up to date or already staged,
                                      10 available, 1 could not tell
         --notify                     with --check: a desktop notification
                                      when an image is published, and one
                                      when it is staged. While
                                      pulsar-update-auto.timer is on, the
                                      first waits a day
         --json                       with --check: the answer as JSON
       pulsar update --download       what the update notification's Update
                                      button does: stage the newest image
                                      through pulsar-update-stage.service
                                      (no password for an administrator),
                                      then a notification says how it ended.
                                      No root. Waits for it: exit 0 staged,
                                      1 failed
       sudo pulsar update --background
                                      stage a newer image if there is one,
                                      unless on battery or a metered
                                      connection. pulsar-update-auto.timer
                                      runs this; turn it off with
                                      sudo systemctl disable --now pulsar-update-auto.timer

Through bootc, or through rpm-ostree when packages are layered. Other flags
pass through to whichever of the two runs.
EOF
}

cmd_update() {
    local arg check=0 notify=0 background=0 download=0
    for arg in "$@"; do
        case "$arg" in
            -h|--help) update_help; return 0 ;;
            --check) check=1 ;;
            --notify) notify=1 ;;
            --background) background=1 ;;
            --download) download=1 ;;
        esac
    done
    if [ "$download" = 1 ]; then
        [ "$#" -eq 1 ] || die "--download takes no other flags: pulsar update --download"
        no_json update
        update_download
        return $?
    fi
    if [ "$background" = 1 ]; then
        [ "$#" -eq 1 ] || die "--background takes no other flags: sudo pulsar update --background"
        no_json update
        update_background
        return $?
    fi
    if [ "$check" = 1 ]; then
        cmd_update_check "$@" || return $?
        return 0
    fi
    [ "$notify" = 0 ] || die "--notify goes with --check: pulsar update --check --notify"
    no_json update

    need_root update
    local lay fix
    if have rpm-ostree; then
        # Refused rather than run: the upgrade would re-pull the same digest
        # and report success, which is how this went unnoticed.
        fix=$(pinned_origin_fix "$(rpm-ostree status --json 2>/dev/null || echo '{}')")
        [ -z "$fix" ] || die "this system follows one image digest, so there is nothing to update to; run: ${fix}"
        lay=$(rpm-ostree status --json 2>/dev/null | jq -r "$JQ_LAYERED" 2>/dev/null) \
            || die "could not read deployment status; refusing to guess whether to update through bootc or rpm-ostree"
        [ -n "$lay" ] || die "could not read deployment status; refusing to guess whether to update through bootc or rpm-ostree"
    else
        lay=0   # nothing to layer with, so nothing can be layered
    fi

    if [ "$lay" -eq 0 ]; then
        need bootc
        exec bootc upgrade "$@"
    fi

    printf '%spulsar:%s %s local package modification(s) on this deployment, so updating through rpm-ostree, which keeps them\n' \
        "$C_KEY" "$C_RESET" "$lay" >&2
    need rpm-ostree
    # The flags pulsar documents are bootc's, and --apply has an exact
    # counterpart here. Everything else passes through verbatim and fails at
    # rpm-ostree if it does not exist there, which is the honest outcome --
    # better than a silently dropped flag.
    local f; local -a a=()
    for f in "$@"; do
        case "$f" in --apply) a+=(--reboot) ;; *) a+=("$f") ;; esac
    done
    exec rpm-ostree upgrade ${a[@]+"${a[@]}"}
}

cmd_rollback() {
    case "${1:-}" in
        -h|--help)
            printf 'usage: sudo pulsar rollback   make the previous deployment the default for the
                              next boot. nothing reboots; other flags pass to bootc
'
            return 0 ;;
    esac
    no_json rollback
    need_root rollback; need bootc
    exec bootc rollback "$@"
}

cmd_pin() {
    local sub=${1:-}
    [ $# -le 1 ] || die "usage: pulsar pin [on | off]"
    case "$sub" in
        -h|--help)
            printf 'usage: pulsar pin            is the booted deployment pinned (kept when old
                             deployments are cleaned up)?
       sudo pulsar pin on    pin it
       sudo pulsar pin off   unpin it
'
            return 0 ;;
        "")
            need rpm-ostree
            local pinned
            pinned=$(rpm-ostree status --json 2>/dev/null \
                | jq -r '[.deployments[]? | select(.booted == true)][0].pinned // false') \
                || die "could not read deployment status"
            if [ "${JSON:-0}" = 1 ]; then
                jq -n -c --argjson p "$pinned" '{pinned: $p}'
            elif [ "$pinned" = true ]; then
                printf 'the booted deployment is pinned (sudo pulsar pin off to release it)
'
            else
                printf 'the booted deployment is not pinned (sudo pulsar pin on to keep it)
'
            fi
            return 0 ;;
        on|off) no_json "pin ${sub}"; need_root "pin ${sub}"; need ostree ;;
        *) die "unknown pin command: ${sub} (see: pulsar pin --help)" ;;
    esac
    if [ "$sub" = off ]; then
        ostree admin pin --unpin booted && printf 'unpinned the booted deployment
'
        return
    fi
    # `booted`, not index 0. Index 0 is the staged deployment when there is
    # one (ostree then refuses: "Cannot pin staged deployment"), and after a
    # rollback or a pick from GRUB the booted one is index 1 -- so `0` pinned
    # the OTHER deployment and reported the booted one pinned, at exactly the
    # moment a pin is wanted.
    ostree admin pin booted && printf 'pinned the booted deployment; it is kept when old deployments are cleaned up\n'
}
