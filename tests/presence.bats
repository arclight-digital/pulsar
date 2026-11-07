#!/usr/bin/env bats
# pulsar-presence: the game being played, in Flatpak Discord. /proc, Discord's
# list of known games and Discord itself are fixtures: a fake /proc tree, a
# file:// list, and a fake Discord on a Unix socket that records what it is
# sent. That real Discord shows "Playing <game>" for these messages was checked
# by hand against Flatpak Discord with State of Decay 2 running (see the
# commit).

setup() {
    REPO="${BATS_TEST_DIRNAME}/.."
    PRESENCE="${REPO}/scripts/pulsar-presence"
    export HOME="${BATS_TEST_TMPDIR}/home" XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/home/.cache"
    export XDG_RUNTIME_DIR="${BATS_TEST_TMPDIR}/run"
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
    export PULSAR_PRESENCE_PROC="${BATS_TEST_TMPDIR}/proc"
    mkdir -p "$PULSAR_PRESENCE_PROC"
    printf 'cpu  1 2 3\nbtime 1700000000\n' > "${PULSAR_PRESENCE_PROC}/stat"
    DB="${BATS_TEST_TMPDIR}/detectable.json"
    cat > "$DB" <<'EOF'
[
 {"id": "100", "name": "State of Decay 2", "executables": [],
  "third_party_skus": [{"distributor": "epic", "id": "abc"}, {"distributor": "steam", "id": "495420"}]},
 {"id": "200", "name": "Wine Game", "executables": [{"os": "win32", "name": "bin/wine-game.exe", "is_launcher": false}]},
 {"id": "300", "name": "Strip Game", "executables": [{"os": "win32", "name": "strip.exe"}]},
 {"id": "400", "name": "A Launcher", "executables": [{"os": "win32", "name": "launcher.exe", "is_launcher": true}],
  "third_party_skus": [{"distributor": "steam", "id": "7"}]},
 {"id": "500", "name": "Mac Only", "executables": [{"os": "darwin", "name": "mac-game"}]},
 {"id": "600", "name": "Native Game", "executables": [{"os": "linux", "name": "native-game.x86_64"}],
  "third_party_skus": [{"distributor": "steam", "id": "888"}]},
 {"id": "700", "name": "Exact", "executables": [{"os": "win32", "name": ">exact.exe"}]}
]
EOF
    export PULSAR_PRESENCE_DB_URL="file://${DB}"
    export PULSAR_PRESENCE_INDEX="${XDG_CACHE_HOME}/pulsar/presence/index.json"
}

fail() { echo "$*" >&2; return 1; }

# proc PID START_TICKS ARGV...  (one process; its stat names its start time)
proc() {
    local pid=$1 ticks=$2; shift 2
    mkdir -p "${PULSAR_PRESENCE_PROC}/${pid}"
    printf '%s\0' "$@" > "${PULSAR_PRESENCE_PROC}/${pid}/cmdline"
    # field 22 is the start time; the name has a space and a ")" in it
    printf '%s (a b) c) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 %s 20 21\n' "$pid" "$ticks" \
        > "${PULSAR_PRESENCE_PROC}/${pid}/stat"
}

