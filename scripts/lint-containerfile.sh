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

# ---------------------------------------------------------------------------
# Invariants that must hold at EVERY site, not just the one a traceback named.
#
# This exists because of a specific miss: dracut is invoked twice in this repo
# -- once in Containerfile, once again in Containerfile.nvidia because the
# nvidia modprobe options live in the initramfs -- and a fix for the first one
# shipped alone. The vanilla image went green and the nvidia image failed the
# same way an hour later.
#
# The invariant: podman mounts a container rootfs with a single mount-wide
# context=, so setxattr(security.selinux) answers EOPNOTSUPP, and dracut's
# copy (dracut-init.sh gates it on DRACUT_NO_XATTR) exits 1 and gets logged as
# dracut[E]: FAILED. Any dracut run in a container build needs the guard, so
# assert it here rather than relying on whoever adds the third one knowing.
# ---------------------------------------------------------------------------
for file in "$@"; do
    [ -f "$file" ] || continue
    while IFS= read -r line; do
        case "$line" in
            *DRACUT_NO_XATTR*dracut\ *) ;;
            *dracut\ -*|*dracut\ --*)
                echo "FAIL ${file}: a dracut invocation without DRACUT_NO_XATTR=1:" >&2
                printf '      %s\n' "$(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-120)" >&2
                echo "      In a container the rootfs is mounted with one mount-wide SELinux" >&2
                echo "      context, so copying security.selinux fails EOPNOTSUPP and dracut" >&2
                echo "      logs dracut[E]: FAILED and exits 0 anyway. See Containerfile." >&2
                status=1
                ;;
        esac
    done < "$file"
done

exit "$status"
