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


# bats-core has no fail(); bats-assert does, and this suite does not load it.
# Prints why and fails the test.
fail() { printf '%s\n' "$*" >&2; return 1; }

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

@test "verify runs the verify command the manifest carries, not a baked one" {
    # The owner and registry are build-time facts: an image built from a fork
    # must verify against the fork, so the command comes from the manifest.
    # Naming a verifier that does not exist proves which one it reached for.
    cat > "$PULSAR_MANIFEST" <<'JSON'
{"image":"pulsar","attestation":"definitely-not-a-real-verifier verify oci://x"}
JSON
    run "$PULSAR" verify
    [ "$status" -ne 0 ]
    [[ "$output" == *"definitely-not-a-real-verifier"* ]]
}

@test "verify refuses an image whose manifest has no attestation" {
    echo '{"image":"pulsar"}' > "$PULSAR_MANIFEST"
    run "$PULSAR" verify
    [ "$status" -ne 0 ]
    [[ "$output" == *"not signed yet"* ]]
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
    for c in update rollback "pin on" "pin off" "checkpoint list" "setup apps"; do
        # shellcheck disable=SC2086
        run "$PULSAR" $c
        [ "$status" -ne 0 ]
        # the exact command to rerun, not a neighbor that does something else
        [[ "$output" == *"try: sudo pulsar ${c}"* ]]
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
# Already root: run it straight. A nested namespace would map only uid 0, and
# root there cannot read a checkout owned by anyone else.
as_root() {
    local ns=(unshare -r)
    if [ "$(id -u)" -eq 0 ]; then ns=()
    else unshare -r true 2>/dev/null || skip "no unprivileged user namespaces"; fi
    run "${ns[@]}" env "PATH=${PATH}" "PULSAR_MANIFEST=${PULSAR_MANIFEST}" "$PULSAR" "$@"
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

# What every ISO before 2026-09-25 installed: bib switched the new system onto
# the digest it was built from, so the origin names a digest and not a tag.
CHECK_PINNED='{"deployments":[{"booted":true,"version":"44.1",
  "requested-packages":["1password"],
  "container-image-reference":"ostree-unverified-registry:ghcr.io/x/pulsar-nvidia@sha256:aaa",
  "container-image-reference-digest":"sha256:aaa"}]}'

@test "REGRESSION: update --check does not call a digest-pinned system up to date" {
    # The registry is asked what the digest points at, and it always answers
    # "itself" -- so the old code printed "up to date" on a machine that could
    # never update, and the six-hourly timer never said a word.
    stub_ostree "$CHECK_PINNED"
    stub_skopeo "sha256:aaa" "44.1"
    run "$PULSAR" update --check
    [ "$status" -eq 1 ]
    [[ "$output" != *"up to date"* ]]
    [[ "$output" == *"rpm-ostree rebase ostree-unverified-registry:ghcr.io/x/pulsar-nvidia:latest"* ]]
}

@test "update refuses a digest-pinned system rather than re-pull the same image" {
    stub_ostree "$CHECK_PINNED"
    as_root update
    [ "$status" -ne 0 ]
    [[ "$output" != *"bootc upgrade"* ]]
    [[ "$output" != *"rpm-ostree upgrade"* ]]
    [[ "$output" == *"rpm-ostree rebase ostree-unverified-registry:ghcr.io/x/pulsar-nvidia:latest"* ]]
}

@test "doctor fails a digest-pinned origin and names the fix" {
    stub_ostree "$CHECK_PINNED"
    run "$PULSAR" doctor --json
    check=$(echo "$output" | jq -c '.checks[] | select(.id=="origin")')
    [ "$(echo "$check" | jq -r .status)" = fail ]
    [[ "$(echo "$check" | jq -r .detail)" == *"ghcr.io/x/pulsar-nvidia:latest"* ]]
}

@test "a tag-following origin is not mistaken for a pinned one" {
    stub_ostree "$CHECK_STATUS"
    run "$PULSAR" doctor --json
    [ "$(echo "$output" | jq -r '.checks[] | select(.id=="origin") | .status')" = ok ]
    stub_skopeo "sha256:aaa" "44.1"
    run "$PULSAR" update --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"up to date"* ]]
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
    # 19 rows is the point of the 38-column rasterisation: a typical readout is
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
    # 38 columns of art, then the two spaces paste_logo adds, then the first
    # key. Written as an exact width because the whole point of the trim is
    # that the offset IS the mark: a regression that reinstates the glow
    # padding shows up here as a wider prefix, not as a vaguer one.
    line=$(manifest_first_line 200)
    [[ "$line" =~ ^.{38}[[:space:]][[:space:]]image ]] || fail "not 38 columns of art: ${line}"
}

@test "a terminal too narrow for the art gets the readout alone" {
    # The fit rule keeps art only while it leaves the values 24 columns, so
    # with this manifest's 9-character key column the mark needs 75.
    line=$(manifest_first_line 40)
    [[ "$line" =~ ^image[[:space:]] ]] || fail "art drawn at 40 columns: ${line}"
}

@test "the trimmed mark is drawn on terminals the untrimmed one lost" {
    # 80 columns is the case that made the trim worth doing rather than
    # shipping a second, smaller file: the old 38-wide art needed 79 and an
    # untrimmed 56-wide one would have needed 97. The v2 mark, rendered
    # at the terminal's true cell shape, is 38 wide and needs 75.
    line=$(manifest_first_line 80)
    [[ "$line" =~ ^.{38}[[:space:]][[:space:]]image ]] || fail "no art at 80 columns: ${line}"
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
    [[ "$output" == *"no such check: tomorrow"* ]]
    run "$PULSAR" manifest extra
    [ "$status" -ne 0 ]
    [[ "$output" == *"takes no arguments"* ]]
    # a recipe with a stray argument does not run
    run "$PULSAR" setup devbox extra
    [ "$status" -ne 0 ]
    [[ "$output" == *"takes no arguments"* ]]
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

# ---------------------------------------------------------------------------
# doctor: the gamemode renice check.
#
# renice=10 is the one gaming setting in this image whose failure is entirely
# SILENT. The nice grant ships in the gamemode package, the request ships in
# /etc/gamemode.ini, and if the account is not in the gamemode group nothing
# anywhere says so -- gamemoded logs a failed setpriority and carries on, the
# game runs, and the priority simply never applies. This check is the only
# thing that reports it, so what is pinned here is that it reports the right
# ONE of five states, and in particular that it distinguishes "enrolled" from
# "enrolled and live in this session".
# ---------------------------------------------------------------------------

# $1 = groups `id -nG <user>` should report (the account database)
# $2 = groups `id -nG` should report (this session, fixed by PAM at login)
stub_gamemode_env() {
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    export DB_GROUPS="$1" SESSION_GROUPS="$2"
    export GM_GROUP_EXISTS="${GM_GROUP_EXISTS:-1}"
    cat > "${STUB}/getent" <<'EOF'
#!/bin/sh
[ "$1" = group ] || exit 0
[ "${GM_GROUP_EXISTS}" = 1 ] || exit 2
printf 'gamemode:x:983:\n'
EOF
    cat > "${STUB}/id" <<'EOF'
#!/bin/sh
case "$1" in
    -u)  echo 1000 ;;
    -un) echo proto ;;
    -nG) if [ -n "$2" ]; then echo "$DB_GROUPS"; else echo "$SESSION_GROUPS"; fi ;;
    *)   exit 1 ;;
esac
EOF
    chmod +x "${STUB}/getent" "${STUB}/id"
    PATH="${STUB}:${PATH}"
    export PATH

    export PULSAR_GAMEMODE_INI="${BATS_TEST_TMPDIR}/gamemode.ini"
    printf 'renice=10\n' > "$PULSAR_GAMEMODE_INI"
    export PULSAR_LIMITS_DIR="${BATS_TEST_TMPDIR}/limits.d"
    export PULSAR_LIMITS_CONF="${BATS_TEST_TMPDIR}/limits.conf"
    mkdir -p "$PULSAR_LIMITS_DIR"
    : > "$PULSAR_LIMITS_CONF"
    printf '@gamemode - nice -10\n' > "${PULSAR_LIMITS_DIR}/10-gamemode.conf"
    unset SUDO_USER
}

gm_check() { "$PULSAR" doctor --json | jq -r '.checks[] | select(.id=="gamemode") | .status + " " + .summary + " " + .detail'; }

@test "doctor: gamemode enrolled and live in this session is ok" {
    stub_gamemode_env "proto wheel gamemode" "proto wheel gamemode"
    run gm_check
    [[ "$output" == ok* ]]
    [[ "$output" == *"renice=10 available"* ]]
}

@test "doctor: enrolled but the session predates it is a warning, not ok" {
    # The first boot after an install lands here every time: the unit enrolled
    # the user while they were already logged in, so /etc/group says yes and
    # the running session says no. Reporting ok here would be a lie that costs
    # someone an afternoon.
    stub_gamemode_env "proto wheel gamemode" "proto wheel"
    run gm_check
    [[ "$output" == warn* ]]
    [[ "$output" == *"predates it"* ]]
    [[ "$output" == *"next login"* ]]
}

@test "doctor: an unenrolled account names the command that fixes it" {
    stub_gamemode_env "proto wheel" "proto wheel"
    run gm_check
    [[ "$output" == warn* ]]
    [[ "$output" == *"not in the gamemode group"* ]]
    [[ "$output" == *"pulsar setup gamemode"* ]]
}

@test "doctor: a missing nice grant is reported as inert, not as unenrolled" {
    # Different cause, different fix: enrolling someone would not help.
    stub_gamemode_env "proto wheel gamemode" "proto wheel gamemode"
    rm -f "${PULSAR_LIMITS_DIR}/10-gamemode.conf"
    run gm_check
    [[ "$output" == warn* ]]
    [[ "$output" == *"nice grant"* ]]
    [[ "$output" == *inert* ]]
}

@test "doctor: a missing gamemode group is reported as inert" {
    export GM_GROUP_EXISTS=0
    stub_gamemode_env "proto wheel" "proto wheel"
    run gm_check
    [[ "$output" == warn* ]]
    [[ "$output" == *"no 'gamemode' group"* ]]
}

@test "doctor: renice=0 means membership is irrelevant and is not warned about" {
    stub_gamemode_env "proto wheel" "proto wheel"
    printf 'renice=0\n' > "$PULSAR_GAMEMODE_INI"
    run gm_check
    [[ "$output" == ok* ]]
    [[ "$output" == *"not requested"* ]]
}

