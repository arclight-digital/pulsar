#!/usr/bin/env bats
# The push gate, end to end with real git: a sandboxed agent's push goes
# through pulsar-agent-gate to an "upstream" on a local path, and the policy
# holds whatever the agent asks for. Nothing is stubbed.

setup() {
    GATE="${BATS_TEST_DIRNAME}/../scripts/pulsar-agent-gate"
    T="$BATS_TEST_TMPDIR"
    # a socket path has to fit in 108 bytes
    SOCK="/tmp/pgate.$$.${BATS_TEST_NUMBER}.sock"
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    export GIT_CONFIG_GLOBAL=/dev/null
    git init -q --bare -b main "$T/upstream.git"
    git clone -q "$T/upstream.git" "$T/project" 2>/dev/null
    echo a > "$T/project/a"
    git -C "$T/project" add a
    git -C "$T/project" commit -qm a
    git -C "$T/project" push -q origin main
    python3 "$GATE" setup "$T/mirror.git" "$T/project" "python3 $GATE"
    export PULSAR_GATE_PUSHED="$T/pushed"
    python3 "$GATE" serve "$SOCK" "$T/mirror.git" 2>"$T/serve.log" &
    GATE_PID=$!
    local i=0
    while [ ! -S "$SOCK" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    URL="$T/upstream.git"
}

teardown() {
    kill "$GATE_PID" 2>/dev/null || true
    rm -f "$SOCK"
}

# git as the sandbox has it: origin rewritten to the gate, no credentials
agit() {
    git -C "$T/project" -c protocol.ext.allow=always \
        -c "url.ext::python3 ${GATE} connect ${SOCK} %s origin.insteadOf=${URL}" "$@"
}

commit() { echo "$1" >> "$T/project/a"; git -C "$T/project" commit -qam "$1"; }
upstream() { git -C "$T/upstream.git" rev-parse --verify --quiet "$1"; }

@test "a fast-forward push reaches the real remote, as the user" {
    commit b
    run agit push origin main
    [ "$status" -eq 0 ] || fail "$output"
    [ "$(upstream main)" = "$(git -C "$T/project" rev-parse main)" ]
}

@test "a new branch is fine" {
    commit b
    run agit push origin main:refs/heads/feature
    [ "$status" -eq 0 ] || fail "$output"
    [ -n "$(upstream feature)" ]
}

@test "force-push, delete and tags are refused, and the remote is untouched" {
    agit push -q origin main:refs/heads/feature
    local before; before=$(upstream main)
    git -C "$T/project" commit -q --amend -m rewritten
    run agit push -f origin main
    [ "$status" -ne 0 ]
    [[ "$output" == *"force-push is not allowed"* ]]
    [ "$(upstream main)" = "$before" ]
    run agit push origin :feature
    [[ "$output" == *"deleting a branch is not allowed"* ]]
    [ -n "$(upstream feature)" ]
    git -C "$T/project" tag v1
    run agit push origin v1
    [[ "$output" == *"only branches can be pushed"* ]]
    [ -z "$(upstream v1)" ]
}

@test "push = branches keeps the default branch for the user" {
    git -C "$T/mirror.git" config pulsar.push branches
    commit b
    run agit push origin main
    [[ "$output" == *"only allows pushing to other branches"* ]]
    run agit push origin main:refs/heads/work
    [ "$status" -eq 0 ]
    [ -n "$(upstream work)" ]
}

@test "push = off refuses everything, and says how to turn it on" {
    git -C "$T/mirror.git" config pulsar.push off
    commit b
    run agit push origin main:refs/heads/work
    [ "$status" -ne 0 ]
    [[ "$output" == *"pulsar agent sandbox push on"* ]]
}

@test "pull works through the gate, fresh from the real remote" {
    git clone -q "$T/upstream.git" "$T/other" 2>/dev/null
    echo z >> "$T/other/a"; git -C "$T/other" commit -qam z; git -C "$T/other" push -q origin main
    run agit pull -q --ff-only origin main
    [ "$status" -eq 0 ] || fail "$output"
    [ "$(git -C "$T/project" rev-parse main)" = "$(upstream main)" ]
}

@test "only the remotes pinned at setup exist; the project's config cannot add one" {
    git -C "$T/project" remote add evil "$T/evil.git"
    run git -C "$T/project" -c protocol.ext.allow=always push "ext::python3 ${GATE} connect ${SOCK} %s evil" main
    [ "$status" -ne 0 ]
    [[ "$output" == *"no pinned remote 'evil'"* ]]
}

@test "the mirror keeps its pinned URL when the project's origin moves" {
    git init -q --bare -b main "$T/evil.git"
    git -C "$T/project" remote set-url origin "$T/evil.git"
    [ "$(git -C "$T/mirror.git" config remote.origin.url)" = "$T/upstream.git" ]
    python3 "$GATE" setup "$T/mirror.git" "$T/project" "python3 $GATE"
    [ "$(git -C "$T/mirror.git" config remote.origin.url)" = "$T/upstream.git" ]
}

@test "the gate notes each branch that reached the remote, and only those" {
    commit b
    agit push -q origin main:refs/heads/feature
    git -C "$T/project" commit -q --amend -m rewritten
    agit push -f origin main:refs/heads/feature 2>/dev/null || true
    [ "$(cat "$T/pushed")" = "$(printf 'origin\trefs/heads/feature')" ]
}
