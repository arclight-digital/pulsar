# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): pulsar agent: installing agents, registering Pulsar with them, guard, default and ask, and the agent command itself.

# ---------------------------------------------------------------------------
# agent guide -- the machine's own briefing for a coding agent.
#
# One vendor-neutral file in the image, at a path that moves with every update,
# so the guide can never describe a system older than the one it ships in.
# This command is the discovery path that works for every agent, including the
# ones that read nothing on their own: "run `pulsar agent guide`" is one line
# to put in any prompt. The per-vendor pointers live in `agent add`, written
# only for the agent the user actually chose.
# ---------------------------------------------------------------------------
AGENTS_MD=${PULSAR_AGENTS_MD:-/usr/share/pulsar/AGENTS.md}

# ---------------------------------------------------------------------------
# agent add -- a coding agent CLI, in a toolbox, on demand.
#
# Nothing here runs until somebody asks for a named agent. The image installs
# no agent and favours none: the table below is the whole of the opinion, and
# every row uses the install its vendor documents (checked 2026-09-26), not a
# packaging of ours that would need maintaining.
#
# WHERE THINGS GO, and why each is where it is:
#
#   the runtime   node/npm or uv, inside the `agents` toolbox via its own
#                 passwordless sudo. That is container root, not host root:
#                 the image and the host's rpm database never see it.
#   the agent     $XDG_DATA_HOME/pulsar/agents, one npm/uv prefix, written as
#                 the user. It is in $HOME, which the box shares, so an
#                 upgrade or a removed box leaves it where it was.
#   the command   ~/.local/bin/<cli>, a shim that runs the agent in the box,
#                 so `claude` or `codex` works from any host terminal.
#
# Every agent goes through npm or uv even where the vendor ALSO offers a curl
# script, because those scripts install their own launcher at exactly
# ~/.local/bin/<cli> -- the path the shim needs -- and $HOME is shared, so
# running one inside the box would overwrite the shim from the host's point of
# view. npm is a documented method for all four npm-shipped agents, and uv is
# aider's own recommended installer.
#
# The toolbox is a TIDINESS boundary, not a security one. It shares $HOME, the
# session bus and (through flatpak-spawn) a way out to the host. What keeps an
# agent from breaking the OS is the OS: /usr is read-only, and every change
# to it becomes a NEW deployment with the old one still bootable -- including
# the `rpm-ostree install` that stock polkit lets a wheel desktop session run
# without a password. See docs/AGENTS-SAFETY.md.
# ---------------------------------------------------------------------------
AGENT_BOX=${PULSAR_AGENT_BOX:-agents}
AGENT_PREFIX=${PULSAR_AGENT_PREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/pulsar/agents}
AGENT_SHIMS=${PULSAR_AGENT_SHIMS:-$HOME/.local/bin}
SHIM_MARK="# pulsar-agent-shim"

# name <TAB> command <TAB> installer <TAB> package <TAB> prompt <TAB> description.
# installer: npm or uv (the package, inside the box), or download (the
# vendor's own release manifest; agy publishes no package). prompt is how
# `agent ask` hands it a first message and stays interactive: arg (a
# positional prompt), i (-i), prompt (--prompt, sent once a model is ready),
# read (none: the report goes in with --read). Deliberately nothing
# Microsoft-owned: GitHub Copilot's CLI is a fine opt-in for anyone who wants
# it, but a row here is a default suggestion, and that is not one.
AGENTS_TABLE='claude	claude	npm	@anthropic-ai/claude-code	arg	Claude Code (Anthropic)
codex	codex	npm	@openai/codex	arg	Codex CLI (OpenAI)
agy	agy	download	antigravity.google	i	Antigravity CLI (Google)
opencode	opencode	npm	@opencode/cli	prompt	opencode (open source, any provider)'

# Rows that are no longer suggested, kept so an install made from them still
# runs, links and comes off again. `agent list` shows one only once it is
# installed, and `agent add` still installs it, with RETIRED_WHY said first.
#   gemini  Google moved free and AI Pro/Ultra accounts to Antigravity CLI on
#           2026-06-18; Gemini CLI now signs in only Code Assist Standard or
#           Enterprise accounts and paid API or Vertex keys.
#   aider   no release since 0.86.2 (2026-02-12), no commit since 2026-05-22.
AGENTS_RETIRED='gemini	gemini	npm	@google/gemini-cli	i	Gemini CLI (Google)
aider	aider	uv	aider-chat	read	aider (open source, any provider)'

retired_why() {
    case "$1" in
        gemini) printf 'Gemini CLI no longer signs in free or Google AI Pro/Ultra accounts; those moved to Antigravity CLI (pulsar agent add agy). It still works with a Code Assist Standard or Enterprise account or a paid API key.\n' ;;
        aider)  printf 'aider has had no release since February 2026, and reads no MCP servers or skills.\n' ;;
        *)      return 1 ;;
    esac
}

# Loads one row into A_NAME A_BIN A_METHOD A_PKG A_PROMPT A_DESC; fails on an unknown name.
agent_row() {
    local line
    line=$(printf '%s\n%s\n' "$AGENTS_TABLE" "$AGENTS_RETIRED" | awk -F'\t' -v n="$1" '$1 == n') || true
    [ -n "$line" ] || return 1
    IFS=$'\t' read -r A_NAME A_BIN A_METHOD A_PKG A_PROMPT A_DESC <<<"$line"
}

agent_names() { printf '%s\n' "$AGENTS_TABLE" | cut -f1 | paste -sd' ' -; }

# The rows to show and to look through for installs: every suggested one,
# and a retired one only where it is installed, as Pulsar's or natively.
agent_rows() {
    local n b rest
    printf '%s\n' "$AGENTS_TABLE"
    while IFS=$'\t' read -r n b rest; do
        if is_our_shim "${AGENT_SHIMS}/${b}" || native_launcher "$b" >/dev/null; then
            printf '%s\t%s\t%s\n' "$n" "$b" "$rest"
        fi
    done <<<"$AGENTS_RETIRED"
}

box_exists() {
    toolbox list --containers 2>/dev/null | awk 'NR > 1 { print $2 }' | grep -Fxq "$AGENT_BOX"
}

in_box() { toolbox run -c "$AGENT_BOX" "$@"; }

# Ours means it carries the marker. Anything else at that path -- a native
# installer's launcher, a user's own wrapper -- is not ours to replace.
is_our_shim() { [ -f "$1" ] && grep -qxF "$SHIM_MARK" "$1" 2>/dev/null; }

# An install this recipe did not make: the vendor's own installer (Claude
# Code's install.sh puts a launcher at ~/.local/bin/claude), npm -g in some
# other prefix, a distro package. People install agents that way whatever
# the docs say, and it is a perfectly good way to run one, so it is
# SUPPORTED, not refused: this recipe will not install a second copy over it
# or remove it, but it still gives it the machine guide. Prints the path.
native_launcher() {
    local b=$1 shim="${AGENT_SHIMS}/$1" found
    if { [ -e "$shim" ] || [ -L "$shim" ]; } && ! is_our_shim "$shim"; then
        printf '%s\n' "$shim"; return 0
    fi
    found=$(command -v "$b" 2>/dev/null) || return 1
    [ "$found" != "$shim" ] || return 1
    printf '%s\n' "$found"
}

# Where each agent looks for machine-wide guidance of its own accord, and only
# where the file there would be one this recipe can OWN outright:
#
#   claude    ~/.claude/rules/*.md load in every project, need no import
#             approval, and a rules file is a file of its own -- unlike
#             ~/.claude/CLAUDE.md, which is the user's and which /memory edits.
#   codex     $CODEX_HOME/AGENTS.md is Codex's global instruction file.
#   opencode  ~/.config/opencode/AGENTS.md is opencode's global rules file.
#   agy       ~/.gemini/config/rules/*.md load in every project, like
#             Claude's rules folder, but each needs a `trigger` in YAML front
#             matter or agy drops it, so a bare link to the guide would load
#             nothing. Pulsar writes a five-line file that pulls the guide in
#             with @[label](path), agy's include (a bare @path is only a
#             reference). It names the path, so it still follows the image.
#
# A symlink rather than a copy, so the guide follows the image through every
# update instead of freezing at the version that happened to be booted here.
# gemini gets a hint instead: its only global file is ~/.gemini/GEMINI.md, which
# `/memory add` writes to, and a link into read-only /usr would break that.
# aider reads nothing on its own, so its shim passes --read.
agent_context_path() {
    case "$1" in
        claude)   printf '%s\n' "$HOME/.claude/rules/pulsar.md" ;;
        codex)    printf '%s\n' "${CODEX_HOME:-$HOME/.codex}/AGENTS.md" ;;
        opencode) printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/AGENTS.md" ;;
        agy)      printf '%s\n' "$HOME/.gemini/config/rules/pulsar.md" ;;
        *)        return 1 ;;
    esac
}

