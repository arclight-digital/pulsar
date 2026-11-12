#!/usr/bin/env bats
# Tests for system_files/usr/share/wireplumber/scripts/pulsar/network-sinks.lua.
#
# The bug these exist for: on 2026-11-12 talos, a Pulsar desktop with no local
# audio output, had found the living-room Sonos Arc over AirPlay, and
# WirePlumber made it the default output on its own. Every "Claude Code is
# done" notification then played on the Arc, which dropped the TV it was
# playing for the blip and did not switch back: three times in twenty minutes.
#
# Pinned here, against a real PipeWire and WirePlumber: a sink marked
# node.network (what PipeWire sets on AirPlay, tunnel, ROC and RTP sinks) is
# never the default or a stream's fallback on its own; it still is when the
# user picks it, and a stream that names it still reaches it. The first test
# runs without the hook and must see the bug, so the harness is known to
# reproduce it.
#
# WirePlumber reads the repo's files through XDG_DATA_DIRS, which it searches
# for both wireplumber.conf.d fragments and scripts: the files tested are the
# files shipped. The sinks are null sinks; node.network is the only thing
# the hook reads.

bats_require_minimum_version 1.5.0

REPO="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

setup() {
  for t in pipewire wireplumber pw-cli pw-dump pw-metadata pw-play wpctl python3; do
    command -v "$t" >/dev/null || skip "needs pipewire, wireplumber and pipewire-utils ($t)"
  done
  export XDG_RUNTIME_DIR="${BATS_TEST_TMPDIR}/run" HOME="${BATS_TEST_TMPDIR}/home"
  export XDG_CONFIG_HOME="${HOME}/.config" XDG_STATE_HOME="${HOME}/.local/state"
  export XDG_DATA_HOME="${HOME}/.local/share"
  mkdir -p -m 700 "${XDG_RUNTIME_DIR}"; mkdir -p "${HOME}"
  unset PIPEWIRE_REMOTE PULSE_SERVER DBUS_SESSION_BUS_ADDRESS
  # Run at a desk, this daemon pair must reach nothing real: no sound card,
  # no Bluetooth, and above all no AirPlay discovery, or the first test (no
  # hook) plays to whatever speaker is on the network.
  mkdir -p "${XDG_CONFIG_HOME}/pipewire/pipewire.conf.d" "${XDG_CONFIG_HOME}/wireplumber/wireplumber.conf.d"
  cat > "${XDG_CONFIG_HOME}/pipewire/pipewire.conf.d/90-test.conf" <<'EOF'
context.properties = {
    module.raop = false
    module.x11.bell = false
    module.jackdbus-detect = false
    module.portal = false
}
EOF
  cat > "${XDG_CONFIG_HOME}/wireplumber/wireplumber.conf.d/90-test.conf" <<'EOF'
wireplumber.profiles = {
  main = {
    hardware.audio = disabled
    hardware.bluetooth = disabled
    hardware.video-capture = disabled
  }
}
EOF
  python3 - "${BATS_TEST_TMPDIR}/blip.wav" <<'PY'
import sys, wave
w = wave.open(sys.argv[1], "wb")
w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
w.writeframes(b"\0" * 48000 * 4 * 5)
w.close()
PY
}

teardown() {
  [ -n "${PLAY:-}" ] && kill "${PLAY}" 2>/dev/null
  [ -n "${WP:-}" ] && kill "${WP}" 2>/dev/null
  [ -n "${PW:-}" ] && kill "${PW}" 2>/dev/null
  wait 2>/dev/null
  true
}

# start [shipped]: PipeWire, then WirePlumber, with Pulsar's files or without
start() {
  if [ "${1:-}" = shipped ]; then
    export XDG_DATA_DIRS="${REPO}/system_files/usr/share:/usr/share"
  else
    export XDG_DATA_DIRS=/usr/share
  fi
  pipewire >"${BATS_TEST_TMPDIR}/pipewire.log" 2>&1 & PW=$!
  wait_for "pw-cli info 0"
  WIREPLUMBER_DEBUG="2,s-pulsar-network-sinks:5" \
    wireplumber >"${BATS_TEST_TMPDIR}/wireplumber.log" 2>&1 & WP=$!
  wait_for "pw-metadata -n default 0 >/dev/null"
  # asserted, not trusted: the switches above took
  local objects; objects=$(pw-dump)
  if grep -q -E 'raop-discover|"device.api": "(alsa|bluez5)"' <<<"$objects"; then
    echo "the test daemons can reach real audio devices or AirPlay speakers" >&2
    return 1
  fi
}