@test "doctor: under sudo the human account is checked, not root" {
    # `sudo pulsar doctor` must not report that root is missing from the
    # gamemode group, which would be true and useless.
    stub_gamemode_env "proto wheel gamemode" "root"
    export SUDO_USER=proto
    run gm_check
    [[ "$output" == ok* ]]
}

@test "doctor: gamemode never fails the exit code, it only warns" {
    # Same severity rule as the scheduler: a missing priority is a performance
    # regression on a completely usable machine.
    stub_gamemode_env "proto wheel" "proto wheel"
    run gm_check
    [[ "$output" == warn* ]]
    # the warning is present, and the exit code is still clean
    run "$PULSAR" doctor --json
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# doctor: the MangoHud layer's pinned branch.
#
# flatpaks.list must pin a branch (a bare id is ambiguous on flathub), and a
# pin is a thing that rots: an extension is only visible to apps on the
# MATCHING runtime, so when the launcher moves branch and the pin does not,
# the overlay stops appearing and nothing anywhere logs a reason. This check
# is the only thing that would say so, which is why it is worth testing the
# difference between "already broken" and "about to break".
# ---------------------------------------------------------------------------

# $1 = extension branches installed, space separated ("" for none)
# $2 = the runtime branch Steam reports  ("" for no Steam at all)
# $3 = the branch flatpaks.list pins     ("" for no entry)
stub_mangohud() {
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    export EXT_BRANCHES="$1" STEAM_RUNTIME="$2"
    export PULSAR_FLATPAKS_LIST="${BATS_TEST_TMPDIR}/flatpaks.list"
    {
        printf '# a comment naming the id, which must not be parsed as an entry\n'
        printf '# org.freedesktop.Platform.VulkanLayer.MangoHud//99.99\n'
        printf 'com.valvesoftware.Steam\n'
        [ -n "$3" ] && printf 'org.freedesktop.Platform.VulkanLayer.MangoHud//%s\n' "$3"
    } > "$PULSAR_FLATPAKS_LIST"
    cat > "${STUB}/flatpak" <<'EOF'
#!/bin/sh
only_apps=0
for a in "$@"; do [ "$a" = "--app" ] && only_apps=1; done
if [ "$only_apps" = 1 ]; then
    [ -n "$STEAM_RUNTIME" ] && \
        printf 'com.valvesoftware.Steam\torg.freedesktop.Platform/x86_64/%s\n' "$STEAM_RUNTIME"
    printf 'com.github.tchx84.Flatseal\torg.freedesktop.Platform/x86_64/25.08\n'
    exit 0
fi
printf 'org.freedesktop.Platform\t25.08\n'
for b in $EXT_BRANCHES; do
    printf 'org.freedesktop.Platform.VulkanLayer.MangoHud\t%s\n' "$b"
done
exit 0
EOF
    chmod +x "${STUB}/flatpak"
    PATH="${STUB}:${PATH}"
    export PATH
}

mh_check() { "$PULSAR" doctor --json | jq -r '.checks[] | select(.id=="mangohud") | .status + " " + .summary + " " + .detail'; }

@test "doctor: mangohud layer matching Steam's runtime is ok" {
    stub_mangohud "25.08" "25.08" "25.08"
    run mh_check
    [[ "$output" == ok* ]]
    [[ "$output" == *"25.08 matches"* ]]
}

@test "doctor: a rotted pin is reported as invisible, with the branch to move to" {
    # The failure this check exists for: apps moved to 26.08, the layer is
    # still 25.08, the overlay silently stopped appearing.
    stub_mangohud "25.08" "26.08" "25.08"
    run mh_check
    [[ "$output" == warn* ]]
    [[ "$output" == *"Steam runs on 26.08"* ]]
    [[ "$output" == *"repin"* ]]
    [[ "$output" == *"26.08"* ]]
}

@test "doctor: a drifted pin still covered by an installed branch warns early" {
    # Both branches installed, so the overlay still works today -- but the
    # list pins the old one, and this is the window in which repinning is
    # free rather than a bug report.
    stub_mangohud "25.08 26.08" "26.08" "25.08"
    run mh_check
    [[ "$output" == warn* ]]
    [[ "$output" == *"pins //25.08"* ]]
    [[ "$output" == *"before the old branch goes"* ]]
}

@test "doctor: a missing layer names the command that installs it" {
    stub_mangohud "" "25.08" "25.08"
    run mh_check
    [[ "$output" == warn* ]]
    [[ "$output" == *"not installed"* ]]
    [[ "$output" == *"flatpak install flathub"* ]]
    [[ "$output" == *"//25.08"* ]]
}

@test "doctor: no Steam means there is nothing to be out of step with" {
    stub_mangohud "25.08" "" "25.08"
    run mh_check
    [[ "$output" == ok* ]]
    [[ "$output" == *"no Steam"* ]]
}

@test "doctor: a list with no MangoHud entry is not a finding" {
    stub_mangohud "" "25.08" ""
    run mh_check
    [[ "$output" == ok* ]]
    [[ "$output" == *"not in the defaults"* ]]
}

@test "doctor: a commented-out entry is not read as a pin" {
    # The fixture carries "# ...MangoHud//99.99" as a comment. Parsing it
    # would invent a pin nobody shipped and warn about a rot that is not real.
    stub_mangohud "25.08" "25.08" "25.08"
    run mh_check
    [[ "$output" != *"99.99"* ]]
    [[ "$output" == ok* ]]
}

@test "doctor: mangohud never fails the exit code, it only warns" {
    stub_mangohud "" "25.08" "25.08"
    run mh_check
    [[ "$output" == warn* ]]
    run "$PULSAR" doctor --json
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# doctor / flatpak-gl: running Flatpak apps against the NVIDIA driver.
#
# A Flatpak app mounts GL.nvidia-<driver version> once, at start. On
# 2026-09-26 Steam autostarted 16s before the new driver's extension landed,
# and an earlier in-place redeploy of the extension had deleted the files out
# from under the previous Steam. Both left games black on the iGPU with no
# error. The check reads flatpak's per-instance info file, which names the
# extension COMMIT each instance holds, and asks whether that commit is still
# deployed.
# ---------------------------------------------------------------------------

# $1 = installed runtimes, space separated
stub_gl() {
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    jq '.variant = "nvidia-open"' "$PULSAR_MANIFEST" > "${PULSAR_MANIFEST}.n" && mv "${PULSAR_MANIFEST}.n" "$PULSAR_MANIFEST"
    export PULSAR_NVIDIA_VERSION_FILE="${BATS_TEST_TMPDIR}/nvidia-version"
    printf '615.71.09\n' > "$PULSAR_NVIDIA_VERSION_FILE"
    # the module is loaded, in the fixture as in the version file: the real
    # /proc/modules is the host's, and the build host has no GPU
    export PULSAR_PROC_MODULES="${BATS_TEST_TMPDIR}/modules"
    printf 'nvidia 1 0 - Live 0x0\n' > "$PULSAR_PROC_MODULES"
    export PULSAR_FLATPAK_RUN="${BATS_TEST_TMPDIR}/run"
    export PULSAR_FLATPAK_ROOTS="${BATS_TEST_TMPDIR}/flatpak"
    export GL_RUNTIMES="$1"
    mkdir -p "$PULSAR_FLATPAK_RUN"
    : > "${BATS_TEST_TMPDIR}/ps"
    cat > "${STUB}/flatpak" <<EOF
#!/bin/sh
case "\$1" in
    list) printf '%s\n' \$GL_RUNTIMES ;;
    ps)   cat "${BATS_TEST_TMPDIR}/ps" ;;
esac
exit 0
EOF
    chmod +x "${STUB}/flatpak"
    PATH="${STUB}:${PATH}"
    export PATH
}

# deploy <GL|GL32> <commit>: the commit exists on disk
deploy() { mkdir -p "${PULSAR_FLATPAK_ROOTS}/runtime/org.freedesktop.Platform.$1.nvidia-615-71-09/x86_64/1.4/$2"; }

# instance <id> <app> <extensions...>: a running instance holding these
# name=commit extensions
instance() {
    local id=$1 app=$2; shift 2
    mkdir -p "${PULSAR_FLATPAK_RUN}/${id}"
    local IFS=';'
    printf '[Application]\nname=%s\n\n[Instance]\nruntime-extensions=%s\n' "$app" "$*" \
        > "${PULSAR_FLATPAK_RUN}/${id}/info"
    printf '%s\t%s\n' "$id" "$app" >> "${BATS_TEST_TMPDIR}/ps"
}

GL_DEF=org.freedesktop.Platform.GL.default=d1
GL32_DEF=org.freedesktop.Platform.GL32.default=d2
GL_NV=org.freedesktop.Platform.GL.nvidia-615-71-09
GL32_NV=org.freedesktop.Platform.GL32.nvidia-615-71-09

gl_check() { "$PULSAR" doctor --json | jq -r '.checks[] | select(.id=="flatpak-gl") | .status + " " + .summary + " " + .detail'; }

@test "doctor: an app holding the live extension is ok" {
    stub_gl "$GL_NV"
    deploy GL c1
    instance 1 com.discordapp.Discord "$GL_DEF" "${GL_NV}=c1"
    run gl_check
    [[ "$output" == ok* ]]
}

@test "REGRESSION: an app that started before the extension landed is stale" {
    stub_gl "$GL_NV"
    deploy GL c1
    instance 1 com.valvesoftware.Steam "$GL_DEF"
    run gl_check
    [[ "$output" == warn* ]]
    [[ "$output" == *"Steam started without the NVIDIA 615.71.09 driver"* ]]
    [[ "$output" == *"quit fully and reopen"* ]]
}

@test "REGRESSION: an app holding a redeployed-and-deleted commit is stale" {
    # Same directory name as the live extension, files gone: the 11:07 case.
    stub_gl "$GL_NV"
    deploy GL c2
    instance 1 com.valvesoftware.Steam "$GL_DEF" "${GL_NV}=c1"
    run gl_check
    [[ "$output" == warn* ]]
    [[ "$output" == *"Steam"* ]]
}

