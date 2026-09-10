#!/usr/bin/env bash
# Hand GNOME Software the cert that actually signed the nvidia module.
#
# GNOME Software's Secure Boot prompt is gnome-software-dkms-helper, and it
# is hardcoded to one path: /etc/pki/akmods/certs/public_key.der. It tests
# that cert against the MOK list, and when it is missing it shows the
# enrolment dialog and runs `mokutil --import` on it. That is the flow a
# user sees after anything clears the MOK list -- a BIOS update did exactly
# that on 2026-09-10 -- and it is the flow this image wants them to use.
#
# Phase 3 of Containerfile.nvidia deletes that file after signing, so on a
# Pulsar host the path is empty and akmods-keygen fills it on first boot
# with a freshly generated key. Nothing is ever signed with that key. The
# prompt enrols it anyway, reports success, and the driver still fails with
# "Loading of module with unavailable key is rejected".
#
# So this puts the real cert, /etc/pki/pulsar/MOK.der, at the path the
# helper reads, and parks a placeholder private key beside it so that
# akmods-keygen (ConditionFileNotEmpty on either file) never generates a
# decoy pair again. It runs at image build, so a fresh install ships it in
# /usr/etc, and again at every boot, because the ostree /etc merge keeps a
# locally created file over the image's copy and a host that already has
# the decoy would otherwise keep it forever.
#
# A private key that is not the placeholder is replaced too. It was never
# used: signing happens on the signer host at image build, never here. With
# the real cert beside a stray key, a local akmodsbuild would sign with a
# key the cert does not match and produce a module that fails to load; with
# the placeholder, sign-file fails the build instead. Loud beats silent.
#
# Environment (for tests): PULSAR_MOK, PULSAR_AKMODS_DIR.
set -euo pipefail

mok="${PULSAR_MOK:-/etc/pki/pulsar/MOK.der}"
dir="${PULSAR_AKMODS_DIR:-/etc/pki/akmods}"
pub="${dir}/certs/public_key.der"
priv="${dir}/private/private_key.priv"
placeholder='placeholder: the private key lives on the signer host, never here.'

if [ ! -s "$mok" ]; then
    echo "akmods-cert: FATAL: ${mok} is missing or empty; nothing to hand GNOME Software" >&2
    exit 1
fi

mkdir -p "${dir}/certs" "${dir}/private"

if cmp -s "$mok" "$pub"; then
    echo "akmods-cert: ${pub} already is ${mok}"
else
    if [ -e "$pub" ]; then
        echo "akmods-cert: replacing ${pub}; it is not the cert that signed the nvidia module"
    fi
    install -m 0444 "$mok" "${pub}.tmp"
    mv -f "${pub}.tmp" "$pub"
    echo "akmods-cert: installed ${mok} at ${pub}"
fi

if [ -s "$priv" ] && [ "$(cat "$priv")" = "$placeholder" ]; then
    :
else
    if [ -e "$priv" ]; then
        echo "akmods-cert: replacing ${priv} with the placeholder; nothing on this host signs modules"
    fi
    (umask 077; printf '%s\n' "$placeholder" > "${priv}.tmp")
    mv -f "${priv}.tmp" "$priv"
    chmod 0400 "$priv"
fi
