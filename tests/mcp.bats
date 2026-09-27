#!/usr/bin/env bats
# pulsar-mcp: the MCP protocol it speaks, and that each tool is the CLI's
# own --json answer. The CLI is stubbed to record what it was asked.

setup() {
    MCP="${BATS_TEST_DIRNAME}/../scripts/pulsar-mcp"
    export PULSAR_CLI="${BATS_TEST_TMPDIR}/pulsar"
    export CLI_LOG="${BATS_TEST_TMPDIR}/cli.log"
    export PULSAR_AGENTS_MD="${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar/AGENTS.md"
    cat > "$PULSAR_CLI" <<'SH'
#!/bin/sh
echo "$*" >> "$CLI_LOG"
case "$*" in
    *"update --check"*) echo '{"status":"available"}'; exit 10 ;;
    *doctor*) echo '{"checks":[],"ok":false}'; exit 1 ;;
    *) echo '{"ok":true}' ;;
esac
SH
    chmod +x "$PULSAR_CLI"
}

# send JSON-RPC lines, get the replies back one per line
rpc() { printf '%s\n' "$@" | python3 "$MCP"; }
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'

@test "initialize names the server and keeps a protocol version it knows" {
    run rpc "$init"
    echo "$output" | jq -e '.result.serverInfo.name == "pulsar" and .result.protocolVersion == "2025-06-18" and .result.capabilities.tools'
    run rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}'
    echo "$output" | jq -e '.result.protocolVersion == "2025-06-18"'
}

@test "notifications get no reply, and an unknown method is method-not-found" {
    run rpc '{"jsonrpc":"2.0","method":"notifications/initialized"}' '{"jsonrpc":"2.0","id":7,"method":"nope"}'
    [ "$(echo "$output" | grep -c .)" -eq 1 ]
    echo "$output" | jq -e '.id == 7 and .error.code == -32601'
}

@test "the tools are read-only except theme_set, and none of them is a root command" {
    run rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    echo "$output" | jq -e '[.result.tools[] | select(.annotations.readOnlyHint | not) | .name] == ["theme_set"]'
    for n in update rollback checkpoint guard pin pin_on; do
        echo "$output" | jq -e --arg n "$n" '[.result.tools[].name] | index($n) == null'
    done
}

@test "a tool is the CLI's --json answer, and exit codes that are answers are not errors" {
    run rpc '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"doctor","arguments":{"check":"crashes"}}}' \
            '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"update_check","arguments":{}}}'
    echo "$output" | jq -s -e '.[0].result.isError == false and .[1].result.isError == false
        and (.[1].result.content[0].text | fromjson | .status) == "available"'
    grep -qx -- "--json doctor crashes" "$CLI_LOG"
    grep -qx -- "--json update --check" "$CLI_LOG"
}

@test "theme_set passes a slug and no flags it did not mean" {
    run rpc '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"theme_set","arguments":{"theme":"nord","variant":"dark"}}}' \
            '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"theme_set","arguments":{"theme":"--help"}}}'
    grep -qx "theme set nord --no-restart --variant dark" "$CLI_LOG"
    [ "$(grep -c "theme set" "$CLI_LOG")" -eq 1 ]
    echo "$output" | jq -s -e '.[1].result.isError == true'
}

@test "the guide is a resource" {
    run rpc '{"jsonrpc":"2.0","id":8,"method":"resources/read","params":{"uri":"pulsar://guide"}}' \
            '{"jsonrpc":"2.0","id":9,"method":"resources/read","params":{"uri":"pulsar://nope"}}'
    echo "$output" | jq -s -e '(.[0].result.contents[0].text | startswith("# This machine runs Pulsar")) and .[1].error.code == -32602'
}

@test "a line that is not JSON gets a parse error, and the server keeps going" {
    run rpc 'not json' "$init"
    echo "$output" | jq -s -e '.[0].error.code == -32700 and .[1].result.serverInfo.name == "pulsar"'
}