@test "doctor: a multiarch app is held to GL32 as well" {
    stub_gl "$GL_NV $GL32_NV"
    deploy GL c1
    instance 1 com.valvesoftware.Steam "$GL_DEF" "$GL32_DEF" "${GL_NV}=c1"
    run gl_check
    [[ "$output" == warn* ]]
    deploy GL32 c3
    instance 1 com.valvesoftware.Steam "$GL_DEF" "$GL32_DEF" "${GL_NV}=c1" "${GL32_NV}=c3"
    run gl_check
    [[ "$output" == ok* ]]
}

@test "doctor: an app with no GL extension point is not judged" {
    stub_gl "$GL_NV"
    instance 1 org.example.NoGL "org.fedoraproject.Platform.GL.default=x"
    run gl_check
    [[ "$output" == ok* ]]
}

@test "doctor: a missing extension names the unit that installs it" {
    stub_gl ""
    instance 1 com.valvesoftware.Steam "$GL_DEF"
    run gl_check
    [[ "$output" == warn* ]]
    [[ "$output" == *"missing or incomplete"* ]]
    [[ "$output" == *"pulsar-gl-nvidia.service"* ]]
}

@test "doctor: the vanilla image has no flatpak-gl finding at all" {
    stub_gl "$GL_NV"
    jq '.variant = "vanilla"' "$PULSAR_MANIFEST" > "${PULSAR_MANIFEST}.n" && mv "${PULSAR_MANIFEST}.n" "$PULSAR_MANIFEST"
    run gl_check
    [ -z "$output" ]
}

@test "doctor: flatpak-gl never fails the exit code, it only warns" {
    stub_gl "$GL_NV"
    instance 1 com.valvesoftware.Steam "$GL_DEF"
    run "$PULSAR" doctor --json
    [ "$status" -eq 0 ]
}

@test "doctor flatpak-gl --notify says so once per stale instance, and again for a new one" {
    stub_gl "$GL_NV"
    stub_notify
    deploy GL c1
    instance 111 com.valvesoftware.Steam "$GL_DEF"
    run "$PULSAR" doctor flatpak-gl --notify
    [ "$status" -eq 0 ]
    run "$PULSAR" doctor flatpak-gl --notify
    [ "$(wc -l < "$NOTIFY_LOG")" -eq 1 ]
    grep -q "Restart Steam" "$NOTIFY_LOG"
    # a second stale instance is news
    instance 222 com.valvesoftware.Steam "$GL_DEF"
    run "$PULSAR" doctor flatpak-gl --notify
    [ "$(wc -l < "$NOTIFY_LOG")" -eq 2 ]
}

@test "doctor flatpak-gl --notify stays quiet while the extension is still missing" {
    # Restarting before it lands would get a second Steam with the same
    # problem; the install touches flatpak's marker and the check runs again.
    stub_gl ""
    stub_notify
    instance 1 com.valvesoftware.Steam "$GL_DEF"
    run "$PULSAR" doctor flatpak-gl --notify
    [ "$status" -eq 0 ]
    [ ! -s "$NOTIFY_LOG" ]
}

@test "doctor flatpak-gl: GL32 still to land is missing, not a reason to restart" {
    # gl-nvidia.sh installs GL, then GL32 in a second transaction. Between
    # the two a restarted Steam would still lack GL32.
    stub_gl "$GL_NV"
    stub_notify
    deploy GL c1
    instance 1 com.valvesoftware.Steam "$GL_DEF" "$GL32_DEF" "${GL_NV}=c1"
    run "$PULSAR" doctor flatpak-gl --notify
    [[ "$output" == warn*"missing or incomplete"* ]]
    [ ! -s "$NOTIFY_LOG" ]
}

# ---------------------------------------------------------------------------
# doctor: reporting health it did not see.
# ---------------------------------------------------------------------------

stub_bin() {
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    cat > "${STUB}/$1"
    chmod +x "${STUB}/$1"
    PATH="${STUB}:${PATH}"
    export PATH
}

@test "doctor: a greenboot that has not run is not a green boot" {
    # Result=success is also what a unit that never ran reports.
    stub_bin systemctl <<'EOF'
#!/bin/sh
case "$*" in
    *is-enabled*greenboot*) echo enabled ;;
    *"-p Result"*greenboot*) echo success ;;
    *"-p ActiveState"*greenboot*) echo inactive ;;
    *) exit 1 ;;
esac
EOF
    run bash -c "'$PULSAR' doctor --json | jq -r '.checks[] | select(.id==\"greenboot\") | .status + \" \" + .summary'"
    [[ "$output" == warn* ]]
    [[ "$output" == *"not finished"* ]]
}

@test "doctor: a disabled greenboot says rollback is not armed" {
    stub_bin systemctl <<'EOF'
#!/bin/sh
case "$*" in *is-enabled*) echo disabled; exit 1 ;; esac
exit 1
EOF
    run bash -c "'$PULSAR' doctor --json | jq -r '.checks[] | select(.id==\"greenboot\") | .status + \" \" + .detail'"
    [[ "$output" == warn* ]]
    [[ "$output" == *"not armed"* ]]
}

@test "doctor: a failing flatpak still yields a whole json report" {
    stub_bin flatpak <<'EOF'
#!/bin/sh
exit 1
EOF
    run "$PULSAR" doctor --json
    echo "$output" | jq -e '.checks | length > 3'
}

@test "doctor: unreadable deployment status is a warning, not 'no update staged'" {
    stub_bin rpm-ostree <<'EOF'
#!/bin/sh
exit 1
EOF
    run bash -c "'$PULSAR' doctor --json | jq -r '.checks[] | select(.id==\"updates\") | .status + \" \" + .summary'"
    [[ "$output" == "warn could not read deployment status" ]]
}

@test "commands that take no arguments still answer --help" {
    run "$PULSAR" doctor --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"pulsar doctor"* ]]
}

# --- the nvidia image with no module loaded -------------------------------
# A missing module on a machine that HAS an NVIDIA GPU is a module Secure Boot
# rejected, and fails. On a machine with none it is the wrong image -- and it
# is every GPU-less VM the boot gate tests this image on, where a fail would
# hold back a release for being booted somewhere it cannot use its driver.

# $1 = one "vendor class" pair per device
pci_fixture() {
    export PULSAR_SYS_PCI="${BATS_TEST_TMPDIR}/pci"
    rm -rf "$PULSAR_SYS_PCI"; mkdir -p "$PULSAR_SYS_PCI"
    local i=0 v c
    while read -r v c; do
        [ -n "$v" ] || continue
        mkdir -p "$PULSAR_SYS_PCI/0000:00:0$i.0"
        echo "$v" > "$PULSAR_SYS_PCI/0000:00:0$i.0/vendor"
        echo "$c" > "$PULSAR_SYS_PCI/0000:00:0$i.0/class"
        i=$((i + 1))
    done <<<"$1"
}

no_module_nvidia_image() {
    jq '.variant = "nvidia-open"' "$PULSAR_MANIFEST" > "$PULSAR_MANIFEST.new" \
        && mv "$PULSAR_MANIFEST.new" "$PULSAR_MANIFEST"
    export PULSAR_PROC_MODULES="${BATS_TEST_TMPDIR}/modules"
    : > "$PULSAR_PROC_MODULES"
}

nvidia_status() { printf '%s' "$output" | jq -r '.checks[] | select(.id=="nvidia") | .status'; }

@test "doctor: an NVIDIA GPU with no module loaded fails" {
    no_module_nvidia_image
    pci_fixture $'0x8086 0x030000\n0x10de 0x030000'
    run "$PULSAR" doctor --json
    [ "$(nvidia_status)" = fail ]
}

@test "doctor: the nvidia image on a machine with no NVIDIA GPU warns, and says which image fits" {
    no_module_nvidia_image
    # an Intel iGPU and an NVIDIA device that is not a display (an audio
    # function on the same card is 0x0403)
    pci_fixture $'0x8086 0x030000\n0x10de 0x040300'
    run "$PULSAR" doctor --json
    [ "$(nvidia_status)" = warn ]
    [[ "$output" == *"no NVIDIA GPU"* ]]
    [[ "$output" == *"ghcr.io/arclight-digital/pulsar:latest"* ]]
}

@test "doctor: no readable PCI bus keeps the strict reading" {
    no_module_nvidia_image
    export PULSAR_SYS_PCI="${BATS_TEST_TMPDIR}/no-such-bus"
    run "$PULSAR" doctor --json
    [ "$(nvidia_status)" = fail ]
}

# --- GPU containers (CDI) --------------------------------------------------
# A CDI spec names every driver library by its full version, so one written
# for another driver resolves fine and then fails inside the container. What
# these pin down: doctor compares versions rather than checking existence,
# reads /etc/cdi (where hand-written, stale-prone specs live) as well as the
# tmpfs /var/run/cdi, and says nothing on an image that promised nothing.

stub_cdi() {   # stub_cdi <running driver> <spec driver, or "" for none> [sebool 0|1]
    jq '.variant = "nvidia-open"' "$PULSAR_MANIFEST" > "$PULSAR_MANIFEST.new" \
        && mv "$PULSAR_MANIFEST.new" "$PULSAR_MANIFEST"
    export PULSAR_NVIDIA_CTK="${BATS_TEST_TMPDIR}/nvidia-ctk"
    printf '#!/bin/sh\n' > "$PULSAR_NVIDIA_CTK"
    chmod +x "$PULSAR_NVIDIA_CTK"
    export PULSAR_NVIDIA_VERSION_FILE="${BATS_TEST_TMPDIR}/nvidia-version"
    printf '%s\n' "$1" > "$PULSAR_NVIDIA_VERSION_FILE"
    mkdir -p "${BATS_TEST_TMPDIR}/etc-cdi" "${BATS_TEST_TMPDIR}/run-cdi" "${BATS_TEST_TMPDIR}/booleans"
    export PULSAR_CDI_DIRS="${BATS_TEST_TMPDIR}/etc-cdi ${BATS_TEST_TMPDIR}/run-cdi"
    export PULSAR_SELINUX_BOOLEANS="${BATS_TEST_TMPDIR}/booleans"
    printf '%s %s\n' "${3:-1}" "${3:-1}" > "${PULSAR_SELINUX_BOOLEANS}/container_use_xserver_devices"
    if [ -n "$2" ]; then cdi_spec "${BATS_TEST_TMPDIR}/run-cdi/nvidia.yaml" "$2"; fi
}

