#!/usr/bin/env bash
# Syntax-check the shell inside every RUN instruction of a Containerfile.
#
# A Containerfile's line continuations are stripped by the image builder's
# parser, which knows nothing about shell quoting. So a RUN whose command
# spans lines inside a quoted string ends at the first line without a trailing
# backslash, and the shell receives a fragment with an unterminated quote:
#
#     RUN jq -n '{a:1,          <- instruction ends here
#         b:2}' > out.json      <- never reaches the shell
#
# That is not visible by reading the file -- the block looks well-formed --
# and it costs a full image build to discover. This joins continuations the
# same way the builder does and hands each RUN body to `bash -n`, which is
# a second rather than nine minutes.
#
# Usage: lint-containerfile.sh Containerfile [Containerfile.nvidia ...]
set -euo pipefail

status=0
errfile=$(mktemp)
trap 'rm -f "$errfile"' EXIT

for file in "$@"; do
    [ -r "$file" ] || { echo "lint-containerfile: cannot read $file" >&2; exit 2; }

    # Join continuations, tracking the line the instruction started on so a
    # failure points at something you can actually navigate to.
    acc=""
    start=0
    lineno=0
    checked=0

    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))

        # Comment lines are dropped by the builder's parser even in the middle
        # of a continued instruction, so drop them here too.
        case "$line" in
            '#'*) [ -n "$acc" ] && continue ;;
        esac

        if [ -z "$acc" ]; then
            start=$lineno
        fi

        if [ "${line%\\}" != "$line" ]; then
            acc="${acc}${line%\\}"
            continue
        fi
        acc="${acc}${line}"

        # Complete instruction in $acc. Only RUN carries shell.
        case "$acc" in
            [Rr][Uu][Nn]\ *|[Rr][Uu][Nn]$'\t'*)
                body="${acc#[Rr][Uu][Nn]}"
                # Exec form is a JSON array, not shell -- do not lint it.
                case "$(printf '%s' "$body" | sed 's/^[[:space:]]*//')" in
                    '["'*) ;;
                    *)
                        if ! printf '%s\n' "$body" | bash -n 2>"$errfile"; then
                            echo "FAIL ${file}:${start}: RUN body is not valid shell" >&2
                            sed 's/^/      /' "$errfile" >&2
                            printf '      %s\n' "$(printf '%s' "$body" | cut -c1-160)" >&2
                            status=1
                        fi
                        checked=$((checked + 1))
                        ;;
                esac
                ;;
        esac
        acc=""
    done < "$file"

    if [ -n "$acc" ]; then
        echo "FAIL ${file}:${start}: file ends with a dangling line continuation" >&2
        status=1
    fi

    echo "${file}: ${checked} RUN instruction(s) checked"
done

exit "$status"
