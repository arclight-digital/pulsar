#!/usr/bin/env bats
# The refusal build.sh makes when the filesystem cannot hold what it is about
# to build.
#
# 2026-09-01: the build cache volume was already at zero free when the nightly
# started -- the builder's log said `(0 free)` at mount, in its first twenty
# lines -- and the build spent three minutes arriving at "rpmfusion release
# RPMs unreachable after 3 attempts", which was true of nothing. rpm's own
# "needs 60KB more space on the / filesystem" was one line above it, inside a
# retry loop that could not tell a full disk from a slow mirror. So the
# question is asked once, up front, where the answer is still cheap.
#
# The refusal is AFTER the podman store lookup rather than beside the argument
# guards build-tags.bats covers, because it needs to know where the store is.
# That means podman has to answer here -- stubbed to answer `info` and to
# refuse everything else, so a run that gets past the guard dies immediately
# instead of starting a fifteen-minute image build inside a lint step.

setup() {
  # The builder exports PULSAR_* into the environment a hand-run build
  # inherits, PULSAR_BUILD_WORK and PULSAR_MIN_FREE_GB among them. Same reason
  # as build-tags.bats: without this the tests below assert against whatever
  # the operator's shell happens to hold.
  for v in "${!PULSAR_@}"; do unset "${v}"; done

  BUILD="${BATS_TEST_DIRNAME}/../scripts/build.sh"
  BIN="${BATS_TEST_TMPDIR}/bin"
  STORE="${BATS_TEST_TMPDIR}/store"
  WORK="${BATS_TEST_TMPDIR}/work"
  mkdir -p "${BIN}" "${STORE}" "${WORK}"
  PATH="${BIN}:${PATH}"
  stub_tools
}

# The store lookup answered, the build refused. build.sh asks `podman info`
# three times and then, if it gets that far, builds -- so this is the seam
# that keeps a test of the space check from being a test of podman build.
stub_tools() {
  local t
  for t in skopeo jq tar; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${BIN}/${t}"
    chmod +x "${BIN}/${t}"
  done

  cat > "${BIN}/podman" <<EOF
#!/usr/bin/env bash
if [ "\$1" = info ]; then
  case "\$*" in
    *GraphRoot*)       printf '%s\n' '${STORE}' ;;
    *RunRoot*)         printf '%s\n' '${STORE}/run' ;;
    *GraphDriverName*) printf 'overlay\n' ;;
  esac
  exit 0
fi
echo "stub podman: reached \$1, which this test never wants to run" >&2
exit 1
EOF
  chmod +x "${BIN}/podman"
}

build() { run "${BUILD}" --work "${WORK}" "$@"; }

@test "a build refuses to start on a filesystem that cannot hold it" {
  # No real full disk to test against, so the floor moves instead: a
  # filesystem with a petabyte free is short of this one.
  PULSAR_MIN_FREE_GB=1000000000 build --no-wallpapers
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to start a build"* ]]
}

@test "the refusal names the escape hatch rather than just the number" {
  # The one thing a wrong floor must never be is unarguable: whoever hits it
  # at 3am needs the override in front of them, not in the source.
  PULSAR_MIN_FREE_GB=1000000000 build --no-wallpapers
  [[ "$output" == *"PULSAR_MIN_FREE_GB"* ]]
  [[ "$output" == *"podman image prune"* ]]
}

@test "the free space is in the log on a build that passes the check" {
  # Reported every night, whether or not it is short. The 2026-09-01 log had
  # this number in it and it took a morning to find, because it was printed
  # once by a script nobody was reading and never again by the build.
  PULSAR_MIN_FREE_GB=1 build --no-wallpapers
  [[ "$output" == *"GB free"* ]]
  [[ "$output" == *"${STORE}"* ]]
}

@test "the check runs before anything expensive" {
  # Ordering, stated as a test. --no-wallpapers is NOT passed here: a build
  # that renders four 4K PNGs and then refuses itself has already spent the
  # minutes the refusal exists to save.
  PULSAR_MIN_FREE_GB=1000000000 build
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to start a build"* ]]
  [[ "$output" != *"rendering wallpapers"* ]]
}

@test "a passing check hands the build on rather than ending it" {
  # The other half: the guard must not become a build that never runs. Past
  # it, the stub podman refuses the build itself, which is how far this can
  # go without one.
  PULSAR_MIN_FREE_GB=1 build --no-wallpapers
  [ "$status" -ne 0 ]
  [[ "$output" == *"reached build"* ]]
}

@test "PULSAR_MIN_FREE_GB=0 turns the check off and says so" {
  # An override that is silent is an override nobody remembers setting.
  PULSAR_MIN_FREE_GB=0 build --no-wallpapers
  [[ "$output" == *"not checking free space"* ]]
  [[ "$output" == *"reached build"* ]]
}
