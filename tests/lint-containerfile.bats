#!/usr/bin/env bats
# Tests for scripts/lint-containerfile.sh, the check.sh step that reads the
# shell inside every RUN before a build pays for it.
#
# The bug: the login step installed glib2-devel for its resource compiler and
# removed it again. Its libmount-devel came at util-linux 2.41.6 and upgraded
# the base's 2.41.5 under the image, and dnf5 remove never took the upgrade
# back, so the 44.20261029.0 nightly died at the step's package-set check.
#
# Pinned here: a RUN that installs a package and removes it again is refused,
# versioned spec or not; removing a package the base ships is not; and the
# shipped Containerfiles pass.

LINT="${BATS_TEST_DIRNAME}/../scripts/lint-containerfile.sh"

setup() {
  CF="${BATS_TEST_TMPDIR}/Containerfile"
}

@test "REGRESSION: a RUN that installs a tool and removes it again is refused, and says what to do" {
  cat >"$CF" <<'EOF'
FROM scratch
RUN set -eu; \
    glib="$(rpm -q --qf '%{VERSION}-%{RELEASE}' glib2)"; \
    dnf5 install -y --enablerepo=updates-archive "glib2-devel-${glib}"; \
    glib-compile-resources --version; \
    dnf5 remove -y glib2-devel
EOF
  run "$LINT" "$CF"
  [ "$status" -eq 1 ]
  [[ "$output" == *"${CF}:2: RUN installs glib2-devel and removes it again"* ]]
  [[ "$output" == *"dnf5 download"* ]]
}

@test "an unversioned tool among packages that stay is caught too" {
  cat >"$CF" <<'EOF'
FROM scratch
RUN dnf5 install -y adw-gtk3-theme libjxl-utils && cjxl in.png out.jxl && dnf5 remove -y libjxl-utils
EOF
  run "$LINT" "$CF"
  [ "$status" -eq 1 ]
  [[ "$output" == *"RUN installs libjxl-utils and removes it again"* ]]
  [[ "$output" != *"adw-gtk3-theme"* ]]
}

@test "removing a package the base ships is not a temporary install" {
  cat >"$CF" <<'EOF'
FROM scratch
RUN dnf5 install -y gamemode mangohud && \
    dnf5 remove -y gnome-shell-extension-background-logo || true
EOF
  run "$LINT" "$CF"
  [ "$status" -eq 0 ]
}

@test "a package installed in one RUN and removed in another is a separate decision, not flagged" {
  cat >"$CF" <<'EOF'
FROM scratch
RUN dnf5 install -y foo
RUN dnf5 remove -y foo
EOF
  run "$LINT" "$CF"
  [ "$status" -eq 0 ]
}

@test "a package that only shares a prefix, or is a subpackage, is not the one removed" {
  cat >"$CF" <<'EOF'
FROM scratch
RUN dnf5 install -y glib2-develop glib2-devel-docs && dnf5 remove -y glib2-devel
EOF
  run "$LINT" "$CF"
  [ "$status" -eq 0 ]
}

@test "the shipped Containerfiles install no tool only to remove it" {
  run "$LINT" "${BATS_TEST_DIRNAME}/../Containerfile" "${BATS_TEST_DIRNAME}/../Containerfile.nvidia"
  [ "$status" -eq 0 ]
}
