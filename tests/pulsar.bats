#!/usr/bin/env bats
# Tests for the pulsar CLI.
#
# These run in CI on Ubuntu, on a machine that is not a Pulsar system and has
# no bootc, no rpm-ostree and no /sys/kernel/sched_ext. That is the point: the
# CLI has to degrade honestly on a system it does not understand rather than
# crash or, worse, report health it cannot actually see.
#
# What is deliberately NOT tested here: that `pulsar update` upgrades anything.
# What IS tested is which tool it hands to, because that is a decision and not
# a pass-through -- picking bootc on a system with layered packages stages a
# deployment without them, and you find out at the next boot.

setup() {
    PULSAR="${BATS_TEST_DIRNAME}/../cli/pulsar"
    export PULSAR_MANIFEST="${BATS_TEST_TMPDIR}/manifest.json"
    cat > "$PULSAR_MANIFEST" <<'JSON'
{
  "image": "pulsar",
  "variant": "vanilla",
  "version": "44.20260805.0",
  "base": "fedora-silverblue:44",
  "built": "2026-08-05T19:44:00Z",
  "kernel": "7.1.5-201.fc44.x86_64",
  "components": { "scheduler": "scx_bpfland", "gamescope": "3.16.14-1.fc44" },
  "changelog_url": "https://example.invalid/changelog.json",
  "attestation": "gh attestation verify oci://ghcr.io/x --owner y"
}
JSON
}

@test "runs and reports a version" {
    run "$PULSAR" --version
    [ "$status" -eq 0 ]
    [[ "$output" == pulsar\ * ]]
}

@test "bare --help prints the top-level usage" {
    run "$PULSAR" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"pulsar manifest"* ]]
    [[ "$output" == *"pulsar doctor"* ]]
}

@test "--help after a subcommand belongs to that subcommand" {
    run "$PULSAR" setup --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"devbox"* ]]
    [[ "$output" == *"quadlet"* ]]
    # must NOT have fallen through to the global usage
    [[ "$output" != *"pulsar rollback"* ]]
}

@test "unknown command fails and does not look like success" {
    run "$PULSAR" definitely-not-a-command
    [ "$status" -ne 0 ]
}

@test "unknown setup recipe fails" {
    run "$PULSAR" setup not-a-recipe
    [ "$status" -ne 0 ]
}

@test "manifest renders every key with its value on the same line" {
    run "$PULSAR" manifest
    [ "$status" -eq 0 ]
    [[ "$output" == *"44.20260805.0"* ]]
    [[ "$output" == *"scx_bpfland"* ]]
}

@test "manifest lists facts, not other commands to run" {
    # `sbom` and `attestation` were rows whose values were commands. The
    # attestation one was 82 characters wide to restate what --help says.
    run "$PULSAR" manifest
    [ "$status" -eq 0 ]
    [[ "$output" != *"pulsar sbom"* ]]
    [[ "$output" != *"pulsar attest"* ]]
    [[ "$output" != *"gh attestation"* ]]
}

@test "attest runs the verify command the manifest carries, not a baked one" {
    # The owner and registry are build-time facts: an image built from a fork
    # must verify against the fork, so the command comes from the manifest.
    # Naming a verifier that does not exist proves which one it reached for.
    cat > "$PULSAR_MANIFEST" <<'JSON'
{"image":"pulsar","attestation":"definitely-not-a-real-verifier verify oci://x"}
JSON
    run "$PULSAR" attest
    [ "$status" -ne 0 ]
    [[ "$output" == *"definitely-not-a-real-verifier"* ]]
}

@test "attest refuses an image whose manifest has no attestation" {
    echo '{"image":"pulsar"}' > "$PULSAR_MANIFEST"
    run "$PULSAR" attest
    [ "$status" -ne 0 ]
    [[ "$output" == *"no attestation"* ]]
}

@test "manifest --json is machine readable and unstyled" {
    run "$PULSAR" manifest --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.version == "44.20260805.0"'
}

