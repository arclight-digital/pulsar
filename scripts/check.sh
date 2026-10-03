#!/usr/bin/env bash
# Every cheap check in one place, run before anything expensive.
#
# This was .github/workflows/cli.yml until the repo left Actions. The checks
# are the same; what changed is when they run. There is no on-push CI any
# more, so the build host runs this at the top of every nightly and every
# weekly ISO build -- a syntax error that reaches main becomes a loudly
# failed build the same evening, not a latent surprise. Run it yourself
# before pushing; it is the same ~40 seconds it was on a runner.
#
# One honest regression from the Actions era: cli.yml ran on Ubuntu
# DELIBERATELY, because a jq object-value parse error once shipped to main
# when every local test ran on Fedora, whose jq was new enough to accept it.
# The build host is Fedora, so that older-toolchain canary is gone. If the
# CLI grows another dependency with version-sensitive syntax, test it against
# the oldest toolchain a user might run it on.
#
# Requires: shellcheck, bats, jq, xmllint (libxml2), python3.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

for tool in shellcheck bats jq xmllint python3; do
  command -v "${tool}" >/dev/null || { echo "missing: ${tool}" >&2; exit 2; }
done

say() { printf '\n==> %s\n' "$*"; }

# Every shell artifact in the repo, not just the CLI. The sbom/changelog
# scripts run both in the build and on user machines.
say "shellcheck"
shellcheck \
  cli/pulsar \
  scripts/akmods-cert.sh \
  scripts/alive-timeout.sh \
  scripts/build-iso.sh \
  scripts/build.sh \
  scripts/check-scx-btf.sh \
  scripts/check.sh \
  scripts/diff-chunk-metadata.sh \
  scripts/flatpak-defaults.sh \
  scripts/gamemode-group.sh \
  scripts/gg \
  scripts/ggm \
  scripts/gl-nvidia.sh \
  scripts/lint-containerfile.sh \
  scripts/next-version.sh \
  scripts/nightly.sh \
  scripts/publish.sh \
  scripts/rechunk-selftest.sh \
  scripts/root-check.sh \
  scripts/rpm-sbom.sh \
  scripts/sbom-changelog.sh \
  scripts/sign-file-oracle \
  scripts/steam-gpu-watch.sh \
  scripts/sync-branding.sh \
  scripts/theme-test-image.sh \
  scripts/weekly.sh \
  tests/theme-gate/gate.sh \
  tests/theme-gate/run.sh \
  tests/theme-gate/session.sh \
  tests/theme-gate/bin/systemd-run
echo "shellcheck: clean"

# The signer holds the Secure Boot key, so a syntax error in it is a nightly
# that cannot sign. Compile-checking is the cheap half; the behaviour is
# covered by the shim's own end-to-end run.
say "compile-check the signer"
python3 -m py_compile scripts/pulsar-signer.py
echo "pulsar-signer: compiles"

# The theme engine runs at every first login, and a syntax error there is a
# desktop that stays stock forever (the unit fails, the stamp is never
# written, it fails again next login). The rest are build and gate tooling.
say "compile-check the theme engine and its tooling"
for f in scripts/pulsar-theme scripts/pulsar-theme-picker scripts/pulsar_theme_engine.py scripts/build-themes.py \
         scripts/render-theme-wallpapers.py tests/theme-gate/scenario.py \
         tests/theme-gate/fixtures/notes.py; do
  python3 - "$f" <<'PY'
import sys
compile(open(sys.argv[1]).read(), sys.argv[1], "exec")
PY
done
echo "theme engine: compiles"

# The shell inside RUN instructions is shell too, and it is the most
# expensive place to have a syntax error: a quote left open by a missing
# line continuation costs a full image build to discover, which is exactly
# how it reached main once.
say "shellcheck the Containerfile RUN bodies"
./scripts/lint-containerfile.sh Containerfile Containerfile.nvidia