cdi_spec() {   # cdi_spec <file> <driver version> -- the shape nvidia-ctk 1.20 writes
    cat > "$1" <<YAML
---
cdiVersion: 0.7.0
kind: nvidia.com/gpu
devices:
    - name: all
containerEdits:
    hooks:
        - hookName: createContainer
          path: /usr/bin/nvidia-cdi-hook
          args:
            - nvidia-cdi-hook
            - enable-cuda-compat
            - --host-driver-version=$2
    mounts:
        - hostPath: /usr/lib64/libcuda.so.$2
          containerPath: /usr/lib64/libcuda.so.$2
YAML
}

gpu_check() { "$PULSAR" doctor --json | jq -r '.checks[] | select(.id=="gpu-containers") | .status + " " + .summary + " " + .detail'; }

@test "doctor: a CDI spec for the running driver is ok and says how to use it" {
    stub_cdi 615.71.09 615.71.09
    run gpu_check
    [[ "$output" == ok* ]]
    [[ "$output" == *"matches driver 615.71.09"* ]]
    [[ "$output" == *"--device nvidia.com/gpu=all"* ]]
}

@test "doctor: a CDI spec for another driver is stale, and names the file" {
    stub_cdi 615.71.09 610.57.04
    run gpu_check
    [[ "$output" == warn* ]]
    [[ "$output" == *"stale"* ]]
    [[ "$output" == *"run-cdi/nvidia.yaml (610.57.04)"* ]]
}

@test "doctor: a hand-written /etc/cdi spec from an old driver is caught beside a fresh one" {
    # The real failure shape: the boot unit's /var/run/cdi spec is fine, and a
    # how-to's `nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` from two
    # drivers ago is still sitting in /etc.
    stub_cdi 615.71.09 615.71.09
    cdi_spec "${BATS_TEST_TMPDIR}/etc-cdi/nvidia.yaml" 595.58.03
    run gpu_check
    [[ "$output" == warn* ]]
    [[ "$output" == *"etc-cdi/nvidia.yaml (595.58.03)"* ]]
    [[ "$output" != *"run-cdi"* ]]
}

@test "doctor: the libcuda soname is enough when the compat hook is absent" {
    stub_cdi 615.71.09 ""
    printf 'kind: nvidia.com/gpu\nmounts:\n  - hostPath: /usr/lib64/libcuda.so.615.71.09\n' \
        > "${BATS_TEST_TMPDIR}/run-cdi/nvidia.yaml"
    run gpu_check
    [[ "$output" == ok* ]]
}

@test "doctor: a spec with no readable driver version is stale, not ok" {
    stub_cdi 615.71.09 ""
    printf 'kind: nvidia.com/gpu\n' > "${BATS_TEST_TMPDIR}/run-cdi/nvidia.yaml"
    run gpu_check
    [[ "$output" == warn* ]]
    [[ "$output" == *"no driver version"* ]]
}

@test "doctor: no CDI spec at all warns with the unit to restart" {
    stub_cdi 615.71.09 ""
    run gpu_check
    [[ "$output" == warn* ]]
    [[ "$output" == *"no CDI spec"* ]]
    [[ "$output" == *"nvidia-cdi-refresh.service"* ]]
}

@test "doctor: a non-nvidia CDI spec is not mistaken for the GPU one" {
    stub_cdi 615.71.09 ""
    printf 'cdiVersion: 0.7.0\nkind: example.com/fpga\n' > "${BATS_TEST_TMPDIR}/etc-cdi/fpga.yaml"
    run gpu_check
    [[ "$output" == *"no CDI spec"* ]]
}

@test "doctor: SELinux blocking container GPU access is reported even with a good spec" {
    # Measured on the reference laptop: with the boolean off, nvidia-smi in a
    # CDI container dies "Failed to initialize NVML: Insufficient Permissions".
    stub_cdi 615.71.09 615.71.09 0
    run gpu_check
    [[ "$output" == warn* ]]
    [[ "$output" == *"container_use_xserver_devices"* ]]
}

@test "doctor: the GPU container check only warns, never fails" {
    # Not asserted through the exit code: with variant=nvidia-open on a CI box
    # with no nvidia module, check_nvidia rightly FAILs. The claim is only
    # that this check never contributes a failure of its own.
    stub_cdi 615.71.09 610.57.04 0
    run "$PULSAR" doctor --json
    [ "$(printf '%s' "$output" | jq -r '.checks[] | select(.id=="gpu-containers") | .status')" = warn ]
}

@test "doctor: the GPU container check is silent on vanilla and on pre-toolkit images" {
    stub_cdi 615.71.09 ""
    jq '.variant = "vanilla"' "$PULSAR_MANIFEST" > "$PULSAR_MANIFEST.new" \
        && mv "$PULSAR_MANIFEST.new" "$PULSAR_MANIFEST"
    run gpu_check
    [ -z "$output" ]
    stub_cdi 615.71.09 ""
    rm -f "$PULSAR_NVIDIA_CTK"
    run gpu_check
    [ -z "$output" ]
}

@test "doctor: no loaded module leaves the GPU container check to check_nvidia" {
    stub_cdi "" ""
    run gpu_check
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# report.
#
# What is pinned is the privacy contract: bounded journal reads, redaction of
# the machine's and the user's identity, nothing from the environment. The
# journal stub hands back lines stuffed with exactly the things that must not
# survive, and records every argv it was given.
# ---------------------------------------------------------------------------
report_env() {
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    export JOURNAL_LOG="${BATS_TEST_TMPDIR}/journal.log"
    : > "$JOURNAL_LOG"
    export R_HOST R_USER R_HOME
    R_HOST=$(cat /proc/sys/kernel/hostname 2>/dev/null || echo somehost)
    R_USER=$(id -un)
    R_HOME=$HOME
    cat > "${STUB}/journalctl" <<'EOF'
#!/bin/sh
echo "$*" >> "$JOURNAL_LOG"
case " $* " in *" --user "*) unit=gamescale-reconcile.service; key=USER_UNIT ;; *) unit=broken.service; key=UNIT ;; esac
printf '{"__REALTIME_TIMESTAMP":"1790000000000000","%s":"%s","PRIORITY":"3","MESSAGE":"%s: failed for %s in %s/project token=hunter2 from 192.168.1.20 via aa:bb:cc:dd:ee:ff"}\n' \
    "$key" "$unit" "$R_HOST" "$R_USER" "$R_HOME"
EOF
    cat > "${STUB}/systemctl" <<'EOF'
#!/bin/sh
case " $* " in
    *" --failed "*)
        case " $* " in *" --user "*) echo "gamescale-reconcile.service loaded failed failed x" ;;
                       *) echo "broken.service loaded failed failed Broken" ;; esac ;;
    *" is-enabled "*) echo not-found; exit 1 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "${STUB}/journalctl" "${STUB}/systemctl"
    PATH="${STUB}:${PATH}"
    export PATH
    stub_ostree "$CHECK_STATUS"
}

@test "report is one JSON document with every section" {
    report_env
    run "$PULSAR" report
    [ "$status" -eq 0 ] || fail "$output"
    echo "$output" | jq -e '.report.schema == 1'
    for k in doctor status manifest units journal graphics flatpak; do
        echo "$output" | jq -e --arg k "$k" 'has($k)' >/dev/null || fail "no .${k}"
    done
    echo "$output" | jq -e '.units.failed_system == ["broken.service"]'
    echo "$output" | jq -e '.units.failed_user == ["gamescale-reconcile.service"]'
    echo "$output" | jq -e '.status.deployments[0].version == "44.1"'
    echo "$output" | jq -e '.journal.system.lines[0].unit == "broken.service"'
}

@test "report never reads the journal unbounded or outside the image's units" {
    report_env
    run "$PULSAR" report
    [ "$status" -eq 0 ]
    [ -s "$JOURNAL_LOG" ]
    while IFS= read -r line; do
        [[ "$line" == *"-n 50"* ]]       || fail "unbounded journal read: $line"
        [[ "$line" == *"-p warning"* ]]  || fail "not filtered by priority: $line"
        [[ "$line" == *" -b "* ]]        || fail "not limited to this boot: $line"
        [[ "$line" == *"pulsar-*"* ]]    || fail "no unit filter: $line"
    done < "$JOURNAL_LOG"
    grep -q -- '-u broken.service' "$JOURNAL_LOG"
    grep -q -- '--user-unit gamescale-reconcile.service' "$JOURNAL_LOG"
}

@test "report --lines bounds the journal, and is capped" {
    report_env
    run "$PULSAR" report --lines 7
    [ "$status" -eq 0 ]
    grep -q -- '-n 7' "$JOURNAL_LOG"
    run "$PULSAR" report --lines 100000
    [ "$status" -ne 0 ]
    run "$PULSAR" report --lines lots
    [ "$status" -ne 0 ]
}

@test "report redacts the hostname, the user, the home path and secrets" {
    report_env
    run "$PULSAR" report
    [ "$status" -eq 0 ]
    [[ "$output" != *"$R_HOST"* ]]  || fail "hostname leaked"
    [[ "$output" != *"$R_HOME"* ]]  || fail "home path leaked"
    [[ "$output" != *"hunter2"* ]]  || fail "token leaked"
    [[ "$output" != *"192.168.1.20"* ]] || fail "address leaked"
    [[ "$output" != *"aa:bb:cc:dd:ee:ff"* ]] || fail "MAC leaked"
    msg=$(echo "$output" | jq -r '.journal.system.lines[0].message')
    [[ "$msg" == *"<hostname>"* ]]
    [[ "$msg" == *"~/project"* ]]
    [[ "$msg" == *"token=<redacted>"* ]]
}

@test "report carries nothing from the environment" {
    report_env
    SOME_API_TOKEN=do-not-print-me-7f3a run "$PULSAR" report
    [ "$status" -eq 0 ]
    [[ "$output" != *"do-not-print-me-7f3a"* ]]
}

@test "report --text is for people, from the same data" {
    report_env
    run "$PULSAR" report --text
    [ "$status" -eq 0 ]
    [[ "$output" == *"failed units"* ]]
    [[ "$output" == *"broken.service"* ]]
    [[ "$output" != *"$R_HOST"* ]]
    [[ "$output" != "{"* ]]
}

@test "report --help says what is and is not included" {
    run "$PULSAR" report --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Not included"* ]]
    [[ "$output" == *"environment variables"* ]]
    [[ "$output" == *"Redacted"* ]]
}

