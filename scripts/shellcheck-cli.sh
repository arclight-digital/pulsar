#!/usr/bin/env bash
# Runs shellcheck on the pulsar CLI as the one program it is.
#
# cli/pulsar reads its parts from cli/lib. shellcheck reports only on the
# files it is given (a file it follows with -x is read for its definitions,
# never checked), and a part checked alone has every other part's globals
# "unassigned" and its own "unused". So the entry and its parts are joined in
# the order the entry reads them, checked as one file, and each finding is
# printed against the file and line it came from.
#
#   scripts/shellcheck-cli.sh [shellcheck options]
#
# Exit status is shellcheck's.
set -euo pipefail
cd "$(dirname "$0")/.."

joined=$(mktemp)
map=$(mktemp)
out=$(mktemp)
trap 'rm -f "$joined" "$map" "$out"' EXIT

# Each `. "${PULSAR_LIB}/<part>.sh"` line in the entry becomes that part's
# text; map holds, for every joined line, "<file> <line>".
awk -v joined="$joined" -v map="$map" '
    function emit(text, file, n) { print text > joined; print file " " n > map }
    {
        if (match($0, /^\. "\$\{PULSAR_LIB\}\/[a-z-]+\.sh"$/)) {
            part = $0; sub(/^\. "\$\{PULSAR_LIB\}\//, "", part); sub(/"$/, "", part)
            f = "cli/lib/" part; n = 0
            while ((getline l < f) > 0) {
                n++
                # a part says what shell it is for when read alone; joined, it is the entry`s
                if (l == "# shellcheck shell=bash") l = ""
                emit(l, f, n)
            }
            close(f)
            next
        }
        emit($0, "cli/pulsar", FNR)
    }' cli/pulsar

rc=0
shellcheck -x --format=gcc "$@" "$joined" > "$out" || rc=$?
awk -v joined="$joined" '
    NR == FNR { file[NR] = $1; line[NR] = $2; next }
    index($0, joined ":") == 1 {
        rest = substr($0, length(joined) + 2)
        n = rest; sub(/:.*/, "", n); rest = substr(rest, length(n) + 2)
        print file[n] ":" line[n] ":" rest
        next
    }
    { print }' "$map" "$out"
exit "$rc"