# The greenboot health checks are shipped shell too, and a syntax error in
# one of them is a red boot on every machine that pulls the image.
say "shellcheck the greenboot checks"
shellcheck system_files/usr/lib/greenboot/check/*/*.sh
echo "greenboot checks: clean"

# A malformed XML file fails SILENTLY at the consumer. A stray double hyphen
# inside a comment in pulsar.xml made gnome-control-center drop the file
# whole, so the Appearance panel showed no Pulsar wallpapers while all eight
# PNGs sat correctly installed -- and nothing anywhere logged a reason. SVGs
# are XML too, and a broken mark is just a missing icon.
say "XML and SVG are well-formed"
n=0
while read -r f; do
  xmllint --noout "$f"
  n=$((n + 1))
done < <(find system_files system_files.nvidia assets \
           -type f \( -name '*.xml' -o -name '*.svg' \) 2>/dev/null)
echo "xmllint: ${n} file(s) well-formed"

say "bats"
# in parallel where GNU parallel is (one job per core): about 40 s, not 4 min
jobs=()
command -v parallel >/dev/null && jobs=(--jobs "$(nproc)")
bats "${jobs[@]}" tests/

# The installer's disk tests (Windows' partitions untouched, the root
# encrypted, a failed install taken back) skip where systemd-repart,
# cryptsetup and the mkfs tools are missing -- which a bare build host may
# be, every night, and a safety test that skips every night guards nothing.
# So where any is missing they run again here, in a Fedora container that
# has them; with neither the tools nor podman, this fails rather than pass
# on skips.
say "installer disk tests, with the disk tools"
disk_tools_missing=""
for t in systemd-repart cryptsetup sfdisk mkfs.btrfs mkfs.vfat mkfs.ext4; do
  command -v "$t" >/dev/null || disk_tools_missing+=" $t"
done
if [ -z "$disk_tools_missing" ]; then
  echo "this host has them: run above"
elif command -v podman >/dev/null; then
  echo "missing here:${disk_tools_missing}; running them in a container"
  disk_out=$(podman run --rm -v "${REPO}:/opt/pulsar:ro,Z" registry.fedoraproject.org/fedora:44 bash -c '
    dnf5 install -y -q bats python3 util-linux systemd-repart cryptsetup btrfs-progs dosfstools e2fsprogs >/dev/null &&
    cd /opt/pulsar && TMPDIR=/var/tmp bats tests/install-disk.bats tests/esp-fallback.bats' 2>&1) \
    || { printf '%s\n' "$disk_out"; echo "FAIL: installer disk tests" >&2; exit 1; }
  printf '%s\n' "$disk_out"
  if grep -q "# skip needs" <<<"$disk_out"; then
    echo "FAIL: installer disk tests skipped even with the tools installed" >&2
    exit 1
  fi
else
  echo "FAIL: the installer's disk tests need${disk_tools_missing}, or podman to run them in a container" >&2
  exit 1
fi

# The CLI must behave on a machine that is not a Pulsar system: no bootc, no
# rpm-ostree, no sched_ext. Asserted rather than assumed, because "works on
# my laptop" is how the jq bug reached main.
say "degrade honestly on a non-Pulsar host"
./cli/pulsar --version
./cli/pulsar doctor --json | jq -e '.checks | length > 0' >/dev/null
./cli/pulsar doctor --json | jq -e 'all(.checks[]; .summary | length > 0)' >/dev/null
# report is what gets pasted from a machine that is misbehaving, so it has to
# assemble whatever sources are missing -- here, most of them.
./cli/pulsar report | jq -e '.report.schema == 1 and (.units | type == "object")' >/dev/null
echo "no manifest here, so this must fail cleanly rather than crash:"
# Pointed at a path that exists nowhere, because "here" is not always a
# non-Pulsar host: run on an actual Pulsar machine, the bare command finds
# the real /usr/share/pulsar/manifest.json and this check fails backwards.
if PULSAR_MANIFEST=/proc/no-such-manifest ./cli/pulsar manifest 2>/dev/null; then
  echo "pulsar manifest succeeded on a host with no manifest" >&2
  exit 1
fi
echo "ok"

say "all checks passed"
