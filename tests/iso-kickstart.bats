#!/usr/bin/env bats
# The installer must ask before it erases a disk.
#
# The ISOs published on 2026-08-10 did not. Booted, they went straight to
# partitioning with no disk picker and no prompt, because bootc-image-builder
# writes a fully automated kickstart whenever nothing supplies one of its own.
# Read out of pulsar-latest-x86_64.iso, the shipped osbuild.ks and its included
# osbuild-base.ks contained:
#
#   clearpart --all
#   autopart --nohome --type=btrfs
#   reboot --eject
#
# clearpart --all with no --drives= is every attached disk. The failure that
# surfaced it was a Ventoy stick that stopped being bootable: Ventoy loop-mounts
# the ISO, so Anaconda never recognises the USB as its own install source and
# never protects it, and the stick's boot partition went with everything else.
#
# The subtlety worth encoding in a test is that installer.unattended does NOT
# control this. For a bootc container payload, bootcInstallerKickstartStages()
# in osbuild/images branches only on whether kickstart CONTENTS were supplied,
# and setting unattended = false changes nothing at all. So the only thing
# standing between this repo and that ISO is iso-config.toml existing and
# reaching bib -- which is exactly what these three tests hold down.
#
# The harness is stubs on PATH, the idiom build-tags.bats and
# nightly-base-gate.bats use: no podman, no skopeo, no registry, no ISO.

bats_require_minimum_version 1.5.0

DIGEST='sha256:1111111111111111111111111111111111111111111111111111111111111111'

setup() {
  # Same reason as build-tags.bats: the builder exports PULSAR_* into the
  # environment a hand-run build inherits, and build-iso.sh reads four of them.
  for v in "${!PULSAR_@}"; do unset "${v}"; done

  # Resolved the same way build-iso.sh resolves its own REPO, because the
  # mount argument is compared as a STRING and "tests/.." would never match.
  REPO="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  ISO="${REPO}/scripts/build-iso.sh"
  CONFIG="${REPO}/iso-config.toml"
  BIN="${BATS_TEST_TMPDIR}/bin"
  WORK="${BATS_TEST_TMPDIR}/work"
  ARGV="${BATS_TEST_TMPDIR}/podman-run.argv"
  mkdir -p "${BIN}" "${WORK}"
  PATH="${BIN}:${PATH}"
  stub_tools
}

# Everything build-iso.sh probes for, stubbed as a SET so the path through the
# script is identical on a workstation, in a toolbox and on the build host --
# otherwise a run stops at whichever tool happens to be missing locally. jq and
# sha256sum are deliberately NOT stubbed: the script parses real JSON and
# checksums a real file, and stubbing those would test the stubs.
stub_tools() {
  # `id -u` must answer 0 or the script refuses before doing anything. Only
  # that one question is answered here; anything else defers to the real id,
  # because bats itself calls it.
  cat > "${BIN}/id" <<EOF
#!/usr/bin/env bash
[ "\$1" = -u ] && { echo 0; exit 0; }
exec /usr/bin/id "\$@"
EOF

  # podman answers the graphroot probe, swallows the pull, and records the
  # argv of the bib run -- which is the whole point of the exercise. It also
  # has to leave an ISO behind, or the script dies on "no ISO was produced"
  # before it reaches the code that names and signs one.
  cat > "${BIN}/podman" <<EOF
#!/usr/bin/env bash
case "\$1" in
  info) echo /var/lib/containers/storage ;;
  pull) exit 0 ;;
  run)
    printf '%s\n' "\$@" > "${ARGV}"
    mkdir -p "${WORK}/iso"
    : > "${WORK}/iso/install.iso"
    ;;
esac
exit 0
EOF

  # The version label matters: build-iso.sh refuses an image without one,
  # because an ISO with no version cannot be named.
  cat > "${BIN}/skopeo" <<EOF
#!/usr/bin/env bash
cat <<JSON
{"Digest": "${DIGEST}",
 "Labels": {"org.opencontainers.image.version": "44.20260817.0"}}
JSON
EOF

  # --keyless is what these tests pass, so cosign only has to not exist as a
  # missing tool. The signature it would write is never read back on that path.
  printf '#!/usr/bin/env bash\nexit 0\n' > "${BIN}/cosign"

  chmod +x "${BIN}"/id "${BIN}"/podman "${BIN}"/skopeo "${BIN}"/cosign
}

build() {
  run -0 "${ISO}" \
    --variant vanilla \
    --image ghcr.io/arclight-digital/pulsar \
    --work "${WORK}" \
    --keyless
}