@test "manifest --json carries the host facts the rows show" {
    run "$PULSAR" manifest --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.host | type == "object"'
    # /proc/uptime exists on anything this can run on, and it goes out as a
    # number: a machine should not have to parse "2h 14m".
    echo "$output" | jq -e '.host.uptime_s | type == "number"'
    echo "$output" | jq -e '.host.gpu == null or (.host.gpu | type == "array")'
}

@test "deleting the host key leaves exactly the baked manifest" {
    # The reason host is one key instead of merged fields: two machines on the
    # same build must still compare equal.
    run "$PULSAR" manifest --json
    [ "$status" -eq 0 ]
    echo "$output" | jq --slurpfile baked "$PULSAR_MANIFEST" -e 'del(.host) == $baked[0]'
}

@test "host facts never contain the hostname" {
    # The rows identify the hardware, not the machine or its owner -- this
    # output gets pasted into public bug reports.
    #
    # Read from /proc rather than calling hostname(1): the binary is absent
    # from a minimal container, and a test that silently errors instead of
    # checking is worse than no test.
    local host
    host=$(cat /proc/sys/kernel/hostname 2>/dev/null || true)
    [ -n "$host" ] || skip "no hostname to look for"
    run "$PULSAR" manifest
    [ "$status" -eq 0 ]
    [[ "$output" != *"$host"* ]]
}

@test "piped output carries no ANSI escapes" {
    run "$PULSAR" manifest
    [ "$status" -eq 0 ]
    # $'\033' must not appear when stdout is not a terminal
    [[ "$output" != *$'\033'* ]]
}

@test "a missing manifest is an error, not a crash" {
    PULSAR_MANIFEST="${BATS_TEST_TMPDIR}/nope.json" run "$PULSAR" manifest
    [ "$status" -eq 1 ]
    [[ "$output" == *"no manifest"* ]]
}

@test "changelog without a url in the manifest fails cleanly" {
    echo '{"image":"pulsar"}' > "$PULSAR_MANIFEST"
    run "$PULSAR" changelog
    [ "$status" -ne 0 ]
    [[ "$output" == *"changelog_url"* ]]
}

@test "root-only commands refuse to run as a normal user" {
    [ "$(id -u)" -eq 0 ] && skip "running as root"
    for c in update rollback pin unpin; do
        run "$PULSAR" "$c"
        [ "$status" -ne 0 ]
        [[ "$output" == *"root"* ]]
    done
}

# ---------------------------------------------------------------------------
# Layering detection and the update path it chooses.
#
# CI has neither rpm-ostree nor bootc, so both are stubbed. The stub is not
# asserting that a mock was called: `rpm-ostree status --json` is the input to
# a real decision, and these pin what that decision does with each answer.
# ---------------------------------------------------------------------------

# $1 = the JSON `rpm-ostree status --json` should print. Both tools record the
# argv they were handed, so a test can read back which one ran and with what.
stub_ostree() {
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    printf '%s' "$1" > "${BATS_TEST_TMPDIR}/status.json"
    cat > "${STUB}/rpm-ostree" <<EOF
#!/bin/sh
[ "\$1" = status ] && exec cat "${BATS_TEST_TMPDIR}/status.json"
echo "rpm-ostree \$*"
EOF
    cat > "${STUB}/bootc" <<'EOF'
#!/bin/sh
echo "bootc $*"
EOF
    chmod +x "${STUB}/rpm-ostree" "${STUB}/bootc"
    PATH="${STUB}:${PATH}"
    export PATH
}

# `update` needs root, and CI is not root. An unprivileged user namespace is
# enough -- nothing here touches the real system -- but Ubuntu can forbid one,
# so the routing tests say so rather than quietly passing.
as_root() {
    unshare -r true 2>/dev/null || skip "no unprivileged user namespaces"
    run unshare -r env "PATH=${PATH}" "PULSAR_MANIFEST=${PULSAR_MANIFEST}" "$PULSAR" "$@"
}