@test "report still reports when a source is missing" {
    # no rpm-ostree: that section goes null, the rest stand
    report_env
    rm -f "${STUB}/rpm-ostree"
    run env PATH="${STUB}:/usr/bin:/bin" "$PULSAR" report
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.units.failed_system | length == 1'
}

# ---------------------------------------------------------------------------
# agent guide: the machine's own briefing for a coding agent. What is worth
# pinning is that it is there, that it says nothing false about this CLI, and
# that the image stays vendor-neutral.
# ---------------------------------------------------------------------------
REPO_AGENTS_MD="${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar/AGENTS.md"

@test "agent guide prints the guide the image ships" {
    PULSAR_AGENTS_MD="$REPO_AGENTS_MD" run "$PULSAR" agent guide
    [ "$status" -eq 0 ]
    [[ "$output" == *"pulsar doctor --json"* ]]
    [[ "$output" == *"toolbox run -c"* ]]
}

@test "agent guide fails honestly on an image without the guide" {
    PULSAR_AGENTS_MD="${BATS_TEST_TMPDIR}/nope.md" run "$PULSAR" agent guide
    [ "$status" -ne 0 ]
    [[ "$output" == *"no agent guide"* ]]
}

@test "the guide names only commands this CLI actually has" {
    # An agent will run what the guide says. Every `pulsar <verb>` in it must
    # be a verb main() dispatches, or the first thing it learns is wrong.
    local verbs v
    verbs=$(grep -o 'pulsar [a-z-]*' "$REPO_AGENTS_MD" | awk 'NF == 2 { print $2 }' | sort -u)
    [ -n "$verbs" ]
    for v in $verbs; do
        grep -qE "^        ${v}\)" "$PULSAR" || fail "AGENTS.md names 'pulsar ${v}', which main() does not dispatch"
    done
}

@test "no coding agent is installed or enabled by the image" {
    # Vendor-neutral is a property of the build, not of the prose: no agent's
    # package may appear in either Containerfile.
    run grep -nE 'claude-code|@openai/codex|gemini-cli|opencode-ai|aider-chat|copilot' \
        "${BATS_TEST_DIRNAME}/../Containerfile" "${BATS_TEST_DIRNAME}/../Containerfile.nvidia"
    [ "$status" -ne 0 ]
}


@test "--help lists report and agent" {
    run "$PULSAR" --help
    for v in "pulsar report" "pulsar agent"; do
        [[ "$output" == *"$v"* ]] || fail "usage() does not mention ${v}"
    done
}

@test "REGRESSION: report completes when there is no user bus" {
    # ssh, a bare TTY, a container: `systemctl --user` exits nonzero there,
    # and under pipefail that ended the whole report with no output at all.
    stub_bin systemctl <<'EOF'
#!/bin/sh
case "$*" in *--user*) exit 1 ;; esac
exit 0
EOF
    run "$PULSAR" report
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.units' >/dev/null
}

# ---------------------------------------------------------------------------
# agent add. The contract worth pinning is mostly about what does NOT
# happen: nothing is installed until an agent is named, nothing runs as root,
# nothing the user already has is replaced, and a vendor's own install is
# kept rather than refused. toolbox is stubbed and plays the box.
# ---------------------------------------------------------------------------
agent_env() {
    # agent add refuses root by design, and the build host runs the suite
    # as root: these are user-session tests
    [ "$(id -u)" -eq 0 ] && skip "agent add refuses root; these run as a user"
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "$HOME"
    unset XDG_DATA_HOME XDG_CONFIG_HOME CODEX_HOME
    export PULSAR_AGENTS_MD="$REPO_AGENTS_MD"
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    export TOOLBOX_LOG="${BATS_TEST_TMPDIR}/toolbox.log"
    export BOX_FLAG="${BATS_TEST_TMPDIR}/box-exists"
    export RUNTIME_FLAG="${BATS_TEST_TMPDIR}/runtime-exists"
    : > "$TOOLBOX_LOG"
    cat > "${STUB}/toolbox" <<'EOF'
#!/bin/bash
echo "toolbox $*" >> "$TOOLBOX_LOG"
fake_bin() { mkdir -p "$1"; printf '#!/bin/sh\necho "real %s $*"\n' "$2" > "$1/$2"; chmod +x "$1/$2"; }
case "$1" in
    list)
        printf 'CONTAINER ID  CONTAINER NAME  CREATED  STATUS  IMAGE NAME\n'
        [ -e "$BOX_FLAG" ] && printf 'c0ffee  agents  now  running  fedora-toolbox:44\n'
        exit 0 ;;
    --assumeyes) touch "$BOX_FLAG"; exit 0 ;;
    run)
        shift 3   # run -c <box>
        case "$1" in
            sh)   [ -e "$RUNTIME_FLAG" ] ;;
            sudo) touch "$RUNTIME_FLAG" ;;
            npm)
                prefix=""; last=""
                while [ $# -gt 0 ]; do
                    if [ "$1" = --prefix ]; then prefix=$2; shift; fi
                    last=$1; shift
                done
                case "$last" in
                    @anthropic-ai/claude-code*) b=claude ;;
                    @openai/codex*) b=codex ;;
                    @google/gemini-cli*) b=gemini ;;
                    opencode-ai*) b=opencode ;;
                    *) b=unknown ;;
                esac
                case "$*" in *uninstall*) exit 0 ;; esac
                fake_bin "$prefix/bin" "$b" ;;
            env)
                bindir=""
                for a in "$@"; do
                    case "$a" in UV_TOOL_BIN_DIR=*) bindir=${a#UV_TOOL_BIN_DIR=} ;; esac
                done
                if printf '%s\n' "$@" | grep -qx uv; then
                    [ -n "$bindir" ] && fake_bin "$bindir" aider
                    exit 0
                fi
                exec "$@" ;;
            *) exec "$@" ;;
        esac ;;
esac
EOF
    chmod +x "${STUB}/toolbox"
    # The shim hops to the host with flatpak-spawn when it runs inside a
    # container other than the agents box -- which is where these tests run
    # when bats itself is in a toolbox. Pass straight through to the stub.
    printf '#!/bin/sh\n[ "$1" = --host ] && shift\nexec "$@"\n' > "${STUB}/flatpak-spawn"
    chmod +x "${STUB}/flatpak-spawn"
    # A clean PATH, not the caller's: agent add looks for native installs
    # on PATH, and a developer's own ~/.local/bin/claude would otherwise be
    # found and every install test would see "already installed".
    PATH="${STUB}:/usr/bin:/bin"
    export PATH
}

@test "agent list shows every agent and installs nothing" {
    agent_env
    run "$PULSAR" agent list
    [ "$status" -eq 0 ]
    for n in claude codex gemini opencode aider; do [[ "$output" == *"$n"* ]]; done
    # the STATE column, not the prose under the table
    [ -z "$(echo "$output" | awk '$4 == "installed"')" ]
    [[ "$output" == *"none is installed by default"* ]]
    [ ! -s "$TOOLBOX_LOG" ]
}

@test "agent, bare, says what the machine gives an agent, in text and JSON" {
    agent_env
    # every gated action still silent: guard is off
    printf '#!/bin/sh\nexit 0\n' > "${STUB}/pkcheck"; chmod +x "${STUB}/pkcheck"
    run "$PULSAR" agent
    [ "$status" -eq 0 ]
    [[ "$output" == *"guide    ${REPO_AGENTS_MD}"* ]]
    [[ "$output" == *"none installed"* ]]
    [[ "$output" == *"guard    off"* ]]
    "$PULSAR" agent add claude >/dev/null
    printf '#!/bin/sh\nexit 2\n' > "${STUB}/pkcheck"
    run "$PULSAR" --json agent
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.guide.present == true
        and .agents == [{"name":"claude","command":"claude","install":"installed"}]
        and .guard == "on"'
}

@test "agent add carries no Microsoft-owned default" {
    agent_env
    run "$PULSAR" agent list
    [[ "$output" != *[Cc]opilot* ]]
    [[ "$output" != *GitHub* ]]
}

@test "agent add rejects an unknown agent and names the known ones" {
    agent_env
    run "$PULSAR" agent add definitely-not-an-agent
    [ "$status" -ne 0 ]
    [[ "$output" == *"known: claude codex gemini opencode aider"* ]]
    [ ! -s "$TOOLBOX_LOG" ]
}

@test "agent add refuses to run as root" {
    agent_env
    unshare -r true 2>/dev/null || skip "no unprivileged user namespaces"
    run unshare -r env "PATH=${PATH}" "HOME=${HOME}" "$PULSAR" agent add claude
    [ "$status" -ne 0 ]
    [[ "$output" == *"must not run as root"* ]]
    [ ! -s "$TOOLBOX_LOG" ]
}

@test "agent add creates the box, the runtime, the package and a shim" {
    agent_env
    run "$PULSAR" agent add claude
    [ "$status" -eq 0 ] || fail "$output"
    grep -q 'toolbox --assumeyes create agents' "$TOOLBOX_LOG"
    grep -q 'run -c agents sudo dnf install -y nodejs npm' "$TOOLBOX_LOG"
    # the vendor's npm package, into a prefix in $HOME -- never the box's /usr
    grep -q "run -c agents npm install -g --prefix ${HOME}/.local/share/pulsar/agents @anthropic-ai/claude-code@latest" "$TOOLBOX_LOG"
    shim="${HOME}/.local/bin/claude"
    [ -x "$shim" ]
    grep -qx '# pulsar-agent-shim' "$shim"
}

@test "the generated shim is clean POSIX sh" {
    # It is written by a heredoc full of escapes and parsed by /bin/sh long
    # after this CLI has exited, so it gets linted like any shipped script.
    command -v shellcheck >/dev/null || skip "shellcheck not installed"
    agent_env
    "$PULSAR" agent add claude >/dev/null
    "$PULSAR" agent add aider >/dev/null
    shellcheck -s sh "${HOME}/.local/bin/claude" "${HOME}/.local/bin/aider"
}

@test "the shim runs the agent in the box, with its arguments intact" {
    agent_env
    "$PULSAR" agent add codex >/dev/null
    : > "$TOOLBOX_LOG"
    run "${HOME}/.local/bin/codex" --version "two words"
    [ "$status" -eq 0 ]
    [[ "$output" == *"real codex --version two words"* ]]
    # Inside a container (CI in a toolbox) the shim runs the binary directly,
    # because toolbox cannot nest; on a host it must go through the box.
    if [ ! -e /run/.containerenv ]; then
        grep -q 'toolbox run -c agents env NPM_CONFIG_PREFIX=' "$TOOLBOX_LOG"
    fi
}