@test "the bib run mounts iso-config.toml and passes it as --config" {
  build

  # Both halves, because either one alone is silently useless: the flag
  # without the mount is a bib error, and the mount without the flag is the
  # unattended kickstart again with no sign anything was wrong.
  grep -Fxq -- '--config' "${ARGV}"
  grep -Fxq -- '/config.toml' "${ARGV}"
  # The RENDERED copy, not the repo file: build-iso.sh fills in the ref the
  # installed system tracks, so what bib reads lives in the work dir.
  grep -Fq -- "${WORK}/iso-config.toml:/config.toml:ro" "${ARGV}"

  # The mount target's EXTENSION is load-bearing -- bib picks its decoder from
  # it, and a .toml file mounted under any other name is parsed as JSON.
  grep -Fq -- ':/config.toml:' "${ARGV}"

  # --rootfs still has to be there. It no longer decides the installed layout
  # once the hardcoded autopart is gone, but it is what satisfies bib's "no
  # default root filesystem type specified in container" check.
  grep -Fxq -- '--rootfs' "${ARGV}"
}

@test "the supplied kickstart carries no clearpart, autopart or reboot" {
  # The assertion the incident actually calls for. Anchored to the start of a
  # line so the prose in iso-config.toml -- which names all three directives
  # while explaining their absence -- cannot satisfy or trip it.
  local directive
  for directive in clearpart autopart reboot rootpw; do
    if grep -Eq "^[[:space:]]*${directive}([[:space:]]|\$)" "${CONFIG}"; then
      echo "iso-config.toml supplies a bare '${directive}' directive;" >&2
      echo "that is the behaviour this file exists to remove" >&2
      return 1
    fi
  done

  # And the converse, so an empty or truncated file cannot pass the loop above
  # by containing nothing at all.
  grep -Eq '^[[:space:]]*network --device=link' "${CONFIG}"
  grep -Eq '^volume_id = ' "${CONFIG}"
}

@test "a missing iso-config.toml stops the build before it starts one" {
  # build-iso.sh derives REPO from its own location, so a copy under a bare
  # directory is a repo with no config in it.
  local fake="${BATS_TEST_TMPDIR}/fakerepo"
  mkdir -p "${fake}/scripts"
  cp "${ISO}" "${fake}/scripts/build-iso.sh"

  run "${fake}/scripts/build-iso.sh" \
    --variant vanilla \
    --image ghcr.io/arclight-digital/pulsar \
    --work "${WORK}" \
    --keyless

  [ "${status}" -eq 2 ]
  [[ "${output}" == *"erases every attached disk"* ]]

  # Refusing late would still cost a multi-gigabyte build and leave an ISO on
  # disk that nobody should boot. The guard has to fire before bib runs.
  [ ! -f "${ARGV}" ]
}

# ---------------------------------------------------------------------------
# The installed system has to FOLLOW the image. bib's own %post switches it
# onto the exact ref bib was given, and build-iso.sh gives bib a digest, so
# every ISO before 2026-09-25 installed a machine whose origin was
# ghcr.io/...@sha256:... -- `pulsar update` re-pulled the same image forever.
# iso-config.toml carries a second %post that points it back at a tag, with a
# placeholder only build-iso.sh knows how to fill.
# ---------------------------------------------------------------------------

@test "REGRESSION: the kickstart bib reads points installs at the tag, not the digest" {
  build
  local rendered="${WORK}/iso-config.toml"
  grep -Fxq -- 'bootc switch --mutate-in-place --transport registry ghcr.io/arclight-digital/pulsar:latest' "${rendered}"
  ! grep -q '@PULSAR_TRACK_IMGREF@' "${rendered}"
  # Only the command lines: the prose above them quotes the old digest origin.
  ! grep -E '^bootc switch .*@sha256' "${rendered}"
}

@test "the tracking %post is after bib's switch and fails the install loudly" {
  # bib %includes its own kickstart at the TOP of ours, so anything in the
  # contents runs after its `bootc switch` onto the digest -- which is the
  # only order in which a second switch means anything.
  grep -Fxq -- '%post --erroronfail' "${CONFIG}"
}

@test "--track changes what installs follow, not what the ISO installs" {
  run -0 "${ISO}" --variant vanilla --image ghcr.io/arclight-digital/pulsar \
    --work "${WORK}" --keyless --track testing
  grep -Fxq -- 'bootc switch --mutate-in-place --transport registry ghcr.io/arclight-digital/pulsar:testing' "${WORK}/iso-config.toml"
  grep -Fxq -- "ghcr.io/arclight-digital/pulsar@${DIGEST}" "${ARGV}"
}

@test "--track refuses a reference, which would pin installs all over again" {
  run -2 "${ISO}" --variant vanilla --image ghcr.io/arclight-digital/pulsar \
    --work "${WORK}" --keyless --track "latest@${DIGEST}"
  [[ "$output" == *"bare tag"* ]]
  [ ! -e "${ARGV}" ]
}

@test "the sidecar records the ref installs will follow" {
  build
  local sidecar
  sidecar="$(find "${WORK}/iso" -name '*.json' | head -1)"
  [ "$(jq -r .tracks "${sidecar}")" = ghcr.io/arclight-digital/pulsar:latest ]
  [ "$(jq -r .digest "${sidecar}")" = "${DIGEST}" ]
}