CLEAN_STATUS='{"deployments":[{"booted":true,"version":"44.1","pinned":false}]}'
# One of each shape the origin can carry: a repo layer, a local rpm, and an
# override. A check that only looked at requested-packages would pass on the
# first and lose the other two.
LAYERED_STATUS='{"deployments":[{"booted":true,"version":"44.1",
  "requested-packages":["1password"],
  "requested-local-packages":["some-local-1.0.rpm"],
  "requested-base-removals":["firefox"]}]}'

# `update --check` asks a registry, so it needs one. The stub answers whatever
# digest and version label the test wants the tag to resolve to.
stub_skopeo() {
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    printf '{"Digest":"%s","Labels":{"org.opencontainers.image.version":"%s"}}' \
        "$1" "$2" > "${BATS_TEST_TMPDIR}/inspect.json"
    cat > "${STUB}/skopeo" <<EOF
#!/bin/sh
[ "\$1" = inspect ] && exec cat "${BATS_TEST_TMPDIR}/inspect.json"
exit 1
EOF
    chmod +x "${STUB}/skopeo"
    PATH="${STUB}:${PATH}"
    export PATH
}

# Records every notification rather than showing one, so a test can count them.
stub_notify() {
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    NOTIFY_LOG="${BATS_TEST_TMPDIR}/notify.log"
    : > "$NOTIFY_LOG"
    cat > "${STUB}/notify-send" <<EOF
#!/bin/sh
echo "\$*" >> "${NOTIFY_LOG}"
EOF
    chmod +x "${STUB}/notify-send"
    PATH="${STUB}:${PATH}"
    export PATH
    export PULSAR_UPDATE_STATE="${BATS_TEST_TMPDIR}/state"
}

# A container-native deployment, which is what --check needs and what the
# routing fixtures above deliberately are not.
CHECK_STATUS='{"deployments":[{"booted":true,"version":"44.1",
  "container-image-reference":"ostree-unverified-registry:ghcr.io/x/pulsar:latest",
  "container-image-reference-digest":"sha256:aaa"}]}'
# The same, carrying a layer. This is the shape rpm-ostree gets wrong.
CHECK_LAYERED='{"deployments":[{"booted":true,"version":"44.1",
  "requested-packages":["1password"],
  "container-image-reference":"ostree-unverified-registry:ghcr.io/x/pulsar:latest",
  "container-image-reference-digest":"sha256:aaa"}]}'
# Update already fetched and waiting for a reboot.
CHECK_STAGED='{"deployments":[
  {"staged":true,"version":"44.2","container-image-reference-digest":"sha256:bbb"},
  {"booted":true,"version":"44.1",
   "container-image-reference":"ostree-unverified-registry:ghcr.io/x/pulsar:latest",
   "container-image-reference-digest":"sha256:aaa"}]}'

@test "doctor reports layering on the booted deployment" {
    stub_ostree "$LAYERED_STATUS"
    run "$PULSAR" doctor --json
    detail=$(echo "$output" | jq -r '.checks[] | select(.id=="updates") | .detail')
    [[ "$detail" == *"3 layered"* ]]
}

@test "doctor does not invent layering on a clean deployment" {
    stub_ostree "$CLEAN_STATUS"
    run "$PULSAR" doctor --json
    detail=$(echo "$output" | jq -r '.checks[] | select(.id=="updates") | .detail')
    [[ "$detail" != *"layered"* ]]
}

@test "layering on a deployment that is not booted is not this system's" {
    # A staged deployment's layers say nothing about what an upgrade of the
    # booted one has to preserve.
    stub_ostree '{"deployments":[{"booted":true,"version":"44.1"},
                 {"staged":true,"version":"44.2","requested-packages":["x"]}]}'
    run "$PULSAR" doctor --json
    detail=$(echo "$output" | jq -r '.checks[] | select(.id=="updates") | .detail')
    [[ "$detail" != *"layered"* ]]
}