@test "a second agent reuses the box and the runtime" {
    agent_env
    "$PULSAR" agent add claude >/dev/null
    : > "$TOOLBOX_LOG"
    run "$PULSAR" agent add gemini
    [ "$status" -eq 0 ]
    run grep -E 'create|dnf install' "$TOOLBOX_LOG"
    [ "$status" -ne 0 ]
}

@test "a native install is supported: kept, not reinstalled, and given the guide" {
    # Claude Code's own install.sh puts its launcher at exactly this path, and
    # people install agents that way whatever the docs say.
    agent_env
    mkdir -p "${HOME}/.local/bin"
    printf '#!/bin/sh\necho mine\n' > "${HOME}/.local/bin/claude"
    run "$PULSAR" agent add claude
    [ "$status" -eq 0 ]
    [[ "$output" == *"already installed by its own installer"* ]]
    grep -qx 'echo mine' "${HOME}/.local/bin/claude"
    # the guide still lands where Claude Code reads it
    [ "$(readlink "${HOME}/.claude/rules/pulsar.md")" = "$REPO_AGENTS_MD" ]
    # and no box, runtime or second copy was touched
    [ ! -s "$TOOLBOX_LOG" ]
}

@test "--list marks a native install as native, with its path" {
    agent_env
    mkdir -p "${HOME}/.local/bin"
    printf '#!/bin/sh\necho mine\n' > "${HOME}/.local/bin/claude"
    run "$PULSAR" agent list
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude"*"native"* ]]
    [[ "$output" == *"${HOME}/.local/bin/claude"* ]]
}

@test "--remove on a native install takes back only the guide link" {
    agent_env
    mkdir -p "${HOME}/.local/bin"
    printf '#!/bin/sh\necho mine\n' > "${HOME}/.local/bin/claude"
    "$PULSAR" agent add claude >/dev/null
    run "$PULSAR" agent remove claude
    [ "$status" -eq 0 ]
    grep -qx 'echo mine' "${HOME}/.local/bin/claude"
    [ ! -e "${HOME}/.claude/rules/pulsar.md" ]
    [ ! -s "$TOOLBOX_LOG" ]
}

@test "the aider shim reads the guide whenever the image has it, not only at install" {
    agent_env
    export PULSAR_AGENTS_MD="${BATS_TEST_TMPDIR}/not-yet.md"
    "$PULSAR" agent add aider >/dev/null
    # written on an image without the guide ...
    grep -q -- "--read" "${HOME}/.local/bin/aider"
    # ... and passes it once the file exists
    cp "$REPO_AGENTS_MD" "$PULSAR_AGENTS_MD"
    run sh -c '. /dev/null; grep -n "set -- --read" "$1"' _ "${HOME}/.local/bin/aider"
    [ "$status" -eq 0 ]
}

@test "agent add links the machine guide where the agent reads it" {
    agent_env
    "$PULSAR" agent add claude >/dev/null
    "$PULSAR" agent add codex >/dev/null
    "$PULSAR" agent add opencode >/dev/null
    [ "$(readlink "${HOME}/.claude/rules/pulsar.md")" = "$REPO_AGENTS_MD" ]
    [ "$(readlink "${HOME}/.codex/AGENTS.md")" = "$REPO_AGENTS_MD" ]
    [ "$(readlink "${HOME}/.config/opencode/AGENTS.md")" = "$REPO_AGENTS_MD" ]
}

@test "agent add leaves an existing instructions file alone" {
    agent_env
    mkdir -p "${HOME}/.codex"
    printf 'my own rules\n' > "${HOME}/.codex/AGENTS.md"
    run "$PULSAR" agent add codex
    [ "$status" -eq 0 ]
    [[ "$output" == *"left alone"* ]]
    [ "$(cat "${HOME}/.codex/AGENTS.md")" = "my own rules" ]
}

@test "agent add aider installs through uv and reads the guide from its shim" {
    agent_env
    run "$PULSAR" agent add aider
    [ "$status" -eq 0 ] || fail "$output"
    grep -q 'sudo dnf install -y uv' "$TOOLBOX_LOG"
    grep -q "UV_TOOL_BIN_DIR=${HOME}/.local/share/pulsar/agents/bin UV_PYTHON_INSTALL_DIR=${HOME}/.local/share/pulsar/agents/python uv tool install --force --python python3.12 --with pip aider-chat@latest" "$TOOLBOX_LOG"
    grep -qF -- "--read '${REPO_AGENTS_MD}'" "${HOME}/.local/bin/aider"
}

@test "agent remove takes back what it made and nothing else" {
    agent_env
    "$PULSAR" agent add claude >/dev/null
    printf 'mine\n' > "${HOME}/.claude/rules/other.md"
    : > "$TOOLBOX_LOG"
    run "$PULSAR" agent remove claude
    [ "$status" -eq 0 ]
    [ ! -e "${HOME}/.local/bin/claude" ]
    [ ! -L "${HOME}/.claude/rules/pulsar.md" ]
    [ -e "${HOME}/.claude/rules/other.md" ]
    grep -q 'npm uninstall -g --prefix' "$TOOLBOX_LOG"
    [[ "$output" == *"left in place"* ]]
}

@test "agent remove leaves a foreign command at the shim path" {
    agent_env
    mkdir -p "${HOME}/.local/bin"
    printf 'mine\n' > "${HOME}/.local/bin/claude"
    run "$PULSAR" agent remove claude
    [ "$status" -eq 0 ]
    [ "$(cat "${HOME}/.local/bin/claude")" = mine ]
}

@test "setup --help lists the recipes, and a recipe's --help runs nothing" {
    run "$PULSAR" setup --help
    [[ "$output" == *"devbox"* ]]
    # before this, --help went straight into distrobox assemble
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "$bin"
    printf '#!/bin/sh\ntouch "%s/ran"\n' "$BATS_TEST_TMPDIR" > "${bin}/distrobox"; chmod +x "${bin}/distrobox"
    PATH="${bin}:${PATH}" run "$PULSAR" setup devbox --help
    [ "$status" -eq 0 ]
    [[ "$output" == "pulsar setup devbox"* ]]
    [ ! -e "${BATS_TEST_TMPDIR}/ran" ]
}

@test "report: a generic hostname like 'fedora' is not redacted out of image names" {
    PULSAR_REPORT_HOSTNAME=fedora run "$PULSAR" report
    [ "$status" -eq 0 ]
    [[ "$output" != *"<hostname>-silverblue"* ]]
    [[ "$output" != *"quay.io/<hostname>"* ]]
}

@test "report: a hostname is redacted as a whole name, never inside another word" {
    PULSAR_REPORT_HOSTNAME=pulsar-nvidia run "$PULSAR" report
    [ "$status" -eq 0 ]
    PULSAR_REPORT_HOSTNAME=nvidia run "$PULSAR" report
    [[ "$output" != *"pulsar-<hostname>"* ]]
}

@test "report: --lines with no value says so" {
    run "$PULSAR" report --lines
    [ "$status" -ne 0 ]
    [[ "$output" == *"--lines wants a number"* ]]
}

@test "the shim hops to the host from any container but the agents box" {
    # From the user's dev box, which shares $HOME but has no node or uv,
    # running the entry point directly died on its shebang.
    agent_env
    "$PULSAR" agent add claude >/dev/null
    grep -q 'name="agents"' "${HOME}/.local/bin/claude"
    grep -q 'exec flatpak-spawn --host toolbox run -c' "${HOME}/.local/bin/claude"
}

# ---------------------------------------------------------------------------
# doctor: the Pulsar code editor also ships a `pulsar` command.
# ---------------------------------------------------------------------------
cli_check() { "$PULSAR" doctor --json | jq -r '.checks[] | select(.id=="cli") | .status + " " + .summary'; }

@test "doctor: an editor's 'pulsar' earlier on PATH is a warning that names it" {
    local stub="${BATS_TEST_TMPDIR}/editorbin"
    mkdir -p "$stub"
    printf '#!/bin/sh\necho "Pulsar editor"\n' > "${stub}/pulsar"; chmod +x "${stub}/pulsar"
    export PULSAR_SYSTEM_CLI="$PULSAR"
    PATH="${stub}:${PATH}" run cli_check
    [[ "$output" == warn* ]]
    [[ "$output" == *"${stub}/pulsar"* ]]
}

@test "doctor: a /usr/bin/pulsar that is not ours fails" {
    local fake="${BATS_TEST_TMPDIR}/usr-bin-pulsar"
    printf '#!/bin/sh\necho "Pulsar editor"\n' > "$fake"; chmod +x "$fake"
    export PULSAR_SYSTEM_CLI="$fake"
    run cli_check
    [[ "$output" == fail* ]]
}

@test "doctor: our own CLI first on PATH is ok" {
    export PULSAR_SYSTEM_CLI="$PULSAR"
    PATH="$(dirname "$PULSAR"):${PATH}" run cli_check
    [[ "$output" == ok* ]]
}

# ---------------------------------------------------------------------------
# checkpoint.
#
# Run as root inside an unprivileged user namespace, against a fake /etc in
# the test's tmpdir, with rpm-ostree and ostree stubbed. What is pinned is the
# undo: changed and deleted files come back, added files are listed and left,
# a deployment staged since is discarded, and only the pin a checkpoint made
# is ever taken away.
# ---------------------------------------------------------------------------

# $1 = the rpm-ostree status JSON. Every non-status rpm-ostree call and every
# ostree call is logged, so a test can read back what was pinned or discarded.
checkpoint_stubs() {
    STUB="${BATS_TEST_TMPDIR}/stub"
    mkdir -p "$STUB"
    printf '%s' "$1" > "${BATS_TEST_TMPDIR}/status.json"
    cat > "${STUB}/rpm-ostree" <<EOF
#!/bin/sh
[ "\$1" = status ] && exec cat "${BATS_TEST_TMPDIR}/status.json"
echo "rpm-ostree \$*" >> "${OSTREE_LOG}"
EOF
    cat > "${STUB}/ostree" <<EOF
#!/bin/sh
echo "ostree \$*" >> "${OSTREE_LOG}"
EOF
    chmod +x "${STUB}/rpm-ostree" "${STUB}/ostree"
    case ":${PATH}:" in *":${STUB}:"*) ;; *) PATH="${STUB}:${PATH}"; export PATH ;; esac
}

