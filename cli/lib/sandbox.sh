# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): pulsar agent run and the sandbox it runs agents in.

# ---------------------------------------------------------------------------
# agent sandbox -- the agent sees the project, not the rest of $HOME, and
# pushes through a gate that never hands it a credential.
#
# Off, an agent runs in the agents toolbox: it shares $HOME, the session bus
# and the user's keys. On, `pulsar agent run` starts it in a rootless podman
# container that holds:
#
#   the project       the git root it was started in, read-write, except
#                     what git runs things from, read-only: a hook or a
#                     core.fsmonitor planted there would run on the host the
#                     next time the USER runs git in it (sandbox_git_mounts)
#   its own state     ~/.claude, ~/.codex, ...: one login, both modes
#   git identity      ~/.gitconfig and ~/.config/git, read-only
#   the guide         AGENTS.md and the skills, read-only
#   the gate          one socket (pulsar-agent-gate): push and pull through
#                     the user's credentials, on the host, under a policy
#
# and nothing else of $HOME: a private tmpfs sits under those mounts. No
# session bus, no flatpak-spawn, no SSH agent. The network stays open (the
# agent needs its API): the sandbox limits what it can READ, not where it
# can send it. SELinux label separation is off, as toolbox has it, so the
# user's files are never relabeled; the mounts do the isolating.
#
# Settings, most specific first. Whatever the agent can write can only
# TIGHTEN, so a sandboxed agent cannot loosen its own next session:
#
#   repo      <root>/.pulsar/agent.toml   sandbox = "on"; push = "off"|"branches"
#   yours     ~/.config/pulsar/agent-projects (per git root; outside the project)
#   global    ~/.config/pulsar/agent.conf
#   default   sandbox off, push on
# ---------------------------------------------------------------------------
AGENT_CONF=${PULSAR_AGENT_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/pulsar/agent.conf}
AGENT_PROJECTS=${PULSAR_AGENT_PROJECTS:-${XDG_CONFIG_HOME:-$HOME/.config}/pulsar/agent-projects}
GATE_DIR=${PULSAR_GATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/pulsar/gate}
GATE_TOOL=${PULSAR_GATE:-/usr/libexec/pulsar/pulsar-agent-gate}
SANDBOX_BASE=${PULSAR_SANDBOX_BASE:-registry.fedoraproject.org/fedora-toolbox}

# The image: the host's own Fedora toolbox, plus what the agents run on.
sandbox_recipe() {
    local ver
    ver=$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"')
    [ -n "$ver" ] || ver=45
    cat <<EOF
FROM ${SANDBOX_BASE}:${ver}
RUN dnf -y install nodejs npm uv git python3 ripgrep fd-find jq && dnf clean all
LABEL digital.arclight.pulsar.sandbox=1
EOF
}

# Tagged by the recipe's hash, so a changed recipe is a new image.
sandbox_image() {
    printf 'localhost/pulsar-agent-sandbox:%s\n' "$(sandbox_recipe | sha256sum | cut -c1-12)"
}

sandbox_build() {
    local img; img=$(sandbox_image)
    podman image exists "$img" 2>/dev/null && return 0
    printf 'building the sandbox image %s (once)\n' "$img" >&2
    sandbox_recipe | podman build --quiet -t "$img" -f - >&2 || die "could not build the sandbox image"
}

# The project an agent started here is working in: the git root, else here.
project_root() {
    git -C "${1:-$PWD}" rev-parse --show-toplevel 2>/dev/null || (cd "${1:-$PWD}" && pwd -P)
}

# key (sandbox|push) -> "value <TAB> where it came from", for project $2.
setting_resolve() {
    local key=$1 root=$2 base="" src="" repo=""
    if [ -r "$AGENT_PROJECTS" ]; then
        base=$(awk -F'\t' -v k="$key" -v p="$root" '$1 == k && $2 == p { v = $3 } END { print v }' "$AGENT_PROJECTS")
        [ -z "$base" ] || src="this project, yours"
    fi
    if [ -z "$base" ] && [ -r "$AGENT_CONF" ]; then
        base=$(awk -F' *= *' -v k="$key" '$1 == k { v = $2 } END { print v }' "$AGENT_CONF")
        [ -z "$base" ] || src="global"
    fi
    if [ -z "$base" ]; then
        case "$key" in sandbox) base=off ;; push|wrap) base=on ;; esac
        src=default
    fi
    # The repo file can only tighten: sandbox on; push off or branches.
    if [ -r "${root}/.pulsar/agent.toml" ]; then
        repo=$(awk -F' *= *' -v k="$key" '$1 == k { gsub(/"/, "", $2); v = $2 } END { print v }' "${root}/.pulsar/agent.toml")
    fi
    case "$key:$repo" in
        sandbox:on)
            [ "$base" = on ] || { base=on; src="this project: .pulsar/agent.toml"; } ;;
        push:off)
            [ "$base" = off ] || { base=off; src="this project: .pulsar/agent.toml"; } ;;
        push:branches)
            [ "$base" != on ] || { base=branches; src="this project: .pulsar/agent.toml"; } ;;
    esac
    printf '%s\t%s\n' "$base" "$src"
}

setting_write() {
    local key=$1 value=$2 here=$3 root=$4 tmp
    if [ "$here" = 1 ]; then
        mkdir -p "$(dirname "$AGENT_PROJECTS")"
        tmp=$(mktemp)
        { [ -r "$AGENT_PROJECTS" ] && awk -F'\t' -v k="$key" -v p="$root" '!($1 == k && $2 == p)' "$AGENT_PROJECTS"
          printf '%s\t%s\t%s\n' "$key" "$root" "$value"; } > "$tmp"
        mv "$tmp" "$AGENT_PROJECTS"
    else
        mkdir -p "$(dirname "$AGENT_CONF")"
        tmp=$(mktemp)
        { [ -r "$AGENT_CONF" ] && awk -F' *= *' -v k="$key" '$1 != k' "$AGENT_CONF"
          printf '%s = %s\n' "$key" "$value"; } > "$tmp"
        mv "$tmp" "$AGENT_CONF"
    fi
}