@test "update goes through bootc when nothing is layered" {
    stub_ostree "$CLEAN_STATUS"
    as_root update
    [ "$status" -eq 0 ]
    [[ "$output" == *"bootc upgrade"* ]]
    [[ "$output" != *"rpm-ostree upgrade"* ]]
}

@test "update goes through rpm-ostree when packages are layered" {
    stub_ostree "$LAYERED_STATUS"
    as_root update
    [ "$status" -eq 0 ]
    [[ "$output" == *"rpm-ostree upgrade"* ]]
    [[ "$output" != *"bootc upgrade"* ]]
    # and says so, because the tool that ran is not the one the docs name
    [[ "$output" == *"rpm-ostree"* ]]
}

@test "update translates --apply for the rpm-ostree path" {
    stub_ostree "$LAYERED_STATUS"
    as_root update --apply
    [[ "$output" == *"rpm-ostree upgrade --reboot"* ]]
}

@test "update --check answers from the registry, not from rpm-ostree" {
    # The regression this whole path exists for. `rpm-ostree upgrade --check`
    # reports "No updates available" on a layered deployment whatever the
    # registry holds -- its container query needs an ostree.manifest-digest the
    # layering merge commit does not carry. Handing --check to it, or to bootc
    # (which drops layers and demands root just to read), is the bug.
    stub_ostree "$CHECK_LAYERED"
    stub_skopeo "sha256:bbb" "44.2"
    run "$PULSAR" update --check
    [[ "$output" != *"rpm-ostree upgrade"* ]]
    [[ "$output" != *"bootc upgrade"* ]]
    [ "$status" -eq 10 ]
}

@test "update --check needs no root" {
    stub_ostree "$CHECK_STATUS"
    stub_skopeo "sha256:aaa" "44.1"
    run "$PULSAR" update --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"up to date"* ]]
}

@test "update --check exits 10 and names both versions when one is published" {
    stub_ostree "$CHECK_STATUS"
    stub_skopeo "sha256:bbb" "44.2"
    run "$PULSAR" update --check
    [ "$status" -eq 10 ]
    [[ "$output" == *"44.1 -> 44.2"* ]]
}

@test "update --check calls an already-staged update staged, not available" {
    stub_ostree "$CHECK_STAGED"
    stub_skopeo "sha256:bbb" "44.2"
    run "$PULSAR" update --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"staged"* ]]
    [[ "$output" != *"update available"* ]]
}

@test "update --notify notifies once per published digest, not once per check" {
    stub_ostree "$CHECK_STATUS"
    stub_skopeo "sha256:bbb" "44.2"
    stub_notify
    run "$PULSAR" update --check --notify
    [ "$status" -eq 10 ]
    run "$PULSAR" update --check --notify
    [ "$status" -eq 10 ]
    [ "$(wc -l < "$NOTIFY_LOG")" -eq 1 ]
    # A different build is a different notification.
    stub_skopeo "sha256:ccc" "44.3"
    run "$PULSAR" update --check --notify
    [ "$(wc -l < "$NOTIFY_LOG")" -eq 2 ]
}

@test "update --check refuses rather than guess when the deployment is not container-native" {
    stub_ostree "$CLEAN_STATUS"
    stub_skopeo "sha256:bbb" "44.2"
    run "$PULSAR" update --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"container-native"* ]]
}

@test "update --check reports an unreachable registry rather than claiming up to date" {
    stub_ostree "$CHECK_STATUS"
    STUB="${BATS_TEST_TMPDIR}/stub"; mkdir -p "$STUB"
    printf '#!/bin/sh\nexit 1\n' > "${STUB}/skopeo"
    chmod +x "${STUB}/skopeo"
    PATH="${STUB}:${PATH}"; export PATH
    run "$PULSAR" update --check
    [ "$status" -eq 1 ]
    [[ "$output" != *"up to date"* ]]
}

@test "update refuses rather than guess when status is unreadable" {
    stub_ostree 'not json at all'
    as_root update
    [ "$status" -ne 0 ]
    [[ "$output" != *"bootc upgrade"* ]]
    [[ "$output" != *"rpm-ostree upgrade"* ]]
}