checkpoint_env() {
    [ "$(id -u)" -eq 0 ] || unshare -r true 2>/dev/null || skip "no unprivileged user namespaces"
    export PULSAR_ETC="${BATS_TEST_TMPDIR}/etc"
    export PULSAR_CHECKPOINTS="${BATS_TEST_TMPDIR}/checkpoints"
    mkdir -p "${PULSAR_ETC}/ssh" "${PULSAR_ETC}/sudoers.d"
    printf 'PermitRootLogin no\n' > "${PULSAR_ETC}/ssh/sshd_config"
    printf 'keep me\n'            > "${PULSAR_ETC}/hosts"
    printf 'untouched\n'          > "${PULSAR_ETC}/motd"
    export OSTREE_LOG="${BATS_TEST_TMPDIR}/ostree.log"
    : > "$OSTREE_LOG"
    # booted is index 1: an update is already staged at 0
    checkpoint_stubs '{"deployments":[
        {"staged":true,"version":"44.2","checksum":"bbb"},
        {"booted":true,"version":"44.1","checksum":"aaa","pinned":false}]}'
}

# Already root: run it straight, as as_root does.
cp_root() {
    local ns=(unshare -r)
    [ "$(id -u)" -ne 0 ] || ns=()
    run "${ns[@]}" env "PATH=${PATH}" "PULSAR_ETC=${PULSAR_ETC}" \
        "PULSAR_CHECKPOINTS=${PULSAR_CHECKPOINTS}" "$PULSAR" checkpoint "$@"
}

latest_checkpoint() { find "$PULSAR_CHECKPOINTS" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | tail -1; }

@test "checkpoint refuses to run as a normal user" {
    [ "$(id -u)" -eq 0 ] && skip "running as root"
    run "$PULSAR" checkpoint
    [ "$status" -ne 0 ]
    [[ "$output" == *"root"* ]]
    # but its help needs no root
    run "$PULSAR" checkpoint --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"restore"* ]]
}

@test "checkpoint snapshots /etc and pins the BOOTED deployment, not index 0" {
    checkpoint_env
    cp_root "before the agent"
    [ "$status" -eq 0 ] || fail "$output"
    id=$(latest_checkpoint)
    [ -s "${PULSAR_CHECKPOINTS}/${id}/etc.tar" ]
    [ -s "${PULSAR_CHECKPOINTS}/${id}/etc.manifest" ]
    jq -e '.deployment.checksum == "aaa" and .pinned_by_checkpoint == true and .note == "before the agent"' \
        "${PULSAR_CHECKPOINTS}/${id}/meta.json"
    grep -qx 'ostree admin pin 1' "$OSTREE_LOG"
    [ "$(stat -c %a "${PULSAR_CHECKPOINTS}/${id}")" = 700 ]
}

@test "checkpoint diff names what changed, appeared and vanished in /etc" {
    checkpoint_env
    cp_root
    printf 'PermitRootLogin yes\n' > "${PULSAR_ETC}/ssh/sshd_config"
    printf 'ALL ALL=(ALL) NOPASSWD: ALL\n' > "${PULSAR_ETC}/sudoers.d/agent"
    rm "${PULSAR_ETC}/hosts"
    cp_root diff
    [ "$status" -eq 0 ] || fail "$output"
    [[ "$output" == *"changed  /etc/ssh/sshd_config"* ]]
    [[ "$output" == *"added  /etc/sudoers.d/agent"* ]]
    [[ "$output" == *"removed  /etc/hosts"* ]]
    [[ "$output" != *"motd"* ]]
}

@test "checkpoint restore puts back changed and deleted files, and lists added ones" {
    checkpoint_env
    cp_root
    printf 'PermitRootLogin yes\n' > "${PULSAR_ETC}/ssh/sshd_config"
    printf 'ALL ALL=(ALL) NOPASSWD: ALL\n' > "${PULSAR_ETC}/sudoers.d/agent"
    rm "${PULSAR_ETC}/hosts"
    cp_root restore "$(latest_checkpoint)"
    [ "$status" -eq 0 ] || fail "$output"
    [ "$(cat "${PULSAR_ETC}/ssh/sshd_config")" = "PermitRootLogin no" ]
    [ "$(cat "${PULSAR_ETC}/hosts")" = "keep me" ]
    # added since: listed, NOT deleted -- it may be the thing you wanted
    [ -e "${PULSAR_ETC}/sudoers.d/agent" ]
    [[ "$output" == *"left in place"*"/etc/sudoers.d/agent"* ]]
    cp_root diff "$(latest_checkpoint)"
    [[ "$output" != *"changed"* ]]
    [[ "$output" != *"removed"* ]]
}

@test "checkpoint restore discards a deployment staged since, and never reboots" {
    checkpoint_env
    # checkpoint taken with nothing staged...
    checkpoint_stubs '{"deployments":[{"booted":true,"version":"44.1","checksum":"aaa"}]}'
    cp_root
    id=$(latest_checkpoint)
    # ...then an agent layers a package
    checkpoint_stubs '{"deployments":[{"staged":true,"version":"44.1","checksum":"ccc"},
        {"booted":true,"version":"44.1","checksum":"aaa"}]}'
    cp_root diff "$id"
    [[ "$output" == *"staged since the checkpoint"* ]]
    cp_root restore "$id"
    [ "$status" -eq 0 ] || fail "$output"
    grep -q 'rpm-ostree cleanup --pending' "$OSTREE_LOG"
    run grep -i reboot "$OSTREE_LOG"
    [ "$status" -ne 0 ]
}

@test "checkpoint drop unpins only what the checkpoint pinned" {
    checkpoint_env
    cp_root
    cp_root drop "$(latest_checkpoint)"
    [ "$status" -eq 0 ] || fail "$output"
    grep -qx 'ostree admin pin --unpin 1' "$OSTREE_LOG"
    [ -z "$(latest_checkpoint)" ]

    # a deployment the user had already pinned stays pinned
    : > "$OSTREE_LOG"
    checkpoint_stubs '{"deployments":[{"booted":true,"version":"44.1","checksum":"aaa","pinned":true}]}'
    cp_root
    [[ "$output" == *"already pinned"* ]]
    cp_root drop "$(latest_checkpoint)"
    run grep -- '--unpin' "$OSTREE_LOG"
    [ "$status" -ne 0 ]
}

@test "checkpoint refuses an id that walks out of its directory" {
    checkpoint_env
    cp_root restore ../../etc
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a checkpoint id"* ]]
}

# ---------------------------------------------------------------------------
# agent guard. The rule itself is JavaScript polkit runs, so what is pinned
# here is the plumbing and the promises the rule's list makes: the actions
# the stock rules let through are gated, and updates are not.
# ---------------------------------------------------------------------------
REPO_GUARD_RULE="${BATS_TEST_DIRNAME}/../system_files/usr/share/pulsar/polkit/49-pulsar-guard.rules"

guard_env() {
    [ "$(id -u)" -eq 0 ] || unshare -r true 2>/dev/null || skip "no unprivileged user namespaces"
    export PULSAR_GUARD_RULE="$REPO_GUARD_RULE"
    export PULSAR_POLKIT_RULES_DIR="${BATS_TEST_TMPDIR}/rules.d"
}

guard_root() {
    local ns=(unshare -r)
    [ "$(id -u)" -ne 0 ] || ns=()
    run "${ns[@]}" env "PATH=${PATH}" "PULSAR_GUARD_RULE=${PULSAR_GUARD_RULE}" \
        "PULSAR_POLKIT_RULES_DIR=${PULSAR_POLKIT_RULES_DIR}" "$PULSAR" agent guard "$@"
}

@test "agent guard on and off refuse a normal user; its status and help need no root" {
    [ "$(id -u)" -eq 0 ] && skip "running as root"
    run "$PULSAR" agent guard on
    [ "$status" -ne 0 ]
    [[ "$output" == *"root"* ]]
    run "$PULSAR" agent guard off
    [ "$status" -ne 0 ]
    run "$PULSAR" agent guard --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"guard off"* ]]
}

@test "agent guard on installs the rule, once, and off takes it back" {
    guard_env
    guard_root on
    [ "$status" -eq 0 ] || fail "$output"
    cmp "$REPO_GUARD_RULE" "${PULSAR_POLKIT_RULES_DIR}/49-pulsar-guard.rules"
    [ "$(stat -c %a "${PULSAR_POLKIT_RULES_DIR}/49-pulsar-guard.rules")" = 644 ]
    guard_root on
    [ "$status" -eq 0 ]
    [[ "$output" == *"already on"* ]]
    guard_root off
    [ "$status" -eq 0 ] || fail "$output"
    [ ! -e "${PULSAR_POLKIT_RULES_DIR}/49-pulsar-guard.rules" ]
    guard_root off
    [ "$status" -eq 0 ]
    [[ "$output" == *"already off"* ]]
}

@test "agent guard never overwrites or removes a rule it did not write" {
    guard_env
    mkdir -p "$PULSAR_POLKIT_RULES_DIR"
    printf '// the admin'"'"'s own\n' > "${PULSAR_POLKIT_RULES_DIR}/49-pulsar-guard.rules"
    guard_root on
    [ "$status" -ne 0 ]
    [[ "$output" == *"not ours"* ]]
    guard_root off
    [ "$status" -ne 0 ]
    [ "$(cat "${PULSAR_POLKIT_RULES_DIR}/49-pulsar-guard.rules")" = "// the admin's own" ]
}

@test "agent guard, bare, reports what polkit answers" {
    [ "$(id -u)" -eq 0 ] && skip "running as root"
    local bin="${BATS_TEST_TMPDIR}/bin"; mkdir -p "$bin"
    # layering is still silent, Flatpak installs already ask
    cat > "${bin}/pkcheck" <<'SH'
#!/bin/sh
case "$2" in *Flatpak*) exit 2 ;; *) exit 0 ;; esac
SH
    chmod +x "${bin}/pkcheck"
    PATH="${bin}:${PATH}" run "$PULSAR" agent guard
    [ "$status" -eq 0 ]
    [[ "$output" == *"install-uninstall-packages"*"no prompt"* ]]
    [[ "$output" == *"Flatpak.app-install"*"asks for a password"* ]]
}