# agy's rules file: exactly this text is ours, anything else is the user's.
agy_rule_text() {
    printf -- '---\ntrigger: always_on\n---\n\n@[Pulsar machine guide](%s)\n' "$AGENTS_MD"
}

# Whether $1 is the guide as Pulsar put it there: a link, or agy's file.
is_our_context() {
    if [ "$A_NAME" = agy ]; then
        [ -f "$1" ] && [ ! -L "$1" ] && [ "$(cat "$1")" = "$(agy_rule_text)" ]
    else
        [ -L "$1" ] && [ "$(readlink "$1")" = "$AGENTS_MD" ]
    fi
}

# What an agent has of the guide, as three lines: state, file, line.
#
#   linked    it reads the guide: Pulsar's link at <file>, aider's shim
#             (<file>), or the line the user added to <file>
#   add-line  Pulsar can't link it: adding <line> to <file> gives it the
#             guide. Always so for gemini and a native aider, and for any
#             agent whose file is already the user's own
#   unlinked  nothing there yet; pulsar agent add <name> links it
#   missing   this image has no guide
#
# Read by `agent add` for what it prints and by `agent list --json` for the
# welcome, so a GUI learns the outcome without reading the prose.
agent_guide_state() {
    local target conf
    if [ ! -r "$AGENTS_MD" ]; then printf 'missing\n\n\n'; return 0; fi
    case "$A_NAME" in
        gemini)
            conf="$HOME/.gemini/GEMINI.md"
            if [ -f "$conf" ] && grep -qF "@${AGENTS_MD}" "$conf"; then
                printf 'linked\n%s\n\n' "$conf"
            else
                printf 'add-line\n%s\n@%s\n' "$conf" "$AGENTS_MD"
            fi
            return 0 ;;
        aider)
            conf="$HOME/.aider.conf.yml"
            if is_our_shim "${AGENT_SHIMS}/${A_BIN}"; then
                printf 'linked\n%s\n\n' "${AGENT_SHIMS}/${A_BIN}"
            elif ! native_launcher "$A_BIN" >/dev/null; then
                printf 'unlinked\n\n\n'
            elif [ -f "$conf" ] && grep -qF "$AGENTS_MD" "$conf"; then
                printf 'linked\n%s\n\n' "$conf"
            else
                printf 'add-line\n%s\nread: %s\n' "$conf" "$AGENTS_MD"
            fi
            return 0 ;;
    esac
    target=$(agent_context_path "$A_NAME") || return 1
    if is_our_context "$target"; then
        printf 'linked\n%s\n\n' "$target"
    elif [ -e "$target" ] || [ -L "$target" ]; then
        # Never overwritten: it is the user's file, and a guide is not worth
        # losing someone's instructions over. Any agent follows a sentence.
        printf 'add-line\n%s\nRead %s before changing anything outside the project.\n' "$target" "$AGENTS_MD"
    else
        printf 'unlinked\n%s\n\n' "$target"
    fi
}

link_agent_context() {
    local state file line
    { read -r state; read -r file; read -r line; } < <(agent_guide_state)
    if [ "$state" = unlinked ] && [ -n "$file" ]; then
        mkdir -p "$(dirname "$file")"
        if [ "$A_NAME" = agy ]; then
            agy_rule_text > "$file"
        else
            ln -s "$AGENTS_MD" "$file"
        fi
        printf 'linked the guide at %s\n' "$file"
        return 0
    fi
    case "$state" in
        linked)
            if [ "$A_NAME" = aider ] && is_our_shim "$file"; then
                printf 'the shim passes --read %s whenever the image has it, so aider starts with the guide\n' "$AGENTS_MD"
            elif is_our_context "$file"; then
                printf 'the guide is already linked at %s\n' "$file"
            else
                printf 'the guide is already in %s\n' "$file"
            fi ;;
        add-line)
            if [ "$file" = "$(agent_context_path "$A_NAME")" ]; then
                printf '%s already exists; left alone. The guide was not linked. To give it the guide, add this line to it:\n  %s\n' \
                    "$file" "$line"
            else
                printf 'the guide was not linked: %s has no file Pulsar can link it into. To give it the guide, add this line to %s:\n  %s\n' \
                    "$A_DESC" "$file" "$line"
            fi ;;
        missing)
            printf 'this image has no %s yet; after the next update, rerun this to link the guide\n' "$AGENTS_MD" ;;
    esac
}

# Skills: /usr/share/pulsar/skills/<name>/SKILL.md, in the Agent Skills
# layout (a folder, a SKILL.md with name and description) that each of these
# reads from a folder of its own, per its docs. Linked one skill at a time,
# so a user's own skills beside them are never touched, and linked rather
# than copied so they follow the image. aider reads no skills. Codex moved
# its user skills to ~/.agents/skills and keeps $CODEX_HOME/skills only for
# old installs; agy's global skills are ~/.gemini/config/skills, which its
# desktop app shares.
SKILLS_DIR=${PULSAR_SKILLS:-/usr/share/pulsar/skills}

agent_skills_path() {
    case "$1" in
        claude)   printf '%s\n' "$HOME/.claude/skills" ;;
        codex)    printf '%s\n' "$HOME/.agents/skills" ;;
        agy)      printf '%s\n' "$HOME/.gemini/config/skills" ;;
        gemini)   printf '%s\n' "$HOME/.gemini/skills" ;;
        opencode) printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills" ;;
        *)        return 1 ;;
    esac
}

# Where an older Pulsar linked them, cleaned up on remove.
agent_old_skills_path() {
    case "$1" in
        codex) printf '%s\n' "${CODEX_HOME:-$HOME/.codex}/skills" ;;
        *)     return 1 ;;
    esac
}