@test "doctor produces valid json even off a Pulsar system" {
    run "$PULSAR" doctor --json
    # status may be 0 or 1 depending on the host; the contract is valid JSON
    echo "$output" | jq -e '.checks | type == "array"'
    echo "$output" | jq -e '.ok | type == "boolean"'
}

@test "doctor json marks every check with a known severity" {
    run "$PULSAR" doctor --json
    echo "$output" | jq -e 'all(.checks[]; .status == "ok" or .status == "warn" or .status == "fail")'
}

@test "doctor exit code agrees with the ok field" {
    run "$PULSAR" doctor --json
    local ok; ok=$(echo "$output" | jq -r '.ok')
    if [ "$ok" = "true" ]; then [ "$status" -eq 0 ]; else [ "$status" -ne 0 ]; fi
}

@test "doctor does not claim greenboot is healthy when it is absent" {
    # The original bug: `systemctl is-enabled` prints not-found AND exits
    # nonzero, so a `|| echo not-found` fallback produced "not-found\nnot-found",
    # matched nothing, and the check reported "health checks passed" on a
    # system with no greenboot at all.
    run "$PULSAR" doctor --json
    run_status=$(echo "$output" | jq -r '.checks[] | select(.id=="greenboot") | .status')
    summary=$(echo "$output" | jq -r '.checks[] | select(.id=="greenboot") | .summary')
    if [ "$run_status" = "ok" ]; then
        [[ "$summary" != *"not installed"* ]]
    fi
}

# --- manifest layout --------------------------------------------------------
# The key column was a hardcoded 11, which "attestation" (11) ran into and
# which "scheduler_btf" (13) overflowed entirely. It is measured now, so these
# pin the measuring rather than the number.

@test "manifest key column is measured from the longest key" {
    cat > "$PULSAR_MANIFEST" <<'JSON'
{"image":"pulsar","version":"1","components":{"a":"x","scheduler_btf":"malformed"}}
JSON
    run "$PULSAR" manifest
    [ "$status" -eq 0 ]
    # every value must start at the same column
    cols=$(printf '%s\n' "$output" | awk '{ i=index($0,$2); print i }' | sort -u | wc -l)
    [ "$cols" -eq 1 ]
}

@test "manifest survives a key longer than any built-in one" {
    cat > "$PULSAR_MANIFEST" <<'JSON'
{"image":"pulsar","components":{"an_absurdly_long_component_key":"v"}}
JSON
    run "$PULSAR" manifest
    [ "$status" -eq 0 ]
    # padded to the longest key + 2, so exactly two spaces here
    [[ "$output" == *"an_absurdly_long_component_key  v"* ]]
}

@test "a corrupt manifest fails loudly instead of printing nothing" {
    echo 'not json at all' > "$PULSAR_MANIFEST"
    run "$PULSAR" manifest
    [ "$status" -ne 0 ]
}

LOGO_ART="system_files/usr/share/pulsar/logo.ansi"

@test "every line of the shipped logo has the same visible width" {
    # The info column is pasted at a fixed offset, so one short line shears
    # the whole readout. The art is generated, so this guards the generator.
    art="${BATS_TEST_DIRNAME}/../${LOGO_ART}"
    [ -r "$art" ]
    widths=$(sed $'s/\033\\[[0-9;]*m//g' "$art" | awk '{ print length($0) }' | sort -u | wc -l)
    [ "$widths" -eq 1 ]
}

@test "the logo is 7-bit ASCII, as a logo called ASCII should be" {
    art="${BATS_TEST_DIRNAME}/../${LOGO_ART}"
    # strip the colour escapes, then assert nothing outside printable ASCII
    run bash -c "sed \$'s/\033\\[[0-9;]*m//g' '$art' | LC_ALL=C grep -qP '[^\\x20-\\x7e]'"
    [ "$status" -ne 0 ]
}