gate_id() { printf '%s' "$1" | sha256sum | cut -c1-16; }

# Extra paths the user lets into the sandbox, global and this project's:
# "path" or "path:rw", one per line. Never from the repo file: allowing is
# loosening, and the agent can write that file.
sandbox_allows() {
    local root=$1
    { [ ! -r "$AGENT_CONF" ] || awk -F' *= *' '$1 == "allow" { print $2 }' "$AGENT_CONF"
      [ ! -r "$AGENT_PROJECTS" ] || awk -F'\t' -v p="$root" '$1 == "allow" && $2 == p { print $3 }' "$AGENT_PROJECTS"
    } | awk '!seen[$0]++'
}

sandbox_allow() {
    local want=$1 here=$2 root=$3 rw=$4 path entry tmp file
    [ -n "$want" ] || die "usage: pulsar agent sandbox allow <path> [--rw] [--here]"
    path=$(realpath -m "$want")
    [ -e "$path" ] || die "no such path: ${path}"
    case "$HOME/" in "${path%/}/"*) die "that would let the whole of ${path} in; allow the one file or folder you need" ;; esac
    case "$path" in
        "$HOME/.ssh"*|"$HOME/.gnupg"*|"$HOME/.local/share/keyrings"*|"$HOME/.config/gh"*|"$HOME/.password-store"*)
            printf 'warning: %s holds keys or tokens; the agent in the sandbox can read them\n' "$path" >&2 ;;
    esac
    entry=$path; [ "$rw" = 0 ] || entry="${path}:rw"
    tmp=$(mktemp)
    if [ "$here" = 1 ]; then
        file=$AGENT_PROJECTS
        { [ ! -r "$file" ] || awk -F'\t' -v p="$root" -v e="$path" '!($1 == "allow" && $2 == p && ($3 == e || $3 == e ":rw"))' "$file"
          printf 'allow\t%s\t%s\n' "$root" "$entry"; } > "$tmp"
    else
        file=$AGENT_CONF
        { [ ! -r "$file" ] || awk -F' *= *' -v e="$path" '!($1 == "allow" && ($2 == e || $2 == e ":rw"))' "$file"
          printf 'allow = %s\n' "$entry"; } > "$tmp"
    fi
    mkdir -p "$(dirname "$file")"; mv "$tmp" "$file"
    printf 'allowed into the sandbox%s: %s (%s)\n' "$([ "$here" = 1 ] && printf ' for %s' "$root")" "$path" \
        "$([ "$rw" = 1 ] && echo read-write || echo read-only)"
}

sandbox_disallow() {
    local path tmp
    path=$(realpath -m "$1")
    tmp=$(mktemp)
    if [ -r "$AGENT_CONF" ]; then
        awk -F' *= *' -v e="$path" '!($1 == "allow" && ($2 == e || $2 == e ":rw"))' "$AGENT_CONF" > "$tmp" && mv "$tmp" "$AGENT_CONF"
    fi
    tmp=$(mktemp)
    if [ -r "$AGENT_PROJECTS" ]; then
        awk -F'\t' -v e="$path" '!($1 == "allow" && ($3 == e || $3 == e ":rw"))' "$AGENT_PROJECTS" > "$tmp" && mv "$tmp" "$AGENT_PROJECTS"
    fi
    rm -f "$tmp"
    printf 'no longer allowed: %s\n' "$path"
}

