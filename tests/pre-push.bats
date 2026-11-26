#!/usr/bin/env bats
# scripts/hooks/pre-push: main moves only to a commit with a recorded pass.
# Every push here goes to a bare repo in the test's own directory, never to a
# real remote.

setup() {
  HOOKS="$(cd "${BATS_TEST_DIRNAME}/../scripts/hooks" && pwd)"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  cd "${BATS_TEST_TMPDIR}"
  git init -q --bare remote.git
  git init -q -b main work
  cd work
  git config core.hooksPath "${HOOKS}"
  git remote add origin ../remote.git
  git commit -q --allow-empty -m one
  SHA=$(git rev-parse HEAD)
  COMMON=$(git rev-parse --git-common-dir)
}

remote_main() { git --git-dir=../remote.git rev-parse -q --verify refs/heads/main || true; }

@test "pre-push: main refuses a commit nothing has passed" {
  run git push -q origin HEAD:main
  [ "$status" -ne 0 ]
  [[ "$output" == *"has not passed check.sh"* ]]
  [[ "$output" == *"scripts/root-check.sh ${SHA:0:12}"* ]]
  [ -z "$(remote_main)" ]
}

@test "pre-push: a root-check pass lets main move" {
  printf '%s passed 2026-11-26T00:00:00+00:00 root-check\n' "${SHA}" > "${COMMON}/local-checks"
  run git push -q origin HEAD:main
  [ "$status" -eq 0 ]
  [ "$(remote_main)" = "${SHA}" ]
}

@test "pre-push: a builder pass still counts" {
  printf '%s passed 2026-11-26T00:00:00+00:00\n' "${SHA}" > "${COMMON}/builder-checks"
  run git push -q origin HEAD:main
  [ "$status" -eq 0 ]
  [ "$(remote_main)" = "${SHA}" ]
}

@test "pre-push: a pass for another commit does not" {
  printf '%s passed 2026-11-26T00:00:00+00:00 root-check\n' "${SHA}" > "${COMMON}/local-checks"
  git commit -q --allow-empty -m two
  run git push -q origin HEAD:main
  [ "$status" -ne 0 ]
  [ -z "$(remote_main)" ]
}

@test "pre-push: a failed line is not a pass" {
  printf '%s failed 2026-11-26T00:00:00+00:00 root-check\n' "${SHA}" > "${COMMON}/local-checks"
  run git push -q origin HEAD:main
  [ "$status" -ne 0 ]
  [ -z "$(remote_main)" ]
}

@test "pre-push: other branches need no pass" {
  run git push -q origin HEAD:refs/heads/topic
  [ "$status" -eq 0 ]
  [ "$(git --git-dir=../remote.git rev-parse refs/heads/topic)" = "${SHA}" ]
}
