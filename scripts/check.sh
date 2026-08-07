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
  scripts/build-iso.sh \
  scripts/build.sh \
  scripts/check-scx-btf.sh \
  scripts/check.sh \
  scripts/diff-chunk-metadata.sh \
  scripts/flatpak-defaults.sh \
  scripts/lint-containerfile.sh \
  scripts/next-version.sh \
  scripts/nightly.sh \
  scripts/publish.sh \
  scripts/rechunk-selftest.sh \
  scripts/rpm-sbom.sh \
  scripts/sbom-changelog.sh \
  scripts/sign-file-oracle \
  scripts/sync-branding.sh \
  scripts/weekly.sh
echo "shellcheck: clean"

# The signer holds the Secure Boot key, so a syntax error in it is a nightly
# that cannot sign. Compile-checking is the cheap half; the behaviour is
# covered by the shim's own end-to-end run.
say "compile-check the signer"
python3 -m py_compile scripts/pulsar-signer.py
echo "pulsar-signer: compiles"

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
bats tests/

# The CLI must behave on a machine that is not a Pulsar system: no bootc, no
# rpm-ostree, no sched_ext. Asserted rather than assumed, because "works on
# my laptop" is how the jq bug reached main.
say "degrade honestly on a non-Pulsar host"
./cli/pulsar --version
./cli/pulsar doctor --json | jq -e '.checks | length > 0' >/dev/null
./cli/pulsar doctor --json | jq -e 'all(.checks[]; .summary | length > 0)' >/dev/null
echo "no manifest here, so this must fail cleanly rather than crash:"
if ./cli/pulsar manifest 2>/dev/null; then
  echo "pulsar manifest succeeded on a host with no manifest" >&2
  exit 1
fi
echo "ok"

say "all checks passed"