@test "the logo carries no blank margin, in either direction" {
    # The SVG pads generously for the glow. In a terminal that padding is not
    # neutral: the art is drawn at a fixed width and the readout pasted at
    # that offset, so a blank column on the right is gap nobody chose and one
    # on the left is indent. This is the invariant behind the trim -- at least
    # one row must reach the first column and at least one must reach the
    # last, and the same for the top and bottom rows.
    art="${BATS_TEST_DIRNAME}/../${LOGO_ART}"
    plain=$(sed $'s/\033\\[[0-9;]*m//g' "$art")
    lead=$(awk '{ n = match($0, /[^ ]/); print (n ? n - 1 : 999) }' <<<"$plain" | sort -n | head -1)
    trail=$(awk '{ s = $0; sub(/ +$/, "", s); print (length(s) ? length($0) - length(s) : 999) }' <<<"$plain" | sort -n | head -1)
    [ "$lead" -eq 0 ]  || fail "${lead} blank columns on the left"
    [ "$trail" -eq 0 ] || fail "${trail} blank columns on the right"
    [ -n "$(head -1 <<<"$plain" | tr -d ' ')" ] || fail "blank first row"
    [ -n "$(tail -1 <<<"$plain" | tr -d ' ')" ] || fail "blank last row"
}

@test "the logo is as tall as a readout, so the two end together" {
    # 19 rows is the point of the 56-column rasterisation: a typical readout is
    # five header rows, six or seven host rows and seven components, and the
    # art stopping six rows short of that is what this size exists to fix.
    [ "$(wc -l < "${BATS_TEST_DIRNAME}/../${LOGO_ART}")" -eq 19 ]
}

# `pulsar manifest` picks the art size from the REAL terminal width, and a
# pipe reports none -- so the only way to test the choice is to give it a
# terminal of a known width. python3 is already a check.sh requirement.
# Prints the first output line with the colour escapes and the CR stripped.
manifest_first_line() {
    # LOGO_DIR pinned at the repo's art: on a machine that has Pulsar
    # installed the CLI would otherwise read /usr/share/pulsar and test the
    # art of whatever image is booted rather than the art in this tree.
    TERM=xterm-256color \
    PULSAR_LOGO_DIR="${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar" \
    python3 - "$1" "$PULSAR" <<'PYEOF' | sed -e $'s/\033\[[0-9;]*m//g' -e $'s/\r$//' | head -1
import os, pty, sys, fcntl, termios, struct, select
cols, pulsar = int(sys.argv[1]), sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(pulsar, [pulsar, "manifest"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 60, cols, 0, 0))
buf = b""
while True:
    try:
        r, _, _ = select.select([fd], [], [], 20)
        if not r:
            break
        d = os.read(fd, 65536)
        if not d:
            break
        buf += d
    except OSError:
        break
os.waitpid(pid, 0)
sys.stdout.write(buf.decode("utf-8", "replace"))
PYEOF
}

@test "the art is pasted at its own width, with no margin in between" {
    # 36 columns of art, then the two spaces paste_logo adds, then the first
    # key. Written as an exact width because the whole point of the trim is
    # that the offset IS the mark: a regression that reinstates the glow
    # padding shows up here as a wider prefix, not as a vaguer one.
    line=$(manifest_first_line 200)
    [[ "$line" =~ ^.{36}[[:space:]][[:space:]]image ]] || fail "not 36 columns of art: ${line}"
}

@test "a terminal too narrow for the art gets the readout alone" {
    # The fit rule keeps art only while it leaves the values 24 columns, so
    # with this manifest's 9-character key column the mark needs 73.
    line=$(manifest_first_line 40)
    [[ "$line" =~ ^image[[:space:]] ]] || fail "art drawn at 40 columns: ${line}"
}

