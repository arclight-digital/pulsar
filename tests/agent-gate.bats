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
    # the host's own credential: what the gate may use, and the sandbox never sees
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper
    export GIT_CONFIG_VALUE_0='!f() { echo username=x; echo password=tok-host-only; }; f'
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

# --- pull requests: `gh pr create` through the gate -------------------------
#
# A fake GitHub API on localhost records what it is sent. The pinned URL
# looks like GitHub; git fetches it from the local upstream by insteadOf.

fake_github() {
    cat > "$T/api.py" <<'PY'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(sys.argv[2], "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers["Authorization"], "body": body}) + "\n")
        if body["head"] == "dup":
            self.send_response(422); self.end_headers()
            self.wfile.write(json.dumps({"message": "Validation Failed",
                "errors": [{"message": "A pull request already exists"}]}).encode()); return
        self.send_response(201); self.end_headers()
        self.wfile.write(json.dumps({"html_url": "https://github.com/o/r/pull/7", "number": 7}).encode())
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_port))
s.serve_forever()
PY
    python3 "$T/api.py" "$T/port" "$T/api.log" &
    API_PID=$!
    local i=0; while [ ! -s "$T/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    # the gate is restarted with the API address in its environment
    kill "$GATE_PID"; rm -f "$SOCK"
    git -C "$T/mirror.git" config remote.origin.url https://github.com/o/r
    git -C "$T/mirror.git" config "url.$T/upstream.git.insteadOf" https://github.com/o/r
    PULSAR_GATE_GITHUB_API="http://127.0.0.1:$(cat "$T/port")" python3 "$GATE" serve "$SOCK" "$T/mirror.git" 2>"$T/serve.log" &
    GATE_PID=$!
    i=0; while [ ! -S "$SOCK" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}

# gh as the sandbox has it: no credential in its own environment
sgh() { (cd "$T/project" && env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
         python3 "$GATE" gh "$SOCK" "$@"); }

@test "gh pr create opens a pull request as the user, with a token the sandbox never had" {
    fake_github
    commit b
    agit push -q origin main:refs/heads/feature
    run sgh pr create --title "Add b" --body "why" --head feature --draft
    kill "$API_PID"
    [ "$status" -eq 0 ] || fail "$output"
    [ "$output" = "https://github.com/o/r/pull/7" ]
    jq -e '.path == "/repos/o/r/pulls" and .auth == "Bearer tok-host-only"
           and .body == {"title":"Add b","body":"why","head":"feature","base":"main","draft":true}' "$T/api.log"
}

@test "gh pr create refuses a head that is not on the remote, and says to push" {
    fake_github
    git -C "$T/project" switch -qc local-only
    run sgh pr create --title x
    kill "$API_PID"
    [ "$status" -ne 0 ]
    [[ "$output" == *"head branch 'local-only' is not on origin: push it first"* ]]
    [ ! -e "$T/api.log" ]
}

@test "gh pr create passes GitHub's refusal through, and push off means no pull requests" {
    fake_github
    commit b
    agit push -q origin main:refs/heads/dup
    run sgh pr create --title x --head dup
    [[ "$output" == *"GitHub said 422: Validation Failed (A pull request already exists)"* ]]
    git -C "$T/mirror.git" config pulsar.push off
    run sgh pr create --title x --head dup
    kill "$API_PID"
    [[ "$output" == *"so are pull requests"* ]]
}

@test "the sandbox's gh does pr create and nothing else" {
    run sgh pr merge 7
    [ "$status" -ne 0 ]
    [[ "$output" == *"only \`gh pr create\` works"* ]]
    run sgh repo delete o/r --yes
    [ "$status" -ne 0 ]
}

@test "gh pr create on a remote that is not GitHub says so" {
    run sgh pr create --title x --head main
    [ "$status" -ne 0 ]
    [[ "$output" == *"GitHub remotes only"* ]]
}