link_agent_skills() {
    local dir s target linked=""
    dir=$(agent_skills_path "$A_NAME") || return 0
    [ -d "$SKILLS_DIR" ] || return 0
    for s in "$SKILLS_DIR"/*/; do
        s=${s%/}
        [ -r "${s}/SKILL.md" ] || continue
        target="${dir}/$(basename "$s")"
        if [ -L "$target" ] && [ "$(readlink "$target")" = "$s" ]; then
            continue
        elif [ -e "$target" ] || [ -L "$target" ]; then
            printf '%s already exists; left alone\n' "$target"
            continue
        fi
        mkdir -p "$dir"
        ln -s "$s" "$target"
        linked+="${linked:+, }$(basename "$s")"
    done
    [ -z "$linked" ] || printf 'linked skills into %s: %s\n' "$dir" "$linked"
}

unlink_agent_skills() {
    local dir l
    for dir in "$(agent_skills_path "$A_NAME")" "$(agent_old_skills_path "$A_NAME")"; do
        [ -n "$dir" ] && [ -d "$dir" ] || continue
        for l in "$dir"/*; do
            # only links into the image's skills, never the user's own
            [ -L "$l" ] || continue
            case "$(readlink "$l")" in "${SKILLS_DIR}"/*) rm -f "$l"; printf 'removed the skill link %s\n' "$l" ;; esac
        done
    done
}

# ---------------------------------------------------------------------------
# mcp -- this machine's facts as MCP tools (scripts/pulsar-mcp). `agent add`
# registers it in each agent's own MCP config, as an entry named "pulsar"
# that is written only if none exists and removed only if it is ours.
#
# An agent in the agents toolbox cannot see /usr/bin/pulsar, so its entry
# starts the server on the host through flatpak-spawn; a native install runs
# on the host already.
# ---------------------------------------------------------------------------
MCP_TOOL=${PULSAR_MCP:-/usr/libexec/pulsar/pulsar-mcp}

cmd_mcp() {
    case "${1:-}" in
        -h|--help)
            printf 'usage: pulsar mcp   an MCP server on stdio: doctor, status, manifest, report, crashes,\n                    update_check, agent_status, theme_list/current/set, and the guide.\n                    pulsar agent add registers it with each agent. Nothing in it needs root.\n'
            return 0 ;;
    esac
    [ $# -eq 0 ] || die "'mcp' takes no arguments (it speaks MCP on stdin/stdout)"
    [ -r "$MCP_TOOL" ] || die "the MCP server is not staged in this image (${MCP_TOOL})"
    PULSAR_CLI=$(realpath "$SELF") PULSAR_AGENTS_MD="$AGENTS_MD" exec python3 "$MCP_TOOL"
}

# The command an agent's MCP entry runs, as a JSON array: host or box.
mcp_argv_json() {
    local cli
    cli=$(realpath "$SELF")
    if [ "${1:-}" = box ]; then
        jq -n -c --arg c "$cli" '["flatpak-spawn", "--host", $c, "mcp"]'
    else
        jq -n -c --arg c "$cli" '[$c, "mcp"]'
    fi
}

# A JSON config's .<path> gets our entry, only if it has none. Atomic.
json_add_entry() {
    local file=$1 path=$2 entry=$3 tmp
    mkdir -p "$(dirname "$file")"
    [ -s "$file" ] || printf '{}\n' > "$file"
    jq -e . "$file" >/dev/null 2>&1 || { printf '%s is not JSON; add the pulsar MCP server to it yourself\n' "$file"; return 0; }
    if jq -e "getpath(${path}) != null" "$file" >/dev/null; then
        printf '%s already has an MCP server named pulsar; left alone\n' "$file"; return 0
    fi
    tmp=$(mktemp "${file}.XXXXXX")
    jq --argjson e "$entry" "setpath(${path}; \$e)" "$file" > "$tmp" && chmod --reference="$file" "$tmp" && mv "$tmp" "$file"
    printf 'registered the pulsar MCP server in %s\n' "$file"
}

# ...and loses it, only if it is still the one we wrote.
json_remove_entry() {
    local file=$1 path=$2 tmp
    [ -f "$file" ] && jq -e . "$file" >/dev/null 2>&1 || return 0
    # ours: it runs pulsar with the argument "mcp" (in whichever shape the
    # agent's config spells a command)
    jq -e "getpath(${path}) | tostring | (contains(\"pulsar\") and contains(\"\\\"mcp\\\"\"))" "$file" >/dev/null 2>&1 || return 0
    tmp=$(mktemp "${file}.XXXXXX")
    jq "delpaths([${path}])" "$file" > "$tmp" && chmod --reference="$file" "$tmp" && mv "$tmp" "$file"
    printf 'removed the pulsar MCP server from %s\n' "$file"
}

register_mcp() {
    local where=${1:-box} argv cmd f
    [ -r "$MCP_TOOL" ] || return 0
    have jq || return 0
    argv=$(mcp_argv_json "$where")
    case "$A_NAME" in
        claude)
            json_add_entry "$HOME/.claude.json" '["mcpServers","pulsar"]' \
                "$(jq -n -c --argjson a "$argv" '{type: "stdio", command: $a[0], args: $a[1:]}')" ;;
        gemini)
            json_add_entry "$HOME/.gemini/settings.json" '["mcpServers","pulsar"]' \
                "$(jq -n -c --argjson a "$argv" '{command: $a[0], args: $a[1:]}')" ;;
        # agy reads its servers from here, not from ~/.gemini/settings.json
        agy)
            json_add_entry "$HOME/.gemini/config/mcp_config.json" '["mcpServers","pulsar"]' \
                "$(jq -n -c --argjson a "$argv" '{command: $a[0], args: $a[1:]}')" ;;
        opencode)
            json_add_entry "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json" '["mcp","pulsar"]' \
                "$(jq -n -c --argjson a "$argv" '{type: "local", command: $a, enabled: true}')" ;;
        codex)
            f="${CODEX_HOME:-$HOME/.codex}/config.toml"
            if [ -f "$f" ] && grep -q '^\[mcp_servers\.pulsar\]' "$f"; then
                printf '%s already has an MCP server named pulsar; left alone\n' "$f"; return 0
            fi
            mkdir -p "$(dirname "$f")"
            cmd=$(printf '%s' "$argv" | jq -r '.[0] | tojson')
            local gap="" rest
            [ ! -s "$f" ] || gap=$'\n'
            rest=$(printf '%s' "$argv" | jq -c '.[1:]')
            printf '%s# pulsar-mcp: written by pulsar agent add codex\n[mcp_servers.pulsar]\ncommand = %s\nargs = %s\n' \
                "$gap" "$cmd" "$rest" >> "$f"
            printf 'registered the pulsar MCP server in %s\n' "$f" ;;
    esac
}

# Turn-end bells for the agents that don't take Claude's hooks: each rings
# the bell of the pane it runs in (PULSAR_TTY, which the pane sets; in the
# sandbox, the container's own terminal, which is the pane's), and tmux's
# alert-bell hook does the rest, as for Claude (agent_notify).
# shellcheck disable=SC2016  # expanded by the hook's sh
AGENT_BELL='printf "\a" > "${PULSAR_TTY:-/dev/tty}" 2>/dev/null; exit 0'
# A turn's real end, told apart from any bell an agent's output rings: the
# turn-end hooks Pulsar gives Codex and agy leave <session>.turn beside the
# session's record (not in a sandbox, which can't see it), then ring.
# shellcheck disable=SC2016  # expanded by the hook's sh
AGENT_TURN='[ -z "${PULSAR_SESSION_RECORD:-}" ] || : > "${PULSAR_SESSION_RECORD%.session}.turn" 2>/dev/null; '

# Codex runs its `notify` program after every turn. Given on its command line
# (-c, for this session only), and only when the user has no notify of their
# own, since this would take its place. Prints the arguments, or nothing.
codex_turn_notify() {
    local f="${CODEX_HOME:-$HOME/.codex}/config.toml"
    [ -f "$f" ] && grep -qE '^[[:space:]]*notify[[:space:]]*=' "$f" && return 0
    printf '%s\n' -c "notify=['sh','-c','${AGENT_TURN}${AGENT_BELL}']"
}

# agy reads hooks only from its hooks.json (its --settings can't add one), so
# Pulsar keeps one entry there, named pulsar, beside the user's: a Stop hook
# that rings only inside a Pulsar session (PULSAR_TTY, or the sandbox) and
# only once agy is fully idle (not while a subagent works). Added when an agy
# session starts, removed by agent remove agy.
agy_turn_hook() {
    have jq || return 0
    local f="${HOME}/.gemini/config/hooks.json" cmd tmp
    # shellcheck disable=SC2016
    # At a real turn end (fullyIdle) in a Pulsar session: mail from other
    # sessions (agent_mail_render, <session>.mail beside its record) is
    # agy's own "keep going", {"decision": "continue", "reason": ...},
    # taken by renaming it as Claude's is; then the bell, for Pulsar.
    cmd='p=$(cat); case "$p" in *"\"fullyIdle\":false"*|*"\"fullyIdle\": false"*) exit 0 ;; esac; [ -n "${PULSAR_TTY}${PULSAR_SANDBOX}" ] || exit 0; m="${PULSAR_SESSION_RECORD%.session}.mail"; [ -n "${PULSAR_SESSION_RECORD:-}" ] && [ -f "$m" ] && mv -f "$m" "$m.taken" 2>/dev/null && head -n 1 "$m.taken"; '"${AGENT_TURN}${AGENT_BELL}"
    mkdir -p "$(dirname "$f")"
    [ -s "$f" ] || printf '{}\n' > "$f"
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { printf '%s is not JSON; left alone\n' "$f"; return 0; }
    # ours as this version writes it: nothing to do. An older one of ours
    # (it rings $PULSAR_TTY) is replaced; a "pulsar" entry the user wrote stays.
    local have; have=$(jq -r '.pulsar.Stop[0].command // empty' "$f" 2>/dev/null) || have=""
    [ "$have" != "$cmd" ] || return 0
    if jq -e '.pulsar' "$f" >/dev/null 2>&1 && [[ "$have" != *PULSAR_TTY* ]]; then return 0; fi
    tmp=$(mktemp "${f}.XXXXXX")
    jq --arg c "$cmd" '.pulsar = {Stop: [{type: "command", command: $c, timeout: 5}]}' "$f" > "$tmp" \
        && chmod --reference="$f" "$tmp" && mv "$tmp" "$f"
    printf 'added the pulsar turn-end hook to %s\n' "$f"
}

agy_turn_hook_remove() {
    local f="${HOME}/.gemini/config/hooks.json" tmp
    have jq && [ -f "$f" ] || return 0
    # ours only: a "pulsar" entry the user wrote is theirs
    jq -e '.pulsar.Stop[0].command // "" | contains("PULSAR_TTY")' "$f" >/dev/null 2>&1 || return 0
    tmp=$(mktemp "${f}.XXXXXX")
    jq 'del(.pulsar)' "$f" > "$tmp" && chmod --reference="$f" "$tmp" && mv "$tmp" "$f"
    printf 'removed the pulsar turn-end hook from %s\n' "$f"
}

unregister_mcp() {
    local f tmp
    # and the turn-end hook kept beside it in agy's own config
    [ "$A_NAME" != agy ] || agy_turn_hook_remove
    case "$A_NAME" in
        claude)   json_remove_entry "$HOME/.claude.json" '["mcpServers","pulsar"]' ;;
        gemini)   json_remove_entry "$HOME/.gemini/settings.json" '["mcpServers","pulsar"]' ;;
        agy)      json_remove_entry "$HOME/.gemini/config/mcp_config.json" '["mcpServers","pulsar"]' ;;
        opencode) json_remove_entry "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json" '["mcp","pulsar"]' ;;
        codex)
            f="${CODEX_HOME:-$HOME/.codex}/config.toml"
            [ -f "$f" ] && grep -q '^# pulsar-mcp: written by' "$f" || return 0
            tmp=$(mktemp "${f}.XXXXXX")
            # our comment line, the table header, and its keys up to the next table
            awk '/^# pulsar-mcp: written by/ { skip = 1; next }
                 skip && /^\[/ && !/^\[mcp_servers\.pulsar\]/ { skip = 0 }
                 !skip' "$f" > "$tmp" && chmod --reference="$f" "$tmp" && mv "$tmp" "$f"
            printf 'removed the pulsar MCP server from %s\n' "$f" ;;
    esac
}

unlink_agent_context() {
    local target
    target=$(agent_context_path "$A_NAME") || return 0
    # Only the link this recipe made. A file the user wrote there stays.
    if is_our_context "$target"; then
        rm -f "$target"
        printf 'removed the guide link at %s\n' "$target"
    fi
}

write_agent_shim() {
    local shim="${AGENT_SHIMS}/${A_BIN}" real="${AGENT_PREFIX}/bin/${A_BIN}" guide=""
    # aider reads nothing unless told. Decided each time the shim runs, not
    # when it is written: a shim written on an image without the guide would
    # otherwise never pass it, even after an update ships one.
    if [ "$A_NAME" = aider ]; then
        guide="[ -r $(sq "$AGENTS_MD") ] && set -- --read $(sq "$AGENTS_MD") \"\$@\""
    fi
    mkdir -p "$AGENT_SHIMS"
    # NPM_CONFIG_PREFIX travels on the command line because toolbox forwards
    # only a fixed list of variables. It is what keeps a self-updating agent
    # (`claude update`, gemini's updater) writing to the prefix it was
    # installed in, rather than to the box's /usr, which needs sudo and fails.
    local cli
    cli=$(realpath "$SELF")
    cat > "$shim" <<EOF
#!/bin/sh
${SHIM_MARK}
# ${A_DESC}.
# Written by \`pulsar agent add ${A_NAME}\`; remove with
# \`pulsar agent remove ${A_NAME}\`. Edits here are overwritten by a rerun.
#
# \`pulsar agent run\` decides how it starts: in the '${AGENT_BOX}' toolbox,
# or sandboxed (pulsar agent sandbox). toolbox forwards only a fixed set of
# environment variables, so an API key exported in this shell does not reach
# the agent there. Log in through the agent instead.
real=$(sq "$real")
prefix=$(sq "$AGENT_PREFIX")
${guide}
# Inside the agents box itself: run the real thing directly, since toolbox
# cannot nest. Inside ANY OTHER container that shares this \$HOME (a dev box
# with no node or uv), hop back to the host and start it from there.
if [ -e /run/.containerenv ]; then
    if grep -qx 'name="${AGENT_BOX}"' /run/.containerenv 2>/dev/null; then
        NPM_CONFIG_PREFIX="\$prefix" exec "\$real" "\$@"
    fi
    exec flatpak-spawn --host $(sq "$cli") agent run $(sq "$A_NAME") -- "\$@"
fi
exec $(sq "$cli") agent run $(sq "$A_NAME") -- "\$@"
EOF
    chmod 0755 "$shim"
    printf 'wrote %s\n' "$shim"
}

agent_list() {
    local n b m p d state native notes="" gs gf gl
    if [ "${JSON:-0}" = 1 ]; then
        need jq
        while IFS=$'\t' read -r n b m p _ d; do
            state=available
            if is_our_shim "${AGENT_SHIMS}/${b}"; then state=installed
            elif native_launcher "$b" >/dev/null; then state=native
            fi
            # guide: what agent_guide_state says, for the welcome to report
            # after an add without reading add's prose
            agent_row "$n"
            { read -r gs; read -r gf; read -r gl; } < <(agent_guide_state)
            jq -n -c --arg n "$n" --arg b "$b" --arg m "$m" --arg p "$p" --arg d "$d" --arg s "$state" \
                --arg gs "$gs" --arg gf "$gf" --arg gl "$gl" \
                '{name: $n, command: $b, installer: $m, package: $p, description: $d, state: $s,
                  guide: {state: $gs, file: $gf, line: $gl}}'
        done < <(agent_rows) | jq -s '.'
        return 0
    fi
    printf '%-9s %-9s %-34s %-10s %s\n' NAME COMMAND INSTALL STATE DESCRIPTION
    while IFS=$'\t' read -r n b m p _ d; do
        state=-
        if is_our_shim "${AGENT_SHIMS}/${b}"; then
            state=installed
        elif native=$(native_launcher "$b"); then
            state=native
            notes+="  ${n}: ${native} (its own installer; Pulsar leaves it alone)"$'\n'
        fi
        printf '%-9s %-9s %-34s %-10s %s\n' "$n" "$b" "${m} ${p}" "$state" "$d"
    done < <(agent_rows)
    [ -z "$notes" ] || printf '\nnative installs:\n%s' "$notes"
    printf '\nnone is installed by default. toolbox: %s  prefix: %s\n' "$AGENT_BOX" "$AGENT_PREFIX"
}

# agy publishes no package: its own install.sh reads a release manifest,
# checks the tarball's SHA-512 and copies one static binary to
# ~/.local/bin/agy, then runs `agy install`, which edits the shell profile.
# Pulsar does the same first three steps into the prefix, from the same
# manifest, and skips the profile: the shim is what goes on PATH. agy
# updates that binary in place on its own.
AGY_MANIFESTS=${PULSAR_AGY_MANIFESTS:-https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests}

agy_download() {
    local dest=$1 arch manifest url sum tmp
    need curl; need jq; need sha512sum; need tar
    case "$(uname -m)" in
        x86_64|amd64)  arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) die "Antigravity CLI has no Linux build for $(uname -m)" ;;
    esac
    manifest=$(curl -fsSL "${AGY_MANIFESTS}/linux_${arch}.json") \
        || die "could not fetch the Antigravity CLI release manifest"
    url=$(jq -r '.url // empty' <<<"$manifest" 2>/dev/null) || url=""
    sum=$(jq -r '.sha512 // empty' <<<"$manifest" 2>/dev/null) || sum=""
    [ -n "$url" ] && [ -n "$sum" ] || die "the Antigravity CLI release manifest has no url or sha512"
    mkdir -p "$(dirname "$dest")"
    tmp=$(mktemp -d "${dest}.XXXXXX")
    if ! curl -fsSL -o "${tmp}/payload" "$url"; then rm -rf "$tmp"; die "could not download ${url}"; fi
    if [ "$(sha512sum < "${tmp}/payload" | cut -d' ' -f1)" != "$sum" ]; then
        rm -rf "$tmp"; die "the Antigravity CLI download does not match the manifest's SHA-512; nothing was installed"
    fi
    case "$url" in
        *.tar.gz*)
            tar -xzf "${tmp}/payload" -C "$tmp" antigravity || { rm -rf "$tmp"; die "the Antigravity CLI archive has no antigravity binary"; }
            mv "${tmp}/antigravity" "${tmp}/payload" ;;
    esac
    chmod 0755 "${tmp}/payload"
    mv -f "${tmp}/payload" "$dest"
    rm -rf "$tmp"
}

# A program in the box that opens a link opens it on the host: the box has no
# browser, and an agent's sign-in (agy's, Codex's) opens one with xdg-open.
box_xdg_open() {
    in_box sh -c 'command -v xdg-open' >/dev/null 2>&1 && return 0
    in_box sudo sh -c 'printf "#!/bin/sh\n# pulsar: open links on the host\nexec flatpak-spawn --host xdg-open \"\$@\"\n" > /usr/local/bin/xdg-open && chmod 0755 /usr/local/bin/xdg-open' \
        || printf 'note: could not add xdg-open to %s; a sign-in that opens a browser prints its link instead\n' "$AGENT_BOX"
}

# A package an agent used to come as, in Pulsar's prefix; it holds the same
# command name, so it goes before the new one can install.
agent_old_pkg() {
    case "$1" in
        opencode) printf 'opencode-ai\n' ;;   # opencode 1; 2 is @opencode/cli
        *) return 1 ;;
    esac
}

agent_install() {
    local native why old
    if why=$(retired_why "$A_NAME"); then printf 'note: %s\n' "$why"; fi
    # Checked BEFORE anything is created or downloaded. A native install is
    # not an error: it is the agent the user already chose to run. Installing
    # a second copy in the box would put two versions on PATH, one shadowing
    # the other, so it gets the guide and nothing else.
    if native=$(native_launcher "$A_BIN"); then
        printf '%s is already installed by its own installer at %s\n' "$A_DESC" "$native"
        printf 'leaving it as it is: it runs on the host, not in the %s toolbox\n' "$AGENT_BOX"
        link_agent_context
        link_agent_skills
        register_mcp host
        printf 'done; nothing was installed in the toolbox\n'
        return 0
    fi
    need toolbox

    if box_exists; then
        printf 'using toolbox %s\n' "$AGENT_BOX"
    else
        # No --image: toolbox picks fedora-toolbox for the host's own release,
        # which is the choice a pin here would only ever lag behind.
        printf 'creating toolbox %s\n' "$AGENT_BOX"
        toolbox --assumeyes create "$AGENT_BOX" || die "could not create toolbox ${AGENT_BOX}"
    fi

    # The runtime is installed lazily and once: the second agent in the box
    # finds npm already there. `nodejs npm` rather than a versioned name, so
    # the box follows Fedora's default stream (Node 22 on F44, above every
    # agent's floor) instead of a number this file would have to chase.
    local tool=""
    case "$A_METHOD" in
        npm) tool=npm ;;
        uv)  tool=uv ;;
        download) ;;
        *)   die "internal error: unknown installer '${A_METHOD}'" ;;
    esac
    if [ -n "$tool" ] && ! in_box sh -c "command -v ${tool}" >/dev/null 2>&1; then
        printf 'installing %s inside %s\n' "$tool" "$AGENT_BOX"
        case "$tool" in
            npm) in_box sudo dnf install -y nodejs npm ;;
            uv)  in_box sudo dnf install -y uv ;;
        esac || die "could not install ${tool} inside ${AGENT_BOX}"
    fi

    mkdir -p "$AGENT_PREFIX"
    printf 'installing %s (%s %s) into %s\n' "$A_DESC" "$A_METHOD" "$A_PKG" "$AGENT_PREFIX"
    case "$A_METHOD" in
        npm)
            if old=$(agent_old_pkg "$A_NAME") && [ -d "${AGENT_PREFIX}/lib/node_modules/${old}" ]; then
                printf 'removing %s, which %s replaces\n' "$old" "$A_PKG"
                in_box npm uninstall -g --prefix "$AGENT_PREFIX" "$old" || die "npm could not remove ${old}"
            fi
            # Claude Code and opencode 2 fetch their native binary in a
            # postinstall script. npm 11 runs it with a warning; npm 12 skips
            # any not allowed, leaving a command that cannot start.
            in_box npm install -g --prefix "$AGENT_PREFIX" --allow-scripts="$A_PKG" "${A_PKG}@latest" \
                || die "npm could not install ${A_PKG}" ;;
        download)
            agy_download "${AGENT_PREFIX}/bin/${A_BIN}" ;;
        uv)
            # aider's documented uv line, with every directory uv would write
            # pointed into the prefix, so removal has one place to clean.
            in_box env "UV_TOOL_DIR=${AGENT_PREFIX}/uv-tools" \
                       "UV_TOOL_BIN_DIR=${AGENT_PREFIX}/bin" \
                       "UV_PYTHON_INSTALL_DIR=${AGENT_PREFIX}/python" \
                uv tool install --force --python python3.12 --with pip "${A_PKG}@latest" \
                || die "uv could not install ${A_PKG}" ;;
    esac
    [ -x "${AGENT_PREFIX}/bin/${A_BIN}" ] \
        || die "the installer reported success, but ${AGENT_PREFIX}/bin/${A_BIN} is not there"

    write_agent_shim
    box_xdg_open
    link_agent_context
    link_agent_skills
    register_mcp box
    case ":${PATH}:" in
        *":${AGENT_SHIMS}:"*) ;;
        *) printf "note: %s is not on PATH in this shell; Fedora's ~/.bashrc adds it in a new bash shell\n" "$AGENT_SHIMS" ;;
    esac
    printf "done: run \`%s\` from any terminal\n" "$A_BIN"
}

agent_remove() {
    local shim="${AGENT_SHIMS}/${A_BIN}" native
    if is_our_shim "$shim"; then
        rm -f "$shim"
        printf 'removed %s\n' "$shim"
    elif native=$(native_launcher "$A_BIN"); then
        printf '%s was installed by its own installer; remove it with that installer\n' "$native"
        unlink_agent_context
        unlink_agent_skills
        unregister_mcp
        return 0
    fi
    unlink_agent_context
    unlink_agent_skills
    unregister_mcp
    local box="" old
    # a downloaded binary is one file, and needs no box to come off
    if [ "$A_METHOD" = download ]; then
        rm -f "${AGENT_PREFIX}/bin/${A_BIN}" "${AGENT_PREFIX}/bin/${A_BIN}".*.old
    fi
    if have toolbox && box_exists; then
        box=", and the ${AGENT_BOX} toolbox (toolbox rm -f ${AGENT_BOX})"
        case "$A_METHOD" in
            npm) in_box npm uninstall -g --prefix "$AGENT_PREFIX" "$A_PKG" || true
                 if old=$(agent_old_pkg "$A_NAME") && [ -d "${AGENT_PREFIX}/lib/node_modules/${old}" ]; then
                     in_box npm uninstall -g --prefix "$AGENT_PREFIX" "$old" || true
                 fi ;;
            uv)  in_box env "UV_TOOL_DIR=${AGENT_PREFIX}/uv-tools" \
                            "UV_TOOL_BIN_DIR=${AGENT_PREFIX}/bin" \
                     uv tool uninstall "$A_PKG" || true ;;
        esac
    else
        printf 'no %s toolbox here; the package files, if any, are under %s\n' "$AGENT_BOX" "$AGENT_PREFIX"
    fi
    # Said out loud, because "removed" would otherwise read as "gone": the
    # agent's logins, history and settings are the user's data, not ours.
    printf "left in place: the agent's own config and credentials in \$HOME%s\n" "$box"
}

# ---------------------------------------------------------------------------
# agent guard -- make the silent system changes ask for a password.
#
# Stock Fedora polkit rules let a wheel user in an active local session layer
# packages, roll back, clean up deployments and install or remove system
# Flatpaks with no prompt, and so can anything that user starts. The rule that
# undoes that ships inert in the image; `on` copies it into /etc, where polkit
# picks it up at once (it watches the directory). Opt-in, not image policy: it
# departs from Silverblue's defaults and costs a human one more prompt.
#
# The state is read from polkit, not from the file: /etc/polkit-1/rules.d is
# not readable by users, and what matters is what polkit answers anyway.
# ---------------------------------------------------------------------------
GUARD_RULE=${PULSAR_GUARD_RULE:-/usr/share/pulsar/polkit/49-pulsar-guard.rules}
POLKIT_RULES_DIR=${PULSAR_POLKIT_RULES_DIR:-/etc/polkit-1/rules.d}
GUARD_MARKER='pulsar agent guard'
GUARD_ACTIONS='org.projectatomic.rpmostree1.install-uninstall-packages
org.projectatomic.rpmostree1.rollback
org.projectatomic.rpmostree1.cleanup
org.freedesktop.Flatpak.app-install
org.freedesktop.Flatpak.app-uninstall'

# action <TAB> yes|auth|no, for this process's session.
guard_answers() {
    local a rc
    while IFS= read -r a; do
        rc=0; pkcheck --action-id "$a" --process $$ >/dev/null 2>&1 || rc=$?
        case "$rc" in
            0) printf '%s\tyes\n' "$a" ;;
            2) printf '%s\tauth\n' "$a" ;;
            *) printf '%s\tno\n' "$a" ;;
        esac
    done <<<"$GUARD_ACTIONS"
}

# on: nothing gated goes through silently. off: all of it does. partial: a
# mix, which a hand-edited rule or a newer stock rule could produce.
guard_state() {
    have pkcheck || { printf 'unknown\n'; return 0; }
    local answers
    answers=$(guard_answers | cut -f2 | sort -u | paste -sd' ' -)
    case "$answers" in
        yes)   printf 'off\n' ;;
        *yes*) printf 'partial\n' ;;
        *)     printf 'on\n' ;;
    esac
}

agent_guard() {
    local sub=${1:-status}
    [ $# -le 1 ] || die "usage: pulsar agent guard [on | off]"
    local dest
    dest="${POLKIT_RULES_DIR}/$(basename "$GUARD_RULE")"
    case "$sub" in
        -h|--help)
            cat <<'EOF'
usage: pulsar agent guard           what polkit answers for your session
       sudo pulsar agent guard on   layering, rollback, cleanup and system
                                    Flatpak installs and removals ask for
                                    a password
       sudo pulsar agent guard off  remove the rule: Fedora's default, where an
                                    administrator in an active local session
                                    is not asked

The rule matches the action, not the program, so a coding agent you run gets
the prompt too. Updates are not gated, and root (sudo) is not affected.
EOF
            ;;
        status)
            [ "$(id -u)" -ne 0 ] || die "'agent guard' checks your session; drop the sudo"
            need pkcheck
            local a v label
            if [ "${JSON:-0}" = 1 ]; then
                need jq
                guard_answers | jq -R -s --arg st "$(guard_state)" \
                    '{state: $st, actions: [split("\n")[] | select(length > 0) | split("\t") | {id: .[0], answer: .[1]}]}'
                return 0
            fi
            printf 'guard: %s\n\n' "$(guard_state)"
            while IFS=$'\t' read -r a v; do
                case "$v" in
                    yes)  label='no prompt' ;;
                    auth) label='asks for a password' ;;
                    *)    label='denied' ;;
                esac
                printf '  %-58s %s\n' "$a" "$label"
            done < <(guard_answers)
            ;;
        off)
            no_json "agent guard off"
            need_root "agent guard off"
            if [ ! -e "$dest" ]; then
                printf 'guard is already off (no %s)\n' "$dest"; return 0
            fi
            grep -qF "$GUARD_MARKER" "$dest" \
                || die "${dest} is not the rule 'agent guard' installs; leaving it alone"
            rm -f "$dest" || die "could not remove ${dest}"
            printf 'guard off: removed %s\n' "$dest"
            ;;
        on)
            no_json "agent guard on"
            need_root "agent guard on"
            [ -r "$GUARD_RULE" ] || die "the guard rule is not staged in this image (${GUARD_RULE})"
            if [ -e "$dest" ] && cmp -s "$GUARD_RULE" "$dest"; then
                printf 'guard is already on (%s)\n' "$dest"; return 0
            fi
            if [ -e "$dest" ] && ! grep -qF "$GUARD_MARKER" "$dest"; then
                die "${dest} exists and is not ours; leaving it alone"
            fi
            install -D -m 0644 "$GUARD_RULE" "$dest" || die "could not write ${dest}"
            # A new file in /etc gets its label from the directory, but make
            # sure: polkitd cannot read a mislabeled rule.
            if have restorecon; then restorecon "$dest" 2>/dev/null || true; fi
            printf 'guard on: installed %s\n' "$dest"
            printf 'these now ask for the admin password:\n'
            printf '  rpm-ostree install/uninstall, rollback, cleanup\n'
            printf '  flatpak install/uninstall (system; --user is unaffected)\n'
            printf 'updates are not gated. check: pulsar agent guard\n'
            ;;
        *) die "unknown guard command: ${sub} (see: pulsar agent guard --help)" ;;
    esac
}

# ---------------------------------------------------------------------------
# agent, bare -- the one-screen answer to "what does this machine give an
# agent": the guide, the agents installed, and whether guard is on. --json
# is for the agent itself.
# ---------------------------------------------------------------------------
agent_status() {
    local guide=false guard=unknown n b m p d state native rows=""
    [ -r "$AGENTS_MD" ] && guide=true
    [ "$(id -u)" -eq 0 ] || guard=$(guard_state)
    while IFS=$'\t' read -r n b m p _ d; do
        state=""
        if is_our_shim "${AGENT_SHIMS}/${b}"; then
            state=installed
        elif native=$(native_launcher "$b"); then
            state=native
        fi
        [ -z "$state" ] || rows+="${n}"$'\t'"${b}"$'\t'"${state}"$'\n'
    done < <(agent_rows)
    local sbx; sbx=$(setting_resolve sandbox "$(project_root)")
    if [ "${JSON:-0}" = 1 ]; then
        need jq
        printf '%s' "$rows" | jq -R -s --arg g "$AGENTS_MD" --argjson gp "$guide" --arg guard "$guard" \
            --arg sb "${sbx%%$'\t'*}" --arg sbsrc "${sbx#*$'\t'}" '
            {guide: {path: $g, present: $gp},
             agents: [split("\n")[] | select(length > 0) | split("\t")
                      | {name: .[0], command: .[1], install: .[2]}],
             guard: $guard, sandbox: {here: $sb, from: $sbsrc}}'
        return 0
    fi
    if [ "$guide" = true ]; then
        printf 'guide    %s  (pulsar agent guide)\n' "$AGENTS_MD"
    else
        printf 'guide    none in this image\n'
    fi
    if [ -n "$rows" ]; then
        while IFS=$'\t' read -r n b state; do
            [ -n "$n" ] || continue
            printf 'agent    %-9s %s\n' "$n" "$state"
        done <<<"$rows"
    else
        printf 'agents   none installed  (pulsar agent list, pulsar agent add <name>)\n'
    fi
    printf 'sandbox  %s here (%s)  (pulsar agent sandbox)\n' "${sbx%%$'\t'*}" "${sbx#*$'\t'}"
    case "$guard" in
        on)      printf 'guard    on: layering, rollback, cleanup and system Flatpak installs and removals ask for a password\n' ;;
        off)     printf 'guard    off: layering, rollback, cleanup and system Flatpak installs and removals need no password  (sudo pulsar agent guard on)\n' ;;
        partial) printf 'guard    partial  (see: pulsar agent guard)\n' ;;
        *)       printf 'guard    unknown  (run pulsar agent guard as yourself)\n' ;;
    esac
}

agent_help() {
    cat <<EOF
usage: pulsar agent                  the guide, installed agents, guard state
       pulsar agent guide            print the guide a coding agent should read first
       pulsar agent list             the supported agents, and which are installed
       pulsar agent add <name>       install one coding agent CLI
       pulsar agent remove <name>    remove its command and package
       pulsar agent default [name]   the agent 'ask' starts (default: the only one installed)
       pulsar agent ask [--crash <pid|latest>] [--with <name>] [question]
                                     start it on a redacted report of this machine,
                                     and a crash if you name one
       pulsar agent sandbox [on|off] [--here]
                                     run agents in a container that sees only the
                                     project and the paths you allow; push goes
                                     through a gate that keeps your credentials.
                                     --here: this project only
       pulsar agent sandbox push on|off|branches [--here]
                                     what the gate lets through; branches: every
                                     branch but the remote's default. Never
                                     force-push, deletes or tags
       pulsar agent sandbox allow <path> [--rw] [--here] | disallow <path>
                                     let one more file or folder in (read-only
                                     unless --rw): a tool the agent's hooks run
       pulsar agent sandbox list|repin
                                     per-project settings; re-pin this project's remotes
       pulsar agent sandbox wrap on|off
                                     whether typing an agent's name in bash goes
                                     through pulsar agent run (default on)
       pulsar agent run <name> [--sandbox|--no-sandbox] [-- args]
                                     start an agent (its command does this for you)
       pulsar agent run <name> --tmux <session> [--new] [--dir <path> | <path>] [--worktree]
                    [--title <text>] [--prompt <text>] [-- args]
                                     attach to that tmux session, or start the agent
                                     in it. One server for agents (-L pulsar-agents),
                                     on the host; a session that died comes back on
                                     its own conversation (claude, opencode, agy; codex
                                     its last in the folder). --new: a fresh one.
                                     --prompt: a new session's first message.
                                     When it waits for you in a session you are not
                                     looking at, a notification offers to open it.
                                     --worktree: its own git worktree and branch,
                                     <repo>/.worktrees/<session>
       pulsar agent read <session> [--lines N]
                                     what that session's screen shows, scrollback
                                     included (default 80 lines)
       pulsar agent send <session> [--from <session>] [--reply-to <id>] [--now] <text>
                                     type a message into its prompt at the end of
                                     its turn, labelled; logged and capped
       pulsar agent inbox [<session>] [--unread] [--keep]
                                     messages to and from a session (default: this
                                     one), with ids to answer (send --reply-to)
       pulsar agent messages [on|off] [--cap N]
                                     whether sessions may message each other, and
                                     how many from one to another in 10 minutes
       pulsar agent whoami           the session this runs in
       pulsar agent settings         the default agent, sandbox, push and messages
       pulsar agent disk [--delete <path>]
                                     free space on /var, and the big things agents
                                     leave in /var/tmp, ~/.cache and scratch folders
       pulsar agent attach [<session>]
                                     back onto a session, or the running one you
                                     were on last; an ended one starts again with
                                     its agent, folder, conversation and sandbox
       pulsar agent undo <session> [--list | --to <n> | --redo] [--yes | --dry-run]
                                     put the project's files back as they were when
                                     the session started (its first start or --new;
                                     restarts do not move it). Git repositories; files
                                     git ignores stay as they are, commits stay; not
                                     while a session runs in that checkout
       pulsar agent undo <session> --file <path> [--uncommitted] [--yes | --dry-run]
                                     one file back as it was when the session started
                                     (or at the last commit); also while it runs.
                                     --redo takes it back
       pulsar agent undo <session> --list --json
                                     its snapshots, newest first: n (for --to),
                                     time, subject, start (where undo goes)
       pulsar agent diff <session> [--uncommitted] [--stat | --files --json] [-- <path>]
                                     what changed in its checkout since it started
                                     (untracked files too); works while it runs.
                                     --uncommitted: since the last commit instead
       pulsar agent usage <session> [--json]
                                     its model, how full the context is, and tokens
                                     read and written (Claude Code; no prices)
       pulsar agent sessions [--kill <name> | --forget <name>] [--json]
                                     the tmux sessions; --kill ends one (attach
                                     brings it back). --forget deletes an ended
                                     one's record and undo snapshots, and its
                                     worktree if git removes it without --force.
                                     The agent's own history is not touched
       pulsar agent sessions --archive|--unarchive <name> | --title <name> <text>
                                     archive: done with it (ends it if running; its
                                     files, worktree and snapshots stay; a start
                                     unarchives). title: what the Agents app shows
       pulsar agent sessions --tidy [--days <n>] [--json]
                                     forget sessions archived n days ago or more
                                     (default 7); a worktree with work in it stays,
                                     and every branch
       pulsar agent model [on|off] [--model <hf-repo[:quant]>] [--at-login] [--purge]
                                     a local model server (llama.cpp, rootless podman,
                                     127.0.0.1 only) for agents with no cloud account.
                                     --at-login: start it at each login
       pulsar agent guard [on|off]   make layering, rollback, cleanup and system
                                     Flatpak installs and removals ask for a
                                     password (on and off need root)

Agents: $(agent_names). None is installed by default.
gemini and aider still install, run and come off, but are no longer
suggested: Gemini CLI no longer signs in free or Google AI Pro/Ultra
accounts (agy does), and aider has had no release since February 2026.

agent add installs an agent with npm in the '${AGENT_BOX}' toolbox
(created on first use), or for agy from Google's release manifest, into
${AGENT_PREFIX}, and puts its command in
${AGENT_SHIMS}. The command runs it in that toolbox, or in a podman
sandbox where the sandbox is on (pulsar agent sandbox). An agent its own
installer put on the host is left as it is, and runs on the host when the
sandbox is off.
Where the agent reads a global instructions file Pulsar can own, it links
${AGENTS_MD} there, and never overwrites a file that exists.
EOF
}

cmd_agent() {
    local sub=${1:-}
    shift || true
    case "$sub" in
        "") agent_status ;;
        -h|--help|help) agent_help ;;
        guide)
            no_args "agent guide" "$@"
            no_json "agent guide"
            [ -r "$AGENTS_MD" ] || die "no agent guide at ${AGENTS_MD} (this image predates it)"
            cat "$AGENTS_MD"
            ;;
        list)
            no_args "agent list" "$@"
            need_user "agent list"
            agent_list
            ;;
        add|remove)
            no_json "agent ${sub}"
            [ $# -eq 1 ] || die "usage: pulsar agent ${sub} <name>  (one of: $(agent_names))"
            need_user "agent ${sub}"
            agent_row "$1" || die "unknown agent: $1 (known: $(agent_names))"
            if [ "$sub" = add ]; then agent_install; else agent_remove; fi
            ;;
        guard) agent_guard "$@" ;;
        sandbox)
            no_json "agent sandbox"
            need_user "agent sandbox"
            agent_sandbox "$@" ;;
        run)
            no_json "agent run"
            need_user "agent run"
            agent_run "$@" ;;
        undo)
            need_user "agent undo"
            agent_undo "$@" ;;
        diff)
            need_user "agent diff"
            agent_diff "$@" ;;
        notify)
            need_user "agent notify"
            agent_notify "$@" ;;
        usage)
            need_user "agent usage"
            agent_usage "$@" ;;
        disk)
            need_user "agent disk"
            agent_disk "$@" ;;
        read)
            need_user "agent read"
            agent_read "$@" ;;
        send)
            no_json "agent send"
            need_user "agent send"
            agent_send "$@" ;;
        whoami)
            need_user "agent whoami"
            agent_whoami "$@" ;;
        hooks)
            # the agents' server's hooks, as `agent run` sets them (tests, repair)
            need_user "agent hooks"
            { have tmux && atmux has-session 2>/dev/null; } || die "no agents' tmux server is running"
            agent_tmux_hooks "$(realpath "$SELF")" ;;
        sizes)
            # tmux's hooks. A session's window follows tmux's default (the
            # latest client's size) unless the Agents app has a view on it:
            # then the smallest client's, so the app and a terminal (or the
            # app on two machines) stop resizing it back and forth, and each
            # sees the whole agent. The app marks its hidden terminals
            # ignore-size, so they don't count.
            # One run at a time, each reading the sessions as they are once it
            # has the lock: several hooks fire for one attach, and a run that
            # read them before a view went must not finish after the one
            # that saw it gone.
            have tmux || return 0
            if [ "${1:-}" = --view ]; then
                # --view <tag> shown|hidden: another machine's app showed or
                # hid its terminal on a view here (its tag, from atmux_view);
                # a hidden one stops counting toward the window's size
                local tag=${2:-} flag
                case "${3:-}" in shown) flag='!ignore-size' ;; hidden) flag=ignore-size ;; *) tag="" ;; esac
                case "$tag" in ''|*[!A-Za-z0-9_-]*) die "usage: pulsar agent sizes [--view <tag> shown|hidden]" ;; esac
                local sess tty
                while IFS=$'\t' read -r sess tty; do
                    [ "$(atmux show-options -qv -t "=${sess}:" @pulsar-view 2>/dev/null)" = "$tag" ] || continue
                    atmux refresh-client -t "$tty" -f "$flag" 2>/dev/null || true
                done < <(atmux list-clients -F $'#{session_name}\t#{client_tty}' 2>/dev/null)
                return 0
            fi
            mkdir -p "$AGENT_SESSIONS"
            local lockfd all base w
            exec {lockfd}>"${AGENT_SESSIONS}/.sizes.lock"
            flock -w 10 "$lockfd" || return 0
            all=$(atmux list-sessions -F '#{session_name}' 2>/dev/null) || return 0
            while IFS= read -r base; do
                case "$base" in ''|*~*) continue ;; esac
                local opt=(-wu) val=()
                if awk -v b="${base}~" 'index($0, b) == 1 { f = 1 } END { exit !f }' <<<"$all"; then
                    opt=(-w) val=(smallest)
                fi
                # every window of it, should an agent's session have several
                while IFS= read -r w; do
                    [ -z "$w" ] || atmux set-option "${opt[@]}" -t "$w" window-size "${val[@]}" 2>/dev/null || true
                done < <(atmux list-windows -t "=${base}:" -F '#{window_id}' 2>/dev/null)
            done <<<"$all" ;;
        seen)
            # clears a session's waiting by hand; an older Pulsar's tmux hooks call it
            local n=${1:-}
            case "$n" in ''|-*|*[!A-Za-z0-9_-]*) die "usage: pulsar agent seen <session> (tmux runs this)" ;; esac
            ! have tmux || atmux set-option -u -t "=${n}:" @pulsar-alert 2>/dev/null || true ;;
        messages)
            need_user "agent messages"
            agent_messages "$@" ;;
        inbox)
            need_user "agent inbox"
            agent_inbox "$@" ;;
        settings)
            need_user "agent settings"
            agent_settings "$@" ;;
        sessions)
            need_user "agent sessions"
            agent_sessions "$@" ;;
        attach)
            no_json "agent attach"
            need_user "agent attach"
            agent_attach "$@" ;;
        model)
            no_json "agent model"
            need_user "agent model"
            agent_model "$@" ;;
        ask)
            no_json "agent ask"
            need_user "agent ask"
            agent_ask "$@" ;;
        default)
            no_json "agent default"
            need_user "agent default"
            agent_default "$@" ;;
        *) die "unknown agent command: ${sub} (see: pulsar agent --help)" ;;
    esac
}

# ---------------------------------------------------------------------------
# agent default / agent ask -- start the user's agent on a question about
# this machine, with the report (and a crash) already in front of it.
# ---------------------------------------------------------------------------
AGENT_DEFAULT_FILE=${PULSAR_AGENT_DEFAULT:-${XDG_CONFIG_HOME:-$HOME/.config}/pulsar/agent}

# Prints the path that runs agent $1 here, or fails if it is not installed.
agent_command() {
    agent_row "$1" || return 1
    if is_our_shim "${AGENT_SHIMS}/${A_BIN}"; then
        printf '%s\n' "${AGENT_SHIMS}/${A_BIN}"
    else
        native_launcher "$A_BIN"
    fi
}

# The one set with `agent default`, else the only agent installed.
agent_default_name() {
    local n
    if [ -r "$AGENT_DEFAULT_FILE" ]; then
        n=$(head -1 "$AGENT_DEFAULT_FILE")
        if agent_command "$n" >/dev/null; then printf '%s\n' "$n"; return 0; fi
    fi
    local -a found=()
    while IFS=$'\t' read -r n _; do
        agent_command "$n" >/dev/null && found+=("$n")
    done < <(agent_rows)
    [ ${#found[@]} -eq 1 ] || return 1
    printf '%s\n' "${found[0]}"
}

agent_default() {
    [ $# -le 1 ] || die "usage: pulsar agent default [name]"
    if [ $# -eq 0 ]; then
        local n
        if n=$(agent_default_name); then
            printf '%s\n' "$n"
        else
            die "no default agent: pulsar agent default <name> (or install exactly one)"
        fi
        return 0
    fi
    agent_row "$1" || die "unknown agent: $1 (known: $(agent_names))"
    agent_command "$1" >/dev/null || die "$1 is not installed (pulsar agent add $1)"
    mkdir -p "$(dirname "$AGENT_DEFAULT_FILE")"
    printf '%s\n' "$1" > "$AGENT_DEFAULT_FILE"
    printf 'default agent: %s\n' "$1"
}

agent_ask() {
    local crash="" with="" a
    local -a q=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --crash) [ $# -ge 2 ] || die "--crash wants a PID or 'latest'"; crash=$2; shift ;;
            --crash=*) crash=${1#--crash=} ;;
            --with) [ $# -ge 2 ] || die "--with wants an agent name"; with=$2; shift ;;
            --with=*) with=${1#--with=} ;;
            -h|--help) agent_help; return 0 ;;
            -*) die "unknown option: $1 (see: pulsar agent --help)" ;;
            *) q+=("$1") ;;
        esac
        shift
    done
    local name cmd
    name=${with:-$(agent_default_name)} \
        || die "no agent chosen: pulsar agent default <name>, or --with <name> (installed: $(agent_installed_names))"
    cmd=$(agent_command "$name") || die "${name} is not installed (pulsar agent add ${name})"
    agent_row "$name"
    if [ -n "$crash" ]; then crash=$(crash_resolve "$crash") || exit 1; fi

    # $XDG_RUNTIME_DIR: private to this user, gone at logout, and shared with
    # the agents toolbox, so an agent in the box reads the same file.
    local dir="${XDG_RUNTIME_DIR:-/tmp}/pulsar" file
    ( umask 077; mkdir -p "$dir" ) || die "could not create ${dir}"
    file="${dir}/report-$(date +%Y%m%dT%H%M%S).json"
    printf 'writing a redacted report to %s\n' "$file" >&2
    ( umask 077; "$SELF" report ${crash:+--crash "$crash"} > "$file" ) \
        || die "could not write the report"

    local prompt exe
    prompt="Read ${file}: a redacted diagnosis report from this Pulsar machine. Run \`pulsar agent guide\` first if you have not read how this system works."
    if [ -n "$crash" ]; then
        exe=$(jq -r '.crash.executable // "a program"' "$file" 2>/dev/null) || exe="a program"
        prompt+=" Its crash section is ${exe} crashing (PID ${crash}): the signal, the crashing thread's stack trace and that process's log lines."
        [ ${#q[@]} -gt 0 ] || prompt+=" Explain what crashed and why, say whether it looks like a known bug (search for it), tell me what I can do about it now, and if it is a bug, help me report it upstream."
    elif [ ${#q[@]} -eq 0 ]; then
        prompt+=" Tell me what, if anything, looks wrong, most important first."
    fi
    [ ${#q[@]} -eq 0 ] || prompt+=" ${q[*]}"
    prompt+=" Do not change the system without asking me first."

    case "$A_PROMPT" in
        arg)     exec "$cmd" "$prompt" ;;
        i)       exec "$cmd" -i "$prompt" ;;
        # opencode sends --prompt once a model is ready; with none set up,
        # it waits in the box
        prompt)  exec "$cmd" --prompt "$prompt" ;;
        # aider has no interactive first message: it gets the report as a
        # read-only file, and the question to paste
        read)    printf 'paste this into aider:\n\n%s\n\n' "$prompt" >&2; exec "$cmd" --read "$file" ;;
        *)       die "internal error: no prompt style for ${name}" ;;
    esac
}

agent_installed_names() {
    local n out=""
    while IFS=$'\t' read -r n _; do
        agent_command "$n" >/dev/null && out+="${out:+ }${n}"
    done < <(agent_rows)
    printf '%s\n' "${out:-none}"
}