@test "the trimmed mark is drawn on terminals the untrimmed one lost" {
    # 80 columns is the case that made the trim worth doing rather than
    # shipping a second, smaller file: the old 38-wide art needed 79 and the
    # untrimmed 56-wide one would have needed 97.
    line=$(manifest_first_line 80)
    [[ "$line" =~ ^.{36}[[:space:]][[:space:]]image ]] || fail "no art at 80 columns: ${line}"
}

@test "manifest draws the logo when asked and omits it when told not to" {
    PULSAR_LOGO="${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar/logo.ansi"
    export PULSAR_LOGO
    # NOT a line count. That worked only while the art was taller than the
    # readout; once the host rows fill in, the readout is the longer column
    # and both forms come out the same height. The art is the only thing that
    # carries colour into a pipe, so that is the tell.
    run env LOGO=always "$PULSAR" manifest
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\033'* ]]
    run env LOGO=never "$PULSAR" manifest
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\033'* ]]
}

@test "the logo never appears in piped output" {
    # bats captures through a pipe, so this is the not-a-terminal path
    PULSAR_LOGO="${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar/logo.ansi"
    export PULSAR_LOGO
    run "$PULSAR" manifest
    [[ "$output" != *$'\033'* ]]
    # every line must start with a manifest key, not with art
    while IFS= read -r line; do
        [[ "$line" =~ ^[a-z_]+[[:space:]] ]] || fail "not a key row: $line"
    done <<< "$output"
}

# --- audit pass: argument and input hygiene ---------------------------------

@test "commands that take no arguments reject them" {
    run "$PULSAR" doctor tomorrow
    [ "$status" -ne 0 ]
    [[ "$output" == *"takes no arguments"* ]]
    run "$PULSAR" manifest extra
    [ "$status" -ne 0 ]
}

@test "changelog renders a baseline as a baseline, not as zero changes" {
    cl="${BATS_TEST_TMPDIR}/cl.json"
    printf '{"baseline":true,"generated":"2026-08-05T00:00:00Z"}' > "$cl"
    jq --arg u "file://${cl}" '.changelog_url = $u' "$PULSAR_MANIFEST" > "${PULSAR_MANIFEST}.n" \
        && mv "${PULSAR_MANIFEST}.n" "$PULSAR_MANIFEST"
    run "$PULSAR" changelog
    [ "$status" -eq 0 ]
    [[ "$output" == *"first build"* ]]
    [[ "$output" != *"0 upgraded"* ]]
}

@test "changelog marks a downgrade instead of blending it into upgrades" {
    cl="${BATS_TEST_TMPDIR}/cl.json"
    cat > "$cl" <<'JSON'
{"generated":"2026-08-05T00:00:00Z",
 "summary":{"added":0,"removed":0,"upgraded":1,"downgraded":1,"changed":0},
 "changed":[{"name":"up","from":"1","to":"2","direction":"upgraded"},
            {"name":"down","from":"2","to":"1","direction":"downgraded"}],
 "added":[],"removed":[]}
JSON
    jq --arg u "file://${cl}" '.changelog_url = $u' "$PULSAR_MANIFEST" > "${PULSAR_MANIFEST}.n" \
        && mv "${PULSAR_MANIFEST}.n" "$PULSAR_MANIFEST"
    run "$PULSAR" changelog
    [ "$status" -eq 0 ]
    [[ "$output" == *"~ up"* ]]
    [[ "$output" == *"! down"* ]]
}

@test "changelog dies cleanly when the url serves something else" {
    cl="${BATS_TEST_TMPDIR}/cl.json"
    printf 'this is a captive portal, honest' > "$cl"
    jq --arg u "file://${cl}" '.changelog_url = $u' "$PULSAR_MANIFEST" > "${PULSAR_MANIFEST}.n" \
        && mv "${PULSAR_MANIFEST}.n" "$PULSAR_MANIFEST"
    run "$PULSAR" changelog
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a changelog"* ]]
}

@test "setup recipes refuse to run as root" {
    [ "$(id -u)" -eq 0 ] || skip "meaningful only as root"
    run "$PULSAR" setup quadlet
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not run as root"* ]]
}
