# pulsar-agents.sh -- typing a coding agent's name goes through Pulsar.
#
# `claude`, `codex`, `gemini`, `opencode` and `aider` become shell functions
# that run `pulsar agent run <name>`. That starts the agent sandboxed where
# the sandbox is on (pulsar agent sandbox), and otherwise exactly as it is
# installed -- a vendor's own install included, which a PATH entry could not
# reach: ~/.bashrc puts ~/.local/bin, where those installers write, first.
# A function is looked up before PATH, and nothing of the install is touched,
# so the vendor's updater and this never fight.
#
# Interactive bash only. A script that runs the agent is unaffected, and so
# is `command claude`. Off: `pulsar agent sandbox wrap off`.
if [ -n "${BASH_VERSION:-}" ] && [[ $- == *i* ]] && [ -z "${PULSAR_SANDBOX:-}" ] \
   && [ -x "${PULSAR_CLI_PATH:-/usr/bin/pulsar}" ] \
   && ! grep -qsx 'wrap = off' "${XDG_CONFIG_HOME:-$HOME/.config}/pulsar/agent.conf"; then
    for __pulsar_agent in claude codex gemini opencode aider; do
        eval "${__pulsar_agent}() { \"\${PULSAR_CLI_PATH:-/usr/bin/pulsar}\" agent run ${__pulsar_agent} -- \"\$@\"; }"
    done
    unset __pulsar_agent
fi