@test "the guard rule gates what the stock rules let through, and never updates" {
    local id
    for id in org.projectatomic.rpmostree1.install-uninstall-packages \
              org.projectatomic.rpmostree1.rollback \
              org.projectatomic.rpmostree1.cleanup \
              org.freedesktop.Flatpak.app-install org.freedesktop.Flatpak.runtime-install \
              org.freedesktop.Flatpak.app-uninstall org.freedesktop.Flatpak.runtime-uninstall; do
        grep -qF "\"${id}\"" "$REPO_GUARD_RULE" || fail "guard rule does not gate ${id}"
    done
    # GNOME Software's background updates go through these; gating them
    # would turn every update into a password prompt.
    for id in rpmostree1.upgrade rpmostree1.repo-refresh rpmostree1.client-management \
              Flatpak.app-update Flatpak.runtime-update Flatpak.appstream-update; do
        ! grep -qF "${id}\"" "$REPO_GUARD_RULE" || fail "guard rule gates ${id}"
    done
    # polkit merges /etc and /usr/share rules by file name; ours must sort
    # before the stock rules it overrides, or they answer YES first.
    [[ "49-pulsar-guard.rules" < "org.freedesktop.Flatpak.rules" ]]
    [[ "49-pulsar-guard.rules" < "org.projectatomic.rpmostree1.rules" ]]
    [[ "49-pulsar-guard.rules" < "empower.rules" ]]
    grep -qF "pulsar agent guard" "$REPO_GUARD_RULE"
}

# ---------------------------------------------------------------------------
# crashes: doctor's check, report --crash, the notification, and agent ask.
# coredumpctl is stubbed with what it prints for a real wireplumber abort;
# the agent is a native `claude` stub that records what it was started with.
# ---------------------------------------------------------------------------
crash_env() {
    agent_env
    export CRASH_LIST="${BATS_TEST_TMPDIR}/crashes.json"
    local me; me=$(id -u)
    # two wireplumber aborts and one foo segfault of ours, one crash of someone else's
    printf '[{"time":1,"pid":101,"uid":%s,"gid":%s,"sig":6,"corefile":"present","exe":"/usr/bin/wireplumber","size":5},
{"time":2,"pid":202,"uid":%s,"gid":%s,"sig":11,"corefile":"present","exe":"/usr/bin/foo","size":5},
{"time":3,"pid":303,"uid":4242,"gid":4242,"sig":11,"corefile":"present","exe":"/usr/bin/theirs","size":5},
{"time":4,"pid":404,"uid":%s,"gid":%s,"sig":6,"corefile":"present","exe":"/usr/bin/wireplumber","size":5}]' \
        "$me" "$me" "$me" "$me" "$me" "$me" > "$CRASH_LIST"
    cat > "${STUB}/coredumpctl" <<'SH'
#!/bin/sh
case "$*" in
    *list*) [ -s "$CRASH_LIST" ] || { echo "No coredumps found." >&2; exit 1; }; cat "$CRASH_LIST" ;;
    *info*) cat <<'INFO'
           PID: 404 (wireplumber)
           UID: 1000 (someone)
        Signal: 6 (ABRT)
     Timestamp: Sun 2026-09-27 13:16:10 MDT (2h 36min ago)
  Command Line: /usr/bin/wireplumber
    Executable: /usr/bin/wireplumber
     User Unit: wireplumber.service
       Package: wireplumber/0.5.17-1.fc44
       Message: Process 404 (wireplumber) of user 1000 dumped core.

                Module libdbus-1.so.3 from rpm dbus-1.16.0-1.fc44.x86_64
                Stack trace of thread 404:
                #0  0x00007f34cb7bfccc __pthread_kill_implementation (libc.so.6 + 0x74ccc)
                #1  0x00007f34bd360f37 dbus_bus_add_match (libdbus-1.so.3 + 0xff37)

                Stack trace of thread 405:
                #0  0x00007f34cb83f37d syscall (libc.so.6 + 0xf437d)
INFO
    ;;
esac
SH
    chmod +x "${STUB}/coredumpctl"
    printf '#!/bin/sh\nexit 0\n' > "${STUB}/journalctl"; chmod +x "${STUB}/journalctl"
    export NOTIFY_LOG="${BATS_TEST_TMPDIR}/notify.log" RUN_LOG="${BATS_TEST_TMPDIR}/run.log"
    : > "$NOTIFY_LOG"; : > "$RUN_LOG"
    printf '#!/bin/sh\necho "$*" >> "$NOTIFY_LOG"\n' > "${STUB}/notify-send"
    printf '#!/bin/sh\necho "$*" >> "$RUN_LOG"\n' > "${STUB}/systemd-run"
    chmod +x "${STUB}/notify-send" "${STUB}/systemd-run"
    export PULSAR_UPDATE_STATE="${BATS_TEST_TMPDIR}/state"
    export PULSAR_BOOT_ID_FILE="${BATS_TEST_TMPDIR}/boot_id"
    echo boot-a > "$PULSAR_BOOT_ID_FILE"
    export XDG_RUNTIME_DIR="${BATS_TEST_TMPDIR}/run"; mkdir -p "$XDG_RUNTIME_DIR"
    export AGENT_ARGS="${BATS_TEST_TMPDIR}/agent.args"
}

# a native install of $1 that records its argv, one argument per line
fake_agent() {
    printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "$AGENT_ARGS"\n' > "${STUB}/$1"
    chmod +x "${STUB}/$1"
}

@test "doctor crashes counts this user's crashes by program, never someone else's" {
    crash_env
    run "$PULSAR" doctor crashes
    [ "$status" -eq 0 ]
    [[ "$output" == warn*"3 crash(es) of yours this boot: wireplumber (2), foo"* ]]
    [[ "$output" != *theirs* ]]
    : > "$CRASH_LIST"
    run "$PULSAR" doctor crashes
    [[ "$output" == ok*"no crashes"* ]]
}

@test "report --crash carries the crashing thread, not the others, and no stale 'ago'" {
    crash_env
    run "$PULSAR" report --crash latest
    [ "$status" -eq 0 ] || fail "$output"
    echo "$output" | jq -e '.crash.executable == "/usr/bin/wireplumber"
        and .crash.unit == "wireplumber.service"
        and .crash.time == "Sun 2026-09-27 13:16:10 MDT"
        and (.crash.stack | length) == 2
        and (.crash.stack[1] | test("dbus_bus_add_match"))'
    run "$PULSAR" report --crash 999
    [ "$status" -ne 0 ]
    [[ "$output" == *"no crash of yours with PID 999"* ]]
    run "$PULSAR" report --crash 303
    [ "$status" -ne 0 ]
}

@test "crash notifications need an agent, and come once per program per boot" {
    crash_env
    run "$PULSAR" doctor crashes --notify
    [ "$status" -eq 0 ]
    [ ! -s "$RUN_LOG" ]
    fake_agent claude
    run "$PULSAR" doctor crashes --notify
    [ "$status" -eq 0 ]
    [ "$(grep -c "^--user" "$RUN_LOG")" -eq 2 ]
    # the newest wireplumber crash, its button, and the command the button runs
    grep -q -- "--unit=pulsar-crash-404 " "$RUN_LOG"
    grep -q "Ask Claude Code wireplumber crashed" "$RUN_LOG"
    grep -q "agent ask --crash 404$" "$RUN_LOG"
    grep -q "foo crashed" "$RUN_LOG"
    # a third wireplumber abort is not news; a new program is
    run "$PULSAR" doctor crashes --notify
    [ "$(grep -c "^--user" "$RUN_LOG")" -eq 2 ]
    jq '. + [{"time":5,"pid":505,"uid":'"$(id -u)"',"sig":11,"exe":"/usr/bin/bar"}]' "$CRASH_LIST" > "${CRASH_LIST}.n" && mv "${CRASH_LIST}.n" "$CRASH_LIST"
    run "$PULSAR" doctor crashes --notify
    [ "$(grep -c "^--user" "$RUN_LOG")" -eq 3 ]
    # after a reboot, the same program is news again
    echo boot-b > "$PULSAR_BOOT_ID_FILE"
    run "$PULSAR" doctor crashes --notify
    [ "$(grep -c "^--user" "$RUN_LOG")" -eq 6 ]
}

@test "agent ask starts the agent on a private report, with the crash and the rule" {
    crash_env
    fake_agent claude
    run "$PULSAR" agent ask --crash latest
    [ "$status" -eq 0 ] || fail "$output"
    [ "$(wc -l < "$AGENT_ARGS")" -eq 1 ]
    local prompt file
    prompt=$(cat "$AGENT_ARGS")
    [[ "$prompt" == *"wireplumber crashing (PID 404)"* ]]
    [[ "$prompt" == *"Do not change the system without asking me first."* ]]
    file=$(printf '%s' "$prompt" | grep -o "${XDG_RUNTIME_DIR}/pulsar/report-[0-9T]*\.json")
    [ "$(stat -c %a "$file")" = 600 ]
    jq -e '.crash.pid == 404' "$file"
    # a question replaces the default ask, and no crash means no crash section
    run "$PULSAR" agent ask why is my fan loud
    prompt=$(cat "$AGENT_ARGS")
    [[ "$prompt" == *"why is my fan loud"* ]]
    [[ "$prompt" != *crash* ]]
}

@test "agent ask hands each agent its prompt the way that agent takes one" {
    crash_env
    fake_agent gemini
    fake_agent aider
    run "$PULSAR" agent ask --with gemini hello
    [ "$(sed -n 1p "$AGENT_ARGS")" = -i ]
    run "$PULSAR" agent ask --with aider hello
    [ "$(sed -n 1p "$AGENT_ARGS")" = --read ]
    [[ "$output" == *"paste this into aider"*"hello"* ]]
}

@test "agent default: the only one installed, else the one chosen, else it asks" {
    crash_env
    run "$PULSAR" agent default
    [ "$status" -ne 0 ]
    fake_agent claude
    run "$PULSAR" agent default
    [ "$output" = claude ]
    fake_agent codex
    run "$PULSAR" agent ask hello
    [ "$status" -ne 0 ]
    [[ "$output" == *"which agent?"*"claude codex"* ]]
    run "$PULSAR" agent default codex
    [ "$status" -eq 0 ]
    run "$PULSAR" agent default
    [ "$output" = codex ]
    run "$PULSAR" agent default gemini
    [ "$status" -ne 0 ]
    [[ "$output" == *"not installed"* ]]
}
