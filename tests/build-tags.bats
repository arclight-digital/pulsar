#!/usr/bin/env bats
# The two refusals build.sh makes before it touches a registry.
#
# Both land in the argument-validation block, ahead of the tool probe and the
# podman store lookup, which is what makes them testable at all: no podman, no
# skopeo, no image. That placement is deliberate in the script -- an hour into a
# build is the wrong place to learn that the push was never going to be allowed.
#
# The tag array inside push() is NOT tested here. Reaching it needs a real OCI
# layout plus a skopeo stub, and the decision that actually matters -- whether
# the floating tags may move -- is the guard below.

setup() {
  # Same reason as next-version.bats: the builder exports PULSAR_* into the
  # environment a hand-run build inherits, and build.sh reads four of them
  # (BUILD_WORK, SIGNER_URL, SIGNER_TOKEN_FILE, SIGNER_CA_FILE). Nothing here
  # sets those, so without this the guards below are tested against whatever the
  # operator's shell happens to hold.
  for v in "${!PULSAR_@}"; do unset "${v}"; done

  BUILD="${BATS_TEST_DIRNAME}/../scripts/build.sh"
  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${BIN}"
  PATH="${BIN}:${PATH}"
}

# A podman that exists and then refuses to answer, so a run which gets PAST the
# guards dies at the store lookup instead of continuing.
#
# Not optional caution: check.sh runs this suite at the top of every nightly, on
# a host that has both podman and the wallpaper renderer. Without this, the two
# tests below would render 4K PNGs and start a fifteen-minute image build inside
# a forty-second lint step.
# Stubbed as a SET, so the path past the guards is identical on a workstation, in
# a toolbox and on the build host -- otherwise the run stops at whichever tool
# happens to be missing, and the test asserts on the local machine's contents.
stub_tools() {
  local t
  for t in skopeo jq tar; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${BIN}/${t}"
    chmod +x "${BIN}/${t}"
  done
  printf '#!/usr/bin/env bash\necho "stub podman: no store here" >&2\nexit 1\n' \
    > "${BIN}/podman"
  chmod +x "${BIN}/podman"
}

@test "--push refuses to move the floating tags onto a -dev version" {
  # The belt across the seam: next-version.sh produces the -dev version and
  # nightly.sh passes --no-floating-tags beside it. Two flags that must agree
  # can disagree, and one direction of that puts a debugging image on every
  # user's next bootc upgrade. So the version string itself vetoes it.
  run "${BUILD}" --version "44.20260808.0-dev" --image localhost/pulsar --push
  [ "$status" -eq 2 ]
  [[ "$output" == *"--no-floating-tags"* ]]
  [[ "$output" == *"debugging build"* ]]
}

@test "--push accepts a -dev version once --no-floating-tags is passed" {
  # Past the guard, so it reaches the store lookup and dies there. What it must
  # not do is exit 2 on the refusal above.
  stub_tools
  run "${BUILD}" --version "44.20260808.0-dev" --image localhost/pulsar \
    --work "${BATS_TEST_TMPDIR}/work" --push --no-floating-tags
  [[ ! "$output" == *"refusing to move"* ]]
  [[ "$output" == *"stub podman"* ]]
}

@test "a plain version still pushes the floating tags without a flag" {
  stub_tools
  run "${BUILD}" --version "44.20260808.0" --image localhost/pulsar \
    --work "${BATS_TEST_TMPDIR}/work" --push
  [[ ! "$output" == *"refusing to move"* ]]
  [[ "$output" == *"stub podman"* ]]
}

@test "--push without --version is refused" {
  # The stamp assertion reads the version back out of the built image, so a
  # push with nothing to assert against cannot be verified. Guarded since the
  # script was written and never tested until now.
  run "${BUILD}" --image localhost/pulsar --push
  [ "$status" -eq 2 ]
  [[ "$output" == *"--push requires --version"* ]]
}

@test "--help prints the whole header, --no-floating-tags included" {
  run "${BUILD}" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--no-floating-tags"* ]]
  [[ "$output" == *"--allow-existing-version"* ]]
}