# Programs the agent's own hooks run that live in $HOME and are not let in:
# the sandbox cannot see them, and the hook fails on every call. Claude Code
# only, for now: its hooks are in settings.json.
sandbox_hook_hints() {
    local name=$1 root=$2 cmd bin allows
    [ "$name" = claude ] && [ -r "$HOME/.claude/settings.json" ] && have jq || return 0
    allows=$(sandbox_allows "$root" | sed 's/:rw$//')
    jq -r '.. | objects | .command? // empty | strings' "$HOME/.claude/settings.json" 2>/dev/null \
        | awk '{ print $1 }' | sort -u | while IFS= read -r cmd; do
            bin=$(command -v "$cmd" 2>/dev/null) || continue
            case "$bin" in "$HOME"/*) ;; *) continue ;; esac
            grep -qxF "$bin" <<<"$allows" && continue
            printf 'note: your claude hooks run %s (%s), which the sandbox cannot see: pulsar agent sandbox allow %s\n' \
                "$cmd" "$bin" "$bin" >&2
        done
}

agent_sandbox() {
    local sub=${1:-} here=0 root a
    local -a rest=()
    shift || true
    local rw=0
    for a in "$@"; do
        case "$a" in --here) here=1 ;; --rw) rw=1 ;; *) rest+=("$a") ;; esac
    done
    root=$(settings_root)
    case "$sub" in
        "")
            local sb push mirror
            sb=$(setting_resolve sandbox "$root"); push=$(setting_resolve push "$root")
            mirror="${GATE_DIR}/$(gate_id "$root").git"
            printf 'project  %s\n' "$root"
            printf 'sandbox  %s  (%s)\n' "${sb%%$'\t'*}" "${sb#*$'\t'}"
            printf 'push     %s  (%s)\n' "${push%%$'\t'*}" "${push#*$'\t'}"
            local al
            while IFS= read -r al; do
                [ -z "$al" ] || printf 'allow    %s\n' "$al"
            done < <(sandbox_allows "$root")
            if [ -d "$mirror" ]; then
                git -C "$mirror" config --get-regexp '^remote\..*\.url$' 2>/dev/null \
                    | sed 's/^remote\.\(.*\)\.url /remote   \1 -> /; s/$/  (pinned)/'
            fi
            local n native wrap
            wrap=$(setting_resolve wrap "$root"); wrap=${wrap%%$'\t'*}
            printf 'wrap     %s  (typing an agent'"'"'s name in bash goes through pulsar agent run)\n' \
                "$([ "$wrap" = off ] && echo off || echo on)"
            while IFS=$'\t' read -r n _; do
                native=$(native_launcher "$n" 2>/dev/null) || continue
                is_our_shim "${AGENT_SHIMS}/${n}" && continue
                if [ "$wrap" = off ]; then
                    printf 'note     %s runs from %s as installed: pulsar agent run %s sandboxes it (wrap is off)\n' "$n" "$native" "$n"
                fi
            done < <(agent_rows)
            ;;
        on|off)
            [ ${#rest[@]} -eq 0 ] || die "usage: pulsar agent sandbox on|off [--here]"
            setting_write sandbox "$sub" "$here" "$root"
            if [ "$here" = 1 ]; then printf 'sandbox %s for %s\n' "$sub" "$root"; else printf 'sandbox %s (global)\n' "$sub"; fi
            local eff; eff=$(setting_resolve sandbox "$root")
            [ "${eff%%$'\t'*}" = "$sub" ] || printf 'here it stays %s: %s\n' "${eff%%$'\t'*}" "${eff#*$'\t'}"
            ;;
        push)
            case "${rest[0]:-}" in on|off|branches) ;; *) die "usage: pulsar agent sandbox push on|off|branches [--here]" ;; esac
            setting_write push "${rest[0]}" "$here" "$root"
            if [ "$here" = 1 ]; then printf 'push %s for %s\n' "${rest[0]}" "$root"; else printf 'push %s (global)\n' "${rest[0]}"; fi
            ;;
        wrap)
            # whether typing an agent's name goes through `agent run`
            # (/etc/profile.d/pulsar-agents.sh); global, read by every shell
            case "${rest[0]:-}" in on|off) ;; *) die "usage: pulsar agent sandbox wrap on|off" ;; esac
            [ "$here" = 0 ] || die "wrap is global: every shell reads it"
            setting_write wrap "${rest[0]}" 0 "$root"
            printf 'typing an agent'"'"'s name %s through pulsar agent run, in new shells\n' \
                "$([ "${rest[0]}" = on ] && echo goes || echo no longer goes)" ;;
        allow)
            [ ${#rest[@]} -eq 1 ] || die "usage: pulsar agent sandbox allow <path> [--rw] [--here]"
            sandbox_allow "${rest[0]}" "$here" "$root" "$rw" ;;
        disallow)
            [ ${#rest[@]} -eq 1 ] || die "usage: pulsar agent sandbox disallow <path>"
            sandbox_disallow "${rest[0]}" ;;
        list)
            [ -r "$AGENT_PROJECTS" ] && [ -s "$AGENT_PROJECTS" ] || { printf 'no per-project settings\n'; return 0; }
            awk -F'\t' '{ printf "%-8s %-9s %s%s\n", $1, $3, $2, (system("test -d \"" $2 "\"") ? "  (gone)" : "") }' "$AGENT_PROJECTS"
            ;;
        repin)
            # The remotes are pinned when a project first runs sandboxed. After
            # a real change of remote, the user says so, here, on the host.
            rm -rf "${GATE_DIR}/$(gate_id "$root").git"
            printf 'unpinned %s: its remotes are pinned again on the next sandboxed run\n' "$root" ;;
        -h|--help) agent_help ;;
        *) die "unknown sandbox command: ${sub} (see: pulsar agent --help)" ;;
    esac
}

# The sandbox's own home, per agent, persistent: its history and caches live
# here. The user's settings flow IN at every start; nothing flows out but the
# login. A sandboxed agent that edits its own settings -- adds a hook, an MCP
# server -- edits this copy, which the next start overwrites, and which the
# unsandboxed agent never reads. Mounting the real ~/.claude read-write would
# let exactly that run on the host.
SANDBOX_HOMES=${PULSAR_SANDBOX_HOMES:-${XDG_DATA_HOME:-$HOME/.local/share}/pulsar/sandbox}

# What of the user's agent setup goes in, relative to $HOME:
#   copy  small files the agent also writes (settings, its state file, the
#         login): copied in at each start, over whatever the sandbox did
#   ro    folders it only reads (skills, plugins, hooks): mounted read-only
#         from the real ones, so nothing is copied and nothing can be planted
agent_sync_paths() {
    local f
    case "$1" in
        claude)
            printf 'copy %s\n' .claude.json .claude/settings.json .claude/settings.local.json \
                .claude/keybindings.json .claude/.credentials.json
            # CLAUDE.md and whatever it @-imports beside it
            for f in "$HOME"/.claude/*.md; do [ ! -e "$f" ] || printf 'copy .claude/%s\n' "$(basename "$f")"; done
            printf 'ro %s\n' .claude/commands .claude/agents .claude/skills .claude/rules .claude/hooks .claude/plugins .claude/themes ;;
        codex)    printf 'copy %s\n' .codex/config.toml .codex/AGENTS.md .codex/AGENTS.override.md .codex/auth.json
                  printf 'ro %s\n' .codex/prompts .codex/skills .agents/skills ;;
        # agy keeps its login in the keyring, which the sandbox cannot reach
        # (no session bus). With no bus it says it uses file-based token
        # storage instead, somewhere under its own home, so a sandbox should
        # sign in once by itself and keep it. Not yet checked end to end: no
        # login has been completed in a sandbox, and how it signs in with no
        # browser to open is untested.
        agy)      printf 'copy %s\n' .gemini/antigravity-cli/settings.json .gemini/antigravity-cli/keybindings.json \
                      .gemini/config/mcp_config.json .gemini/config/hooks.json \
                      .gemini/GEMINI.md .gemini/AGENTS.md .gemini/config/GEMINI.md .gemini/config/AGENTS.md
                  printf 'ro %s\n' .gemini/config/rules .gemini/config/skills .gemini/config/plugins \
                      .gemini/skills .gemini/antigravity-cli/skills ;;
        gemini)   printf 'copy %s\n' .gemini/settings.json .gemini/GEMINI.md .gemini/oauth_creds.json .gemini/google_accounts.json
                  printf 'ro %s\n' .gemini/commands .gemini/skills ;;
        # A login made under opencode 1.x is auth.json, and 2 imports it
        # into its opencode.db once. One made under 2 lives only in that
        # database, which goes neither in nor out: a sandboxed opencode 2
        # signs in by itself.
        opencode) printf 'copy %s\n' .local/share/opencode/auth.json
                  printf 'ro %s\n' .config/opencode .agents/skills ;;
        aider)    printf 'copy %s\n' .aider.conf.yml ;;
    esac
}

# The login: the one thing copied back out, so both modes stay signed in.
agent_cred_path() {
    case "$1" in
        claude)   printf '%s\n' .claude/.credentials.json ;;
        codex)    printf '%s\n' .codex/auth.json ;;
        gemini)   printf '%s\n' .gemini/oauth_creds.json ;;
        opencode) printf '%s\n' .local/share/opencode/auth.json ;;
        *)        return 1 ;;
    esac
}

sandbox_sync_in() {
    local name=$1 home=$2 how rel
    mkdir -p "$home"; chmod 0700 "$home"
    while read -r how rel; do
        [ "$how" = copy ] && [ -n "$rel" ] || continue
        if [ -e "$HOME/$rel" ]; then
            mkdir -p "$(dirname "$home/$rel")"
            cp -a --remove-destination "$HOME/$rel" "$home/$rel"
            # the host's pulsar MCP server is not reachable from in here
            if { [ "$rel" = .claude.json ] || [ "$rel" = .gemini/config/mcp_config.json ]; } && have jq; then
                local t; t=$(mktemp)
                if jq 'del(.mcpServers.pulsar)' "$home/$rel" > "$t" 2>/dev/null; then mv "$t" "$home/$rel"; else rm -f "$t"; fi
            fi
            # Codex: the block pulsar agent add wrote (marked), nothing of the user's
            if [ "$rel" = .codex/config.toml ] && grep -q '^# pulsar-mcp: written by' "$home/$rel"; then
                local t; t=$(mktemp)
                awk '/^# pulsar-mcp: written by/ { skip = 1; next }
                     skip && /^\[/ && !/^\[mcp_servers\.pulsar\]/ { skip = 0 }
                     !skip' "$home/$rel" > "$t" && mv "$t" "$home/$rel"
            fi
        else
            # gone on the host: gone in here too, not left over from before
            rm -f "${home:?}/$rel"
        fi
    done < <(agent_sync_paths "$name")
}

# The read-only half, as podman -v arguments, one per line.
sandbox_ro_mounts() {
    local name=$1 how rel
    while read -r how rel; do
        [ "$how" = ro ] && [ -d "$HOME/$rel" ] || continue
        printf '%s\n' "$HOME/$rel:$HOME/$rel:ro"
    done < <(agent_sync_paths "$name")
}

# At the end of a session: the refreshed login goes back, if it is still
# JSON, if it changed in here, and if the host's copy did NOT change meanwhile
# (then the host's is newer, and the sandbox's may already be revoked).
sandbox_creds_out() {
    local name=$1 home=$2 before=$3 rel host in tmp
    rel=$(agent_cred_path "$name") || return 0
    host="$HOME/$rel"; in="$home/$rel"
    # A real file inside the sandbox's home, never a symlink: the agent could
    # point it at any JSON the user can read on the host (registry auth, a
    # cloud token) and have it copied into the host's login, then back into
    # the sandbox next session. Nor may the sandbox create a host login that
    # was not there before it started.
    [ -f "$in" ] && [ ! -L "$in" ] || return 0
    case "$(realpath -e -- "$in" 2>/dev/null)" in "$(realpath -e -- "$home")"/*) ;; *) return 0 ;; esac
    [ -n "$before" ] || return 0
    jq -e . "$in" >/dev/null 2>&1 || return 0
    [ "$(sha256sum < "$host" 2>/dev/null | cut -c1-64)" = "$before" ] || return 0
    cmp -s "$in" "$host" 2>/dev/null && return 0
    mkdir -p "$(dirname "$host")"
    tmp=$(mktemp "${host}.XXXXXX") && cp "$in" "$tmp" && chmod 0600 "$tmp" && mv "$tmp" "$host"
}

# Upstream tracking for what the agent pushed. Inside, .git/config is
# read-only, so `push -u` (and push.autoSetupRemote) cannot record it; the
# gate notes each branch that reached the real remote, and this records it
# on the host as the session ends. Only branch.<b>.remote and .merge, only
# for a local branch of that name with no upstream yet, and only for a
# remote the gate had pinned.
sandbox_tracking() {
    local root=$1 log=$2 mirror=$3 remote ref b
    [ -s "$log" ] || { rm -f "$log"; return 0; }
    while IFS=$'\t' read -r remote ref; do
        b=${ref#refs/heads/}
        [ "$ref" != "$b" ] || continue
        git check-ref-format --branch "$b" >/dev/null 2>&1 || continue
        git -C "$mirror" config "remote.${remote}.url" >/dev/null 2>&1 || continue
        git -C "$root" show-ref --verify --quiet "refs/heads/${b}" || continue
        git -C "$root" config "branch.${b}.remote" >/dev/null 2>&1 && continue
        git -C "$root" config "branch.${b}.remote" "$remote"
        git -C "$root" config "branch.${b}.merge" "$ref"
        printf 'note: %s now tracks %s/%s\n' "$b" "$remote" "$b" >&2
    done < <(sort -u "$log")
    rm -f "$log"
}

# Git runs things out of its own files: a hook, core.fsmonitor, any config it
# is pointed at. The project is read-write in here, so each of those the agent
# could write would run on the host the next time you ran git in the project,
# or your editor did in the background. .git/config and .git/hooks being
# read-only closed only the front door. The others:
#
#   .git itself        moved aside, it takes its read-only mounts with it,
#                      and a new .git with a config of the agent's takes its
#                      place; bound onto itself, it is a mount point, and a
#                      mount point cannot be renamed
#   .git/commondir     git then reads config and hooks from wherever it
#                      points; a plain repository never has one
#   submodules         their git directories under .git/modules have a
#                      config and hooks of their own, and a gitlink in the
#                      index plus a .git file or folder anywhere in the tree
#                      makes the user's `git status` run git in it
#   config it names    core.hooksPath (husky's .husky/_), include.path and
#                      includeIf: in the project, they are .git/hooks and
#                      .git/config by another name
#
# What a mount can close is closed before the agent starts. What it cannot --
# a file that does not exist yet, since mounting over it would make it on the
# host -- is checked when the session ends, before Pulsar runs git itself.

# Refuse a project whose git directory the sandbox cannot protect.
sandbox_git_check() {
    local root=$1
    { [ -e "${root}/.git" ] || [ -L "${root}/.git" ]; } || return 0
    [ -d "${root}/.git" ] && [ ! -L "${root}/.git" ] \
        || die "${root}/.git is not a folder: this is a linked worktree or a submodule, and its git directory is outside the project, where the sandbox cannot protect it; start the agent from the main checkout"
    [ ! -e "${root}/.git/commondir" ] \
        || die "${root}/.git/commondir exists, which a plain repository never has: git would read its config and hooks from wherever it points. Read it before starting an agent here"
}

# The git mounts, one podman -v per line: each git directory bound onto itself
# and its config and hooks read-only, then what the project's config points at.
sandbox_git_mounts() {
    local root=$1 g="${1}/.git" p d line key val src
    [ -d "$g" ] || return 0
    printf '%s:%s\n' "$g" "$g"
    [ ! -e "${g}/config" ] || printf '%s:%s:ro\n' "${g}/config" "${g}/config"
    mkdir -p "${g}/hooks"
    printf '%s:%s:ro\n' "${g}/hooks" "${g}/hooks"
    # linked worktrees: their git side is not the agent's to change, nor is
    # the .git file in one that lives in the project, which your git follows
    [ ! -d "${g}/worktrees" ] || printf '%s:%s:ro\n' "${g}/worktrees" "${g}/worktrees"
    local w
    for w in "${g}"/worktrees/*/gitdir; do
        [ -f "$w" ] || continue
        w=$(realpath -m "$(head -n 1 "$w")")
        case "$w" in "${root}/"*/.git) [ ! -f "$w" ] || [ -L "$w" ] || printf '%s:%s:ro\n' "$w" "$w" ;; esac
    done
    # The worktree the agent works in (sandbox_run): its index, HEAD and logs
    # are its to write; the files that say where its repository is are not.
    if [ -n "${2:-}" ]; then
        printf '%s:%s\n' "$2" "$2"
        [ -e "${2}/config.worktree" ] || : > "${2}/config.worktree"
        for w in commondir gitdir config.worktree; do printf '%s:%s:ro\n' "${2}/${w}" "${2}/${w}"; done
    fi
    if [ -d "${g}/modules" ]; then
        while IFS= read -r -d '' p; do
            d=$(dirname "$p")
            mkdir -p "${d}/hooks"
            printf '%s:%s\n%s:%s:ro\n%s:%s:ro\n' "$d" "$d" "$p" "$p" "${d}/hooks" "${d}/hooks"
        done < <(find "${g}/modules" -name config -type f -print0 | sort -z)
    fi
    # As the user's git reads it: every scope, includes followed. An include
    # is relative to the file that names it; hooksPath to the checkout. One
    # outside the project is not in here at all, so it needs nothing.
    while IFS= read -r line; do
        src=${line%%$'\t'*}; src=${src#file:}
        line=${line#*$'\t'}
        key=${line%% *}; val=${line#* }
        case "$val" in \~/*) val="${HOME}/${val#\~/}" ;; esac
        case "$key" in
            core.hookspath) case "$val" in /*) ;; *) val="${root}/${val}" ;; esac
                            val=$(realpath -m "$val")
                            case "$val/" in "${root}/"*) mkdir -p "$val" ;; esac ;;
            *) case "$val" in /*) ;; *) val="$(dirname "$src")/${val}" ;; esac
               val=$(realpath -m "$val") ;;
        esac
        case "$val" in "${root}/"*) [ ! -e "$val" ] || printf '%s:%s:ro\n' "$val" "$val" ;; esac
    done < <(git -C "$root" config --show-origin --get-regexp '^(core\.hookspath|include\.path|includeif\..*\.path)$' 2>/dev/null)
}

# What in the tree could make the user's git run something, as NUL-separated
# records: every .git below the project's own (a submodule's pointer, or a
# repository), and every commondir in a git directory, each with its content
# or its identity. The records compare whole, so no name can forge a line.
sandbox_git_state() {
    local root=$1 p
    while IFS= read -r -d '' p; do
        if [ -f "$p" ] && [ ! -L "$p" ]; then
            printf 'f\t%s\t%s\0' "$(sha256sum < "$p" | cut -c1-64)" "$p"
        else
            printf 'x\t%s\t%s\0' "$(stat -c %d:%i "$p")" "$p"
        fi
    done < <(find "$root" -path "${root}/.git" -prune -o -name .git -print0 2>/dev/null)
    [ -d "${root}/.git" ] || return 0
    while IFS= read -r -d '' p; do
        printf 'c\t%s\t%s\0' "$(sha256sum < "$p" | cut -c1-64)" "$p"
    done < <(find "${root}/.git" -path "${root}/.git/worktrees" -prune -o -name commondir -print0 2>/dev/null)
}

# Anything new or changed since $2 (sandbox_git_state before the session) is
# renamed out of git's way, the way sandbox_defuse does agent config.
sandbox_git_defuse() {
    local root=$1 before=$2 rec p
    local -A seen=()
    if [ -f "$before" ]; then
        while IFS= read -r -d '' rec; do seen["$rec"]=1; done < "$before"
    fi
    while IFS= read -r -d '' rec; do
        [ -z "${seen["$rec"]:-}" ] || continue
        p=${rec#*$'\t'}; p=${p#*$'\t'}
        { [ -e "$p" ] || [ -L "$p" ]; } || continue
        # a worktree made meanwhile, on the host (another session's
        # --worktree): its registration is in .git/worktrees, which the
        # sandbox has read-only, so its .git file can't be the agent's
        [ "$(basename "$p")" != .git ] || ! worktree_main "$(dirname "$p")" >/dev/null || continue
        rm -rf "${p}.from-sandbox"
        mv "$p" "${p}.from-sandbox"
        printf 'note: the sandboxed agent left %s, which your git would follow; renamed to %s.from-sandbox. Read it, and any git directory it points at, before renaming it back.\n' \
            "${p#"${root}/"}" "$(basename "$p")" >&2
    done < <(sandbox_git_state "$root")
    rm -f "$before"
}

# Agent config in the project that an agent loads by itself: read-only in
# here when it exists; created in here, it is defused when the session ends.
# .agents holds agy's hooks.json and mcp_config.json and the skills Codex,
# opencode and agy read.
PROJECT_AGENT_CONFIG='.claude .mcp.json .codex .gemini .agents .opencode opencode.json opencode.jsonc'

sandbox_defuse() {
    local root=$1 existed=$2 p
    for p in $PROJECT_AGENT_CONFIG; do
        case " ${existed} " in *" ${p} "*) continue ;; esac
        { [ -e "${root}/${p}" ] || [ -L "${root}/${p}" ]; } || continue
        rm -rf "${root}/${p}.from-sandbox"
        mv "${root}/${p}" "${root}/${p}.from-sandbox"
        printf 'note: the sandboxed agent created %s; renamed to %s.from-sandbox so no agent loads it. Read it, then rename it back if you want it.\n' \
            "$p" "$p" >&2
    done
}

# <wt>: "main checkout <TAB> git directory", when wt is a linked worktree that
# lives INSIDE its main checkout (where `agent run --worktree` puts them), so
# the sandbox can show that checkout and start the agent in the worktree.
# Read from the files, not by asking git, and every link checked both ways:
# a worktree whose pointers have been bent is not one.
worktree_main() {
    local wt=$1 line gd common main back
    [ -f "${wt}/.git" ] && [ ! -L "${wt}/.git" ] || return 1
    line=$(head -n 1 "${wt}/.git"); gd=${line#gitdir: }
    [ "$gd" != "$line" ] || return 1
    case "$gd" in /*) ;; *) gd="${wt}/${gd}" ;; esac
    gd=$(realpath -e "$gd" 2>/dev/null) || return 1
    [ -f "${gd}/commondir" ] && [ -f "${gd}/gitdir" ] || return 1
    common=$(head -n 1 "${gd}/commondir")
    case "$common" in /*) ;; *) common="${gd}/${common}" ;; esac
    common=$(realpath -e "$common" 2>/dev/null) || return 1
    [ "$(basename "$common")" = .git ] && [ "$(dirname "$gd")" = "${common}/worktrees" ] || return 1
    back=$(head -n 1 "${gd}/gitdir")
    [ "$(realpath -m "$back")" = "${wt}/.git" ] || return 1
    main=$(dirname "$common")
    [ -d "${main}/.git" ] && [ ! -L "${main}/.git" ] || return 1
    case "${wt}/" in "${main}/"?*) printf '%s\t%s\n' "$main" "$gd" ;; *) return 1 ;; esac
}

sandbox_run() {
    local name=$1; shift
    local root cmd real wt="" wtgit="" m
    root=$(project_root)
    [ "$root" != "$HOME" ] && [ "$root" != / ] \
        || die "the sandbox shows the agent one project; start it inside one, not in ${root}"
    need podman; need python3; need git
    if m=$(worktree_main "$root"); then
        wt=$root; root=${m%%$'\t'*}; wtgit=${m#*$'\t'}
    fi
    # before anything here runs git in the project
    sandbox_git_check "$root"
    [ -r "$GATE_TOOL" ] || die "the push gate is not staged in this image (${GATE_TOOL})"
    cmd=$(agent_command "$name") || die "${name} is not installed (pulsar agent add ${name})"
    agent_row "$name"
    real=$(readlink -f "$cmd")
    sandbox_build
    local img; img=$(sandbox_image)

    local id sid mirror sock policy
    id=$(gate_id "$root")
    # the mirror is the repository's; the socket and the state files are this
    # session's, or two sandboxed sessions in one repository take each
    # other's (the second's socket replaced the first's, and whichever ended
    # first checked .git files against the other's snapshot)
    sid="${id}.$$"
    mirror="${GATE_DIR}/${id}.git"
    python3 "$GATE_TOOL" setup "$mirror" "$root" "$GATE_TOOL" || die "could not set up the push gate"
    policy=$(setting_resolve push "$root"); policy=${policy%%$'\t'*}
    git -C "$mirror" config pulsar.push "$policy"

    local home cred before=""
    home="${SANDBOX_HOMES}/${name}"
    sandbox_sync_in "$name" "$home"
    if cred=$(agent_cred_path "$name") && [ -f "$HOME/$cred" ]; then
        before=$(sha256sum < "$HOME/$cred" | cut -c1-64)
    fi

    # A worktree session sees its own worktree, not the whole checkout (where
    # the other sessions' worktrees are); the repository's .git comes in
    # through sandbox_git_mounts, as it must for commits.
    local tree=${wt:-$root}
    local -a args=(run --rm -i --userns=keep-id --security-opt label=disable
        -v "${home}:${HOME}"
        -v "${tree}:${tree}"
        -w "$PWD"
        -e "HOME=${HOME}" -e "USER=$(id -un)" -e PULSAR_SANDBOX=1
        # Fedora adds ~/.local/bin only for login shells; an agent's hooks
        # do not run in one, and it is where an allowed tool usually lives.
        -e "PATH=${HOME}/.local/bin:${HOME}/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin"
        -e "TERM=${TERM:-xterm-256color}" -e "LANG=${LANG:-C.UTF-8}")
    [ ! -t 0 ] || args+=(-t)
    while IFS= read -r p; do
        [ -z "$p" ] || args+=(-v "$p")
    done < <(sandbox_git_mounts "$root" "$wtgit")
    local gitstate="${XDG_RUNTIME_DIR:-/tmp}/pulsar/gitstate-${sid}"
    mkdir -p "$(dirname "$gitstate")"
    sandbox_git_state "$root" > "$gitstate"
    while IFS= read -r p; do
        [ -z "$p" ] || args+=(-v "$p")
    done < <(sandbox_ro_mounts "$name")
    # opencode's config folder comes in read-only, as it is; its opencode.json
    # without the pulsar MCP server goes over that one file
    local occ="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json"
    if [ "$name" = opencode ] && [ -f "$occ" ] && have jq && jq -e '.mcp.pulsar' "$occ" >/dev/null 2>&1; then
        jq 'del(.mcp.pulsar)' "$occ" > "${home}/.pulsar-opencode.json" 2>/dev/null \
            && args+=(-v "${home}/.pulsar-opencode.json:${occ}:ro")
    fi
    local p existed=""
    for p in $PROJECT_AGENT_CONFIG; do
        { [ -e "${tree}/${p}" ] || [ -L "${tree}/${p}" ]; } || continue
        existed+="${p} "
        args+=(-v "${tree}/${p}:${tree}/${p}:ro")
    done
    for p in "$HOME/.gitconfig" "${XDG_CONFIG_HOME:-$HOME/.config}/git"; do
        [ ! -e "$p" ] || args+=(-v "${p}:${p}:ro")
    done
    # The agent itself: Pulsar's prefix, or the native install's real files.
    if is_our_shim "${AGENT_SHIMS}/${A_BIN}"; then
        args+=(-v "${AGENT_PREFIX}:${AGENT_PREFIX}:ro" -e "NPM_CONFIG_PREFIX=${AGENT_PREFIX}")
        real="${AGENT_PREFIX}/bin/${A_BIN}"
    else
        args+=(-v "$(dirname "$real"):$(dirname "$real"):ro")
    fi
    local al
    while IFS= read -r al; do
        [ -n "$al" ] || continue
        case "$al" in
            *:rw) [ ! -e "${al%:rw}" ] || args+=(-v "${al%:rw}:${al%:rw}") ;;
            *)    [ ! -e "$al" ] || args+=(-v "${al}:${al}:ro") ;;
        esac
    done < <(sandbox_allows "$root")
    sandbox_hook_hints "$name" "$root"
    # The local model (pulsar agent model), if there is one: pasta forwards
    # exactly that port from the sandbox's loopback to the host's, and no
    # other host port is reachable. The key comes along, read-only.
    if [ -f "${MODEL_UNIT_DIR}/${MODEL_UNIT}.container" ]; then
        args+=(--network "pasta:-T,${MODEL_PORT}")
        [ ! -s "$MODEL_KEY" ] || args+=(-v "${MODEL_KEY}:${MODEL_KEY}:ro")
    fi
    # the session's scratch folder, the one place outside the project it may write
    if [ -n "${PULSAR_SCRATCH:-}" ] && [ -d "$PULSAR_SCRATCH" ]; then
        args+=(-v "${PULSAR_SCRATCH}:${PULSAR_SCRATCH}" -e "PULSAR_SCRATCH=${PULSAR_SCRATCH}")
    fi
    [ ! -r "$AGENTS_MD" ] || args+=(-v "${AGENTS_MD}:/usr/share/pulsar/AGENTS.md:ro")
    [ ! -d "$SKILLS_DIR" ] || args+=(-v "${SKILLS_DIR}:/usr/share/pulsar/skills:ro")
    # The agent's own API key, if the user exported one; nothing else of the env.
    for p in ANTHROPIC_API_KEY OPENAI_API_KEY CODEX_API_KEY GEMINI_API_KEY GOOGLE_API_KEY OPENROUTER_API_KEY; do
        [ -z "${!p:-}" ] || args+=(-e "$p")
    done
    # The agent's files are read-only in here, so its updater could only fail.
    args+=(-e DISABLE_AUTOUPDATER=1 -e AGY_CLI_DISABLE_AUTO_UPDATE=true)

    # Every pinned remote's URL, rewritten to the gate, in the env rather than
    # in the project's config, which the user's own git keeps using.
    sock="${XDG_RUNTIME_DIR:-/tmp}/pulsar/gate-${sid}.sock"
    mkdir -p "$(dirname "$sock")"
    local n=0 rname url pin
    args+=(-v "${GATE_TOOL}:/usr/libexec/pulsar/pulsar-agent-gate:ro" -v "${sock}:/run/pulsar-gate.sock")
    # `gh pr create`, through the gate; the only gh there is in here
    local ghw="${XDG_RUNTIME_DIR:-/tmp}/pulsar/gh"
    printf '#!/bin/sh\n# the sandbox'"'"'s gh: pr create, through the gate (pulsar-agent-gate)\nexec python3 /usr/libexec/pulsar/pulsar-agent-gate gh /run/pulsar-gate.sock "$@"\n' > "$ghw"
    chmod 0755 "$ghw"
    args+=(-v "${ghw}:/usr/local/bin/gh:ro")
    # .git/config is read-only in here, so `push -u` cannot record tracking
    # (git says it did, after an error). autoSetupRemote makes a plain
    # `git push` of a new branch work without it.
    args+=(-e "GIT_CONFIG_KEY_0=protocol.ext.allow" -e "GIT_CONFIG_VALUE_0=always"
           -e "GIT_CONFIG_KEY_1=push.autoSetupRemote" -e "GIT_CONFIG_VALUE_1=true"); n=2
    while read -r rname url; do
        [ -n "$url" ] || continue
        args+=(-e "GIT_CONFIG_KEY_${n}=url.ext::python3 /usr/libexec/pulsar/pulsar-agent-gate connect /run/pulsar-gate.sock %s ${rname}.insteadOf"
               -e "GIT_CONFIG_VALUE_${n}=${url}")
        n=$((n + 1))
        pin=$(git -C "$root" config "remote.${rname}.url" 2>/dev/null) || pin=""
        [ "$pin" = "$url" ] || printf 'note: %s is pinned to %s, but the project now says %s (pulsar agent sandbox repin, if that is right)\n' \
            "$rname" "$url" "$pin" >&2
    done < <(git -C "$mirror" config --get-regexp '^remote\..*\.url$' | sed 's/^remote\.\(.*\)\.url /\1 /')
    args+=(-e "GIT_CONFIG_COUNT=${n}")

    local pushed="${XDG_RUNTIME_DIR:-/tmp}/pulsar/gate-${sid}.pushed"
    rm -f "$pushed"
    PULSAR_GATE_PUSHED="$pushed" python3 "$GATE_TOOL" serve "$sock" "$mirror" \
        2>>"${XDG_RUNTIME_DIR:-/tmp}/pulsar/gate-${id}.log" &
    local gate_pid=$!
    # shellcheck disable=SC2064  # the values are fixed now, on purpose
    # git's own files are defused first: sandbox_tracking runs git on the host
    trap "kill ${gate_pid} 2>/dev/null; rm -f '${sock}'; sandbox_git_defuse '${root}' '${gitstate}'; sandbox_defuse '${tree}' '${existed}'; sandbox_tracking '${root}' '${pushed}' '${mirror}'; sandbox_creds_out '${name}' '${home}' '${before}'" EXIT
    local waited=0
    while [ ! -S "$sock" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
    [ -S "$sock" ] || die "the push gate did not start (see ${XDG_RUNTIME_DIR:-/tmp}/pulsar/gate-${id}.log)"

    printf 'sandboxed: %s and the paths you allowed are visible; push: %s, through the gate\n' "$tree" "$policy" >&2
    [ "$name" != aider ] || [ ! -r "$AGENTS_MD" ] || set -- --read /usr/share/pulsar/AGENTS.md "$@"
    podman "${args[@]}" "$img" "$real" "$@"
}

# The project whose settings apply here: the git root, or for one of its
# worktrees inside it, the main checkout, so `sandbox on --here` covers both.
settings_root() {
    local r m
    r=$(project_root "${1:-$PWD}")
    if m=$(worktree_main "$r"); then printf '%s\n' "${m%%$'\t'*}"; else printf '%s\n' "$r"; fi
}

# on|off: whether an agent starts sandboxed in project $2, given --sandbox
# (on), --no-sandbox (off) or neither ("") as $1. A repo that says sandbox
# beats --no-sandbox. Call as $(...) || exit 1: a refusal dies in the subshell.
agent_mode() {
    local mode=$1 root=$2 eff
    eff=$(setting_resolve sandbox "$root")
    if [ "$mode" = off ] && [ "${eff#*$'\t'}" = "this project: .pulsar/agent.toml" ]; then
        die "this project's .pulsar/agent.toml says to sandbox agents; remove that line to run one unsandboxed here"
    fi
    [ -n "$mode" ] || mode=${eff%%$'\t'*}
    printf '%s\n' "$mode"
}

AGENT_RUN_USAGE="usage: pulsar agent run <name> [--sandbox|--no-sandbox] [--tmux <session> [--new] [--dir <path> | <path>] [--worktree] [--title <text>] [--prompt <text>]] [-- args]"

# The one place that decides how an agent starts: the shim calls this.
# Only what follows -- reaches the agent. A bare word after the name is the
# session's folder (`--tmux work ~/code/x`), never the agent's first prompt.
agent_run() {
    local name="" mode="" tname="" fresh=0 dir="" tmux=0 worktree=0 bare=""
    AGENT_RUN_TITLE=""; AGENT_RUN_PROMPT=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --sandbox) mode=on ;;
            --no-sandbox) mode=off ;;
            --tmux) [ $# -ge 2 ] || die "--tmux wants a session name"; tmux=1; tname=$2; shift ;;
            --tmux=*) tmux=1; tname=${1#--tmux=} ;;
            --new) fresh=1 ;;
            --worktree) worktree=1 ;;
            --dir) [ $# -ge 2 ] || die "--dir wants a folder"; dir=$2; shift ;;
            --dir=*) dir=${1#--dir=} ;;
            --title) [ $# -ge 2 ] || die "--title wants a title"; AGENT_RUN_TITLE=$2; shift ;;
            --prompt) [ $# -ge 2 ] || die "--prompt wants what to ask the agent"; AGENT_RUN_PROMPT=$2; shift ;;
            --) shift; break ;;
            -*) die "unknown option: $1 (${AGENT_RUN_USAGE})" ;;
            *)
                if [ -z "$name" ]; then name=$1
                elif [ -z "$bare" ]; then bare=$1
                else die "one folder only, got ${bare} and $1; arguments for the agent go after --"
                fi ;;
        esac
        shift
    done
    [ -n "$name" ] || die "$AGENT_RUN_USAGE"
    agent_row "$name" || die "unknown agent: ${name} (known: $(agent_names))"
    if [ -n "$bare" ]; then
        [ "$tmux" = 1 ] || die "a folder goes with --tmux <session>, got ${bare}; arguments for the agent go after --"
        [ -z "$dir" ] || die "two folders, --dir ${dir} and ${bare}"
        [ -d "$bare" ] || die "not a folder: ${bare}; arguments for the agent go after --"
        dir=$bare
    fi
    [ "$tmux" = 1 ] || [ -z "${AGENT_RUN_TITLE:-}${AGENT_RUN_PROMPT:-}" ] || die "--title and --prompt go with --tmux <session>"
    if [ "$tmux" = 1 ]; then
        agent_tmux "$tname" "$name" "$mode" "$fresh" "$dir" "$worktree" "$@"
        return
    fi
    [ "$fresh" = 0 ] && [ -z "$dir" ] && [ "$worktree" = 0 ] || die "--new, --dir and --worktree go with --tmux <session>"
    mode=$(agent_mode "$mode" "$(settings_root)") || exit 1
    if [ "$mode" = on ]; then
        sandbox_run "$name" "$@"
        return
    fi
    local cmd
    cmd=$(agent_command "$name") || die "${name} is not installed (pulsar agent add ${name})"
    # aider reads nothing unless told, so it is told about the guide here
    # rather than in the shim: decided at each start, it follows the image.
    [ "$name" != aider ] || [ ! -r "$AGENTS_MD" ] || set -- --read "$AGENTS_MD" "$@"
    if is_our_shim "$cmd"; then
        exec toolbox run -c "$AGENT_BOX" env NPM_CONFIG_PREFIX="$AGENT_PREFIX" "${AGENT_PREFIX}/bin/${A_BIN}" "$@"
    fi
    exec "$cmd" "$@"
}