# wait_for <command>: up to 10 s for it to succeed
wait_for() {
  local i
  for i in $(seq 1 100); do
    eval "$1" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "timed out waiting for: $1" >&2
  return 1
}

# sink <name> <network> <priority>
sink() {
  pw-cli create-node adapter "{ factory.name=support.null-audio-sink node.name=$1 \
    node.description=$1 media.class=Audio/Sink object.linger=true \
    audio.position=[FL FR] node.network=$2 priority.session=$3 priority.driver=$3 }" >/dev/null
  wait_for "node_id $1"
}

node_id() {
  pw-dump | python3 -c '
import json, sys
ids = [o["id"] for o in json.load(sys.stdin)
       if o.get("info", {}).get("props", {}).get("node.name") == sys.argv[1]]
print(ids[0]) if ids else sys.exit(1)' "$1"
}

default_sink() {
  pw-metadata -n default 0 default.audio.sink 2>/dev/null \
    | grep -o '"name":"[^"]*"' | cut -d'"' -f4
}

# settled: WirePlumber has processed everything queued so far. A second
# metadata key written after the change is seen only once the first is.
settled() {
  local mark="pulsar.test.$RANDOM"
  pw-metadata -n default 0 "$mark" 1 >/dev/null
  wait_for "pw-metadata -n default 0 $mark | grep -q value"
  sleep 0.5
}

# play [pw-play args]: starts a stream; linked_to prints the sinks it reached
play() {
  pw-play --properties='{ media.role = Notification }' "$@" "${BATS_TEST_TMPDIR}/blip.wav" \
    >"${BATS_TEST_TMPDIR}/play.log" 2>&1 & PLAY=$!
  # a refused stream can be gone before it is seen; that is an answer too
  wait_for "node_id_like pw-play || ! kill -0 ${PLAY}"
  settled
}

node_id_like() {
  pw-dump | python3 -c '
import json, sys
sys.exit(0 if any((o.get("info", {}).get("props", {}).get("node.name") or "").startswith(sys.argv[1])
                  for o in json.load(sys.stdin)) else 1)' "$1"
}

linked_to() {
  pw-dump | python3 -c '
import json, sys
objs = json.load(sys.stdin)
names = {o["id"]: o.get("info", {}).get("props", {}).get("node.name") or "" for o in objs}
out = sorted({names.get(o["info"]["input-node-id"]) for o in objs
              if o.get("type") == "PipeWire:Interface:Link"
              and names.get(o["info"]["output-node-id"], "").startswith("pw-play")})
print(",".join(out) or "none")'
}

@test "without Pulsar's hook, a lone network speaker takes the default and the stream" {
  start
  sink airplay true 1000
  settled
  [ "$(default_sink)" = airplay ]
  play
  [ "$(linked_to)" = airplay ]
}

@test "a lone network speaker is not made the default, and a stream is not sent to it" {
  start shipped
  sink airplay true 1000
  settled
  [ -z "$(default_sink)" ]
  play
  [ "$(linked_to)" = none ]
  grep -q "not choosing network node airplay" "${BATS_TEST_TMPDIR}/wireplumber.log"
  grep -q "not sending to network node airplay as a fallback" "${BATS_TEST_TMPDIR}/wireplumber.log"
}

@test "a local output wins over a network speaker ranked above it" {
  start shipped
  sink airplay true 2000
  sink speakers false 1000
  settled
  [ "$(default_sink)" = speakers ]
  play
  [ "$(linked_to)" = speakers ]
}

@test "a network speaker the user picks is the default and plays" {
  start shipped
  sink airplay true 1000
  sink speakers false 2000
  settled
  wpctl set-default "$(node_id airplay)"
  settled
  [ "$(default_sink)" = airplay ]
  play
  [ "$(linked_to)" = airplay ]
}

@test "a stream that names a network speaker reaches it" {
  start shipped
  sink airplay true 1000
  settled
  play --target airplay
  [ "$(linked_to)" = airplay ]
}