py() {
    local code=$1; shift
    python3 -c '
import importlib.machinery, importlib.util, os, sys
loader = importlib.machinery.SourceFileLoader("pp", sys.argv[1])
spec = importlib.util.spec_from_loader("pp", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
sys.stderr = sys.stdout
exec(sys.argv[2])' "$PRESENCE" "$code" "$@"
}

# A fake Discord: answers the handshake with READY, SET_ACTIVITY with what it
# was sent, and writes each frame it gets to $DISCORD_LOG, one JSON a line.
start_discord() {
    SOCK="${XDG_RUNTIME_DIR}/app/com.discordapp.Discord/discord-ipc-0"
    mkdir -p "$(dirname "$SOCK")"
    export DISCORD_LOG="${BATS_TEST_TMPDIR}/discord.log"
    : > "$DISCORD_LOG"
    python3 - "$SOCK" "$DISCORD_LOG" "${1:-ok}" <<'EOF' &
import json, os, socket, struct, sys, threading
path, log, mode = sys.argv[1:]
srv = socket.socket(socket.AF_UNIX); srv.bind(path); srv.listen(8)
def send(c, op, obj):
    b = json.dumps(obj).encode(); c.sendall(struct.pack("<II", op, len(b)) + b)
def serve(c):
    while True:
        head = c.recv(8)
        if len(head) < 8:
            with open(log, "a") as f: f.write("CLOSED\n")
            return
        op, n = struct.unpack("<II", head); body = b""
        while len(body) < n: body += c.recv(n - len(body))
        msg = json.loads(body)
        with open(log, "a") as f: f.write(json.dumps({"op": op, **msg}, sort_keys=True) + "\n")
        if op == 0:
            send(c, 1, {"cmd": "DISPATCH", "evt": "READY", "data": {"v": 1}})
        elif mode == "refuse":
            send(c, 1, {"cmd": "SET_ACTIVITY", "evt": "ERROR", "data": {"code": 4000, "message": "no"}, "nonce": msg["nonce"]})
        else:
            send(c, 1, {"cmd": "SET_ACTIVITY", "evt": None, "data": msg["args"]["activity"], "nonce": msg["nonce"]})
while True:
    c, _ = srv.accept(); threading.Thread(target=serve, args=(c,), daemon=True).start()
EOF
    DISCORD_PID=$!
    for _ in $(seq 50); do [ -S "$SOCK" ] && return 0; sleep 0.1; done
    fail "the fake Discord never listened"
}

teardown() {
    [ -n "${DISCORD_PID:-}" ] && kill "$DISCORD_PID" 2>/dev/null || true
}

@test "presence: the index keeps names, Steam ids and game executables, not launchers' or Mac ones" {
    run py 'import json; idx = m.build_index(json.load(open(sys.argv[3])))
print(sorted(idx["steam"].items()))
print(sorted(idx["exes"].items()))
print(idx["names"]["100"], len(idx["names"]))' "$DB"
    [ "$status" -eq 0 ] || fail "$output"
    # a launcher's program is left out, but its Steam id is still that game's
    [ "${lines[0]}" = "[('495420', '100'), ('7', '400'), ('888', '600')]" ]
    [ "${lines[1]}" = "[('>exact.exe', '700'), ('bin/wine-game.exe', '200'), ('native-game.x86_64', '600'), ('strip.exe', '300')]" ]
    [ "${lines[2]}" = "State of Decay 2 7" ]
}

@test "presence: program paths match the way Discord matches them" {
    run py 'exes = {"bin/wine-game.exe": "200", "strip.exe": "300", "native-game.x86_64": "600", ">exact.exe": "700"}
for p in (r"S:\steamapps\common\X\Bin\Wine-Game.exe",   # a Wine path, any case, by its end
          r"Z:\games\other\wine-game.exe",               # the folder in the entry has to match too
          "/home/u/Games/Strip64.exe",                   # "64" dropped, as Discord drops it
          "/home/u/Games/native-game.x86_64",
          r"C:\windows\system32\strip.exe",              # never Wine'"'"'s own programs
          r"C:\x\exact.exe", "/opt/a/notexact.exe", "/usr/bin/bash"):
    print(m.match_exe(p, exes))'
    [ "$status" -eq 0 ] || fail "$output"
    [ "$output" = "200
None
300
600
None
700
None
None" ]
}

@test "presence: Steam games by app id, others by path, one each, only this user's" {
    proc 10 100 /steam/ubuntu12_32/reaper SteamLaunch AppId=495420 -- /x/proton waitforexitandrun 'S:\x\StateOfDecay2.exe'
    proc 11 100 'S:\x\StateOfDecay2.exe' -steamlaunch
    proc 12 100 'S:\steamapps\common\W\bin\wine-game.exe'
    proc 13 100 'S:\steamapps\common\W\bin\wine-game.exe'
    proc 14 100 /steam/reaper SteamLaunch AppId=7 -- x
    proc 15 100 /steam/reaper SteamLaunch -- AppId=888
    proc 16 100 /usr/bin/bash
    mkdir -p "${PULSAR_PRESENCE_PROC}/self" "${PULSAR_PRESENCE_PROC}/20"
    run py 'import json; idx = m.build_index(json.load(open(sys.argv[3])))
print(sorted(m.scan(idx).items()))
print(m.scan(idx, uid=os.getuid() + 1))' "$DB"
    [ "$status" -eq 0 ] || fail "$output"
    # by Steam id from the reaper; the same game twice is one; an AppId after -- is the game's own argument
    [ "${lines[0]}" = "[('100', 10), ('200', 12), ('400', 14)]" ]
    [ "${lines[1]}" = "{}" ]
}

@test "presence: tells Discord the game, under its own app id, from when it started" {
    start_discord
    proc 10 5000 /steam/reaper SteamLaunch AppId=495420 -- x
    run "$PRESENCE" --once
    [ "$status" -eq 0 ] || fail "$output"
    [[ "$output" == *"playing State of Decay 2 (pid 10)"* ]] || fail "$output"
    run python3 -c '
import json, os, sys
frames = [json.loads(l) for l in open(sys.argv[1]) if l.startswith("{")]
print(frames[0]["op"], frames[0]["client_id"], frames[0]["v"])
a = frames[1]
print(a["op"], a["cmd"], a["args"]["pid"], a["args"]["activity"]["timestamps"]["start"])
print(1700000000 * 1000 + 5000 * 1000 // os.sysconf("SC_CLK_TCK"))' "$DISCORD_LOG"
    [ "${lines[0]}" = "0 100 1" ]
    [ "${lines[1]}" = "1 SET_ACTIVITY 10 ${lines[2]}" ]
    # --once ends its connections, which is what clears the activity
    grep -qx CLOSED "$DISCORD_LOG"
}

@test "presence: clears the game when it stops, and shows it again when Discord comes back" {
    start_discord
    proc 10 100 /steam/reaper SteamLaunch AppId=495420 -- x
    run py 'import json, socket
idx = m.build_index(json.load(open(sys.argv[3]))); shown = {}
m.tick(idx, shown, sys.argv[4]); print(sorted(shown))
m.tick(idx, shown, sys.argv[4]); print(sorted(shown))        # still running: nothing new sent
os.remove(os.path.join(m.PROC, "10", "cmdline"))
m.tick(idx, shown, sys.argv[4]); print(sorted(shown))' "$DB" "$SOCK"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "pulsar-presence: playing State of Decay 2 (pid 10)" ] || fail "$output"
    [ "${lines[1]}" = "['100']" ]
    [ "${lines[2]}" = "['100']" ]
    [ "${lines[3]}" = "pulsar-presence: cleared State of Decay 2" ]
    [ "${lines[4]}" = "[]" ]
    [ "$(grep -c SET_ACTIVITY "$DISCORD_LOG")" -eq 1 ]
    grep -qx CLOSED "$DISCORD_LOG"
}

@test "presence: a Discord that went away is noticed, and the game is shown again" {
    start_discord
    proc 10 100 /steam/reaper SteamLaunch AppId=495420 -- x
    run py 'import json
idx = m.build_index(json.load(open(sys.argv[3]))); shown = {}
m.tick(idx, shown, sys.argv[4])
shown["100"].s.shutdown(2)          # as when Discord quits: the other end is gone
m.tick(idx, shown, sys.argv[4]); print(sorted(shown))' "$DB" "$SOCK"
    [ "$status" -eq 0 ] || fail "$output"
    [ "${lines[0]}" = "pulsar-presence: playing State of Decay 2 (pid 10)" ]
    [ "${lines[1]}" = "pulsar-presence: cleared State of Decay 2" ]
    [ "${lines[2]}" = "pulsar-presence: playing State of Decay 2 (pid 10)" ]
    [ "${lines[3]}" = "['100']" ]
    [ "$(grep -c SET_ACTIVITY "$DISCORD_LOG")" -eq 2 ]
}

@test "presence: Discord refusing the activity is said, and nothing is kept open" {
    start_discord refuse
    proc 10 100 /steam/reaper SteamLaunch AppId=495420 -- x
    run "$PRESENCE" --once
    [ "$status" -eq 0 ]
    [[ "$output" == *"can't show State of Decay 2: activity refused"* ]] || fail "$output"
    grep -qx CLOSED "$DISCORD_LOG"
}

@test "presence: without Discord running, nothing is scanned or fetched" {
    proc 10 100 /steam/reaper SteamLaunch AppId=495420 -- x
    run "$PRESENCE" --once
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$PULSAR_PRESENCE_INDEX" ]
}

@test "presence: the list is fetched once and kept; a failed refresh keeps the old one" {
    start_discord
    proc 10 100 /steam/reaper SteamLaunch AppId=495420 -- x
    run "$PRESENCE" --once
    [ -s "$PULSAR_PRESENCE_INDEX" ]
    # a week on, Discord's list is gone: the old index still names the game
    python3 -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["fetched"] -= 8 * 86400; json.dump(d, open(p, "w"))' "$PULSAR_PRESENCE_INDEX"
    export PULSAR_PRESENCE_DB_URL="file://${BATS_TEST_TMPDIR}/gone.json"
    run "$PRESENCE" --once
    [ "$status" -eq 0 ]
    [[ "$output" == *"can't fetch Discord's game list"* ]] || fail "$output"
    [[ "$output" == *"playing State of Decay 2"* ]] || fail "$output"
}

@test "presence: a fresh list is not fetched again" {
    start_discord
    run "$PRESENCE" --once
    [ -s "$PULSAR_PRESENCE_INDEX" ]
    export PULSAR_PRESENCE_DB_URL="file://${BATS_TEST_TMPDIR}/gone.json"
    run "$PRESENCE" --once
    [ "$status" -eq 0 ]
    [[ "$output" != *"can't fetch"* ]] || fail "$output"
}

@test "presence: the image installs it, enables it for every account, and links Discord's socket for host programs" {
    cf="${REPO}/Containerfile"
    unit="${REPO}/system_files/usr/lib/systemd/user/pulsar-presence.service"
    grep -qx 'COPY scripts/pulsar-presence /usr/libexec/pulsar/pulsar-presence' "$cf"
    grep -q '^      /usr/libexec/pulsar/pulsar-presence \\$' "$cf"
    grep -q 'systemctl --global enable pulsar-presence.service' "$cf"
    grep -qx 'enable pulsar-presence.service' "${REPO}/system_files/usr/lib/systemd/user-preset/50-pulsar.preset"
    awk '/^    for u in podman-auto-update.timer/,/; do/' "$cf" | grep -q 'pulsar-presence.service'
    grep -qx 'ExecStart=/usr/libexec/pulsar/pulsar-presence' "$unit"
    grep -qx 'WantedBy=graphical-session.target' "$unit"
    grep -qx 'L %t/discord-ipc-0 - - - - app/com.discordapp.Discord/discord-ipc-0' \
        "${REPO}/system_files/usr/share/user-tmpfiles.d/pulsar-discord-ipc.conf"
}
