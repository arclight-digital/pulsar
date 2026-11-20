# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): the basics every part uses: output, die/need, quoting, sizes.

# Under pipefail, `printf '%s\n' "$x" | grep -q ...` can answer "no" when the
# answer is yes: grep -q exits on its first match, bash's printf writes a line
# at a time, and a printf still writing dies of SIGPIPE, which pipefail
# reports. So text already in a variable is searched with a here-string,
# `grep -q ... <<<"$x"`, which bash writes in full before grep starts.

# A systemd system service, a timer or cron starts this with no HOME at all,
# and under set -u the first path built from it kills the script before
# doctor, status or manifest -- none of which need a home -- print a word.
# The account's own home from passwd, as a login would set it; / if even that
# is missing, so nothing written under it lands in the working directory.
if [ -z "${HOME:-}" ]; then
    HOME=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)
    export HOME=${HOME:-/}
fi

# the release (YY.M.N) the image carries; a checkout has none installed
VERSION=$(cat "${PULSAR_RELEASE_FILE:-/usr/share/pulsar/release}" 2>/dev/null || true)
VERSION=${VERSION:-dev}
MANIFEST=${PULSAR_MANIFEST:-/usr/share/pulsar/manifest.json}
SBOM_TOOL=${PULSAR_SBOM_TOOL:-/usr/libexec/pulsar/rpm-sbom.sh}

# ---------------------------------------------------------------------------
# Output. Colour only when stdout is a terminal, so piping into a file or a
# log does not embed escape codes.
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_KEY=$'\033[36m'
else
    C_RESET=""; C_DIM=""; C_BOLD=""; C_OK=""; C_WARN=""; C_FAIL=""; C_KEY=""
fi

die() { printf '%spulsar:%s %s\n' "$C_FAIL" "$C_RESET" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    die "'$1' needs root. Run: sudo pulsar $1"
}

# The mirror image, for setup recipes: they write to $HOME and talk to the
# user session bus, and under sudo both silently target root's. The failure
# that surfaces otherwise is systemd's "Failed to connect to bus", which
# points nowhere near the actual mistake.
need_user() {
    [ "$(id -u)" -ne 0 ] && return 0
    die "'$1' configures your session, so run it without sudo"
}

need() { have "$1" || die "required tool not found: $1"; }

# `--json` is accepted anywhere on the line. A command (or subcommand) that has
# no JSON output calls this, so a script that asked for JSON gets an error, not
# prose it will fail to parse -- or, for `update`, a real upgrade.
no_json() { [ "${JSON:-0}" = 0 ] || die "'$1' has no --json output"; }

# Commands that take no arguments say so, instead of silently ignoring what
# they were given: `pulsar doctor tomorrow` should not run doctor today.
no_args() {
    local c=$1; shift
    case "${1:-}" in -h|--help) usage_for "$c"; exit 0 ;; esac
    [ $# -eq 0 ] || die "'${c}' takes no arguments (got: $*)"
}

# Reads a top-level string out of the baked manifest. Absent manifest is not
# fatal: a system rebased from an older image, or a hand-built one, still gets
# a working doctor and status.
mf() {
    # if-then, not `A && B || C`: in that form C also runs when A succeeds and
    # B fails, which is the same shape as the fallback bug that made the
    # greenboot check report health it could not see.
    [ -r "$MANIFEST" ] || return 0
    jq -r --arg k "$1" '.[$k] // empty' "$MANIFEST" 2>/dev/null || true
}

# Single-quoted for sh, whatever the path holds. The shim is a file other
# shells will parse long after this one has exited.
sq() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }

# One word for tmux's command parser: single-quoted, and a ' inside as "'".
tq() { local s=${1//\'/\'\"\'\"\'}; printf "'%s'" "$s"; }

# 1536 -> 1.5 KB, 43459411968 -> 43 GB (decimal, as df -H and Files say)
human_bytes() {
    awk -v b="${1:-0}" 'BEGIN { split("B KB MB GB TB", u, " "); i = 1
        while (b >= 1000 && i < 5) { b /= 1000; i++ }
        printf (i == 1 || b >= 10) ? "%.0f %s\n" : "%.1f %s\n", b, u[i] }'
}

# 75 -> 1m, 7300 -> 2h 1m, 200000 -> 2d 7h
human_age() {
    local t=$1
    if [ "$t" -lt 3600 ]; then printf '%dm\n' $(( t / 60 ))
    elif [ "$t" -lt 86400 ]; then printf '%dh %dm\n' $(( t / 3600 )) $(( t % 3600 / 60 ))
    else printf '%dd %dh\n' $(( t / 86400 )) $(( t % 86400 / 3600 )); fi
}

# stdin: a count of tokens -> 950, 12k, 273k, 25.1M
human_tokens() {
    awk '{ n = $1 + 0
           if (n < 1000) printf "%d\n", n
           else if (n < 1000000) printf "%dk\n", int(n / 1000 + 0.5)
           else printf "%.1fM\n", n / 1000000 }'
}

# A JSON value from a command, or null when the command fails or prints
# something that is not JSON. One broken source must not cost the other six.
json_or_null() {
    local out
    out=$("$@" 2>/dev/null) || true
    if [ -n "$out" ] && printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$out"
    else
        printf 'null'
    fi
}
