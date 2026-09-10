#!/usr/bin/env bats
# Tests for scripts/akmods-cert.sh.
#
# The bug these exist for: GNOME Software's Secure Boot prompt enrols
# /etc/pki/akmods/certs/public_key.der, and on a Pulsar host that file was a
# key akmods-keygen generated locally, not the one that signed the nvidia
# module. On 2026-09-10 a BIOS update cleared the MOK list, the prompt
# appeared, the user went through it exactly as designed, it reported
# success, and the driver stayed rejected. The decisions pinned here: the
# real cert lands at that path on a fresh host, a decoy already there is
# replaced (both halves), a correct file is left alone, and a missing MOK.der
# is a loud failure that touches nothing.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/akmods-cert.sh"

    export PULSAR_MOK="${BATS_TEST_TMPDIR}/MOK.der"
    export PULSAR_AKMODS_DIR="${BATS_TEST_TMPDIR}/akmods"
    PUB="${PULSAR_AKMODS_DIR}/certs/public_key.der"
    PRIV="${PULSAR_AKMODS_DIR}/private/private_key.priv"

    printf 'the cert that signed the module\n' > "$PULSAR_MOK"
}

seed_decoy() {
    mkdir -p "${PULSAR_AKMODS_DIR}/certs" "${PULSAR_AKMODS_DIR}/private"
    printf 'decoy public key from akmods-keygen\n' > "$PUB"
    printf 'decoy private key from akmods-keygen\n' > "$PRIV"
}

@test "fresh host: the real cert and a placeholder private key land" {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    cmp -s "$PULSAR_MOK" "$PUB"
    [ "$(stat -c %a "$PUB")" = "444" ]
    [ -s "$PRIV" ]
    grep -q '^placeholder:' "$PRIV"
    [ "$(stat -c %a "$PRIV")" = "400" ]
}

@test "a decoy pair is replaced, both halves, and says so" {
    seed_decoy
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    cmp -s "$PULSAR_MOK" "$PUB"
    ! grep -q decoy "$PRIV"
    grep -q '^placeholder:' "$PRIV"
    [[ "$output" == *"replacing ${PUB}"* ]]
    [[ "$output" == *"replacing ${PRIV}"* ]]
}

@test "a correct pair is left untouched on the second run" {
    "$SCRIPT"
    pub_inode=$(stat -c %i "$PUB")
    priv_inode=$(stat -c %i "$PRIV")
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(stat -c %i "$PUB")" = "$pub_inode" ]
    [ "$(stat -c %i "$PRIV")" = "$priv_inode" ]
    [[ "$output" == *"already is"* ]]
    [[ "$output" != *"replacing"* ]]
}

@test "only the half that drifted is rewritten" {
    "$SCRIPT"
    pub_inode=$(stat -c %i "$PUB")
    printf 'decoy private key from akmods-keygen\n' > "$PRIV"
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(stat -c %i "$PUB")" = "$pub_inode" ]
    grep -q '^placeholder:' "$PRIV"
}

@test "a missing MOK.der fails loudly and touches nothing" {
    seed_decoy
    rm "$PULSAR_MOK"
    run "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *FATAL* ]]
    grep -q decoy "$PUB"
    grep -q decoy "$PRIV"
}
