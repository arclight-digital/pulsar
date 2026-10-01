#!/usr/bin/env bats
# publish.sh --stage: a gated build describes itself before its boot gate
# without becoming the release. The real publish.sh, against a local bare
# repository standing in for the site and stubs for everything that talks to
# a registry or R2 -- which record what they were asked to do.

bats_require_minimum_version 1.5.0

VERSION=44.20261001.3

setup() {
  for v in "${!PULSAR_@}"; do unset "${v}"; done
  BIN="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${BIN}"; PATH="${BIN}:${PATH}"
  export CALLS="${BATS_TEST_TMPDIR}/calls"; : > "${CALLS}"

  TREE="${BATS_TEST_TMPDIR}/tree"; mkdir -p "${TREE}/scripts"
  cp "${BATS_TEST_DIRNAME}/../scripts/publish.sh" "${TREE}/scripts/"
  echo "the OS repo" > "${TREE}/README.md"
  # an SBOM with enough packages to pass the sanity check
  cat > "${TREE}/scripts/rpm-sbom.sh" <<'EOF'
#!/usr/bin/env bash
jq -n '{packages: [range(150) | {name: "p\(.)", versionInfo: "1"}]}'
EOF
  printf '#!/usr/bin/env python3\n' > "${TREE}/scripts/render-theme-wallpapers.py"
  chmod +x "${TREE}/scripts/"*

  # podman: only `run ... cat manifest.json` is reached on this path
  printf '#!/usr/bin/env bash\necho "podman $*" >> "%s"\necho "{\\"version\\": \\"%s\\"}"\n' \
    "${CALLS}" "${VERSION}" > "${BIN}/podman"
  printf '#!/usr/bin/env bash\necho "oras $*" >> "%s"\n' "${CALLS}" > "${BIN}/oras"
  # aws: downloads fail (no baseline yet, so a baseline changelog); uploads record
  cat > "${BIN}/aws" <<EOF
#!/usr/bin/env bash
echo "aws \$*" >> "${CALLS}"
case "\$3" in s3://*) exit 1 ;; esac
exit 0
EOF
  chmod +x "${BIN}"/*

  # the site: main with what publish_site reads and writes
  SITE="${BATS_TEST_TMPDIR}/site.git"
  git init -q --bare -b main "${SITE}"
  local w="${BATS_TEST_TMPDIR}/seed"
  git init -q -b main "${w}"
  mkdir -p "${w}/src/data"
  echo '{}' > "${w}/src/data/changelog.json"
  echo '{}' > "${w}/src/data/manifest.json"
  echo 'README.md' > "${w}/upstream.list"
  git -C "${w}" add -A
  git -C "${w}" -c user.name=t -c user.email=t@t commit -q -m seed
  git -C "${w}" push -q "${SITE}" main
  MAIN_BEFORE="$(git -C "${SITE}" rev-parse main)"

  export WORK="${BATS_TEST_TMPDIR}/work"; mkdir -p "${WORK}"
  echo sha256:aaaa > "${WORK}/digest-vanilla"
  echo sha256:bbbb > "${WORK}/digest-nvidia"
  export R2_BUCKET=pulsar-artifacts R2_ENDPOINT=https://r2.example AWS_ACCESS_KEY_ID=k AWS_SECRET_ACCESS_KEY=s
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
}

publish() {
  run --separate-stderr "${TREE}/scripts/publish.sh" --version "${VERSION}" \
    --image ghcr.io/arclight-digital/pulsar --image-nvidia ghcr.io/arclight-digital/pulsar-nvidia \
    --work "${WORK}" --site-repo "file://${SITE}" --branch main "$@"
}

@test "--stage commits the site to release/<version> and leaves main alone" {
  publish --stage
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; false; }
  [ "$(git -C "${SITE}" rev-parse main)" = "${MAIN_BEFORE}" ]
  git -C "${SITE}" rev-parse -q --verify "refs/heads/release/${VERSION}" >/dev/null
  [ "$(git -C "${SITE}" rev-parse "release/${VERSION}^")" = "${MAIN_BEFORE}" ]
  git -C "${SITE}" show "release/${VERSION}:src/data/manifest.json" | grep -q "${VERSION}"
  [[ "$output" == *"staged ${VERSION}"* ]]
}

@test "--stage writes the per-build R2 keys and none of the pointers" {
  publish --stage
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  grep -q "s3://pulsar-artifacts/pulsar/sbom/${VERSION}-vanilla.spdx.json" "${CALLS}"
  grep -q "s3://pulsar-artifacts/pulsar/changelog/${VERSION}.json" "${CALLS}"
  if grep -q -- '-latest.spdx.json\|changelog/latest.json' <(grep '^aws s3 cp /' "${CALLS}"); then
    echo "a moving pointer was written:"; grep -- 'latest' "${CALLS}"; false
  fi
  # and the SBOMs are attached to the pushed digests, as for any build
  grep -q '^oras attach .*pulsar@sha256:aaaa' "${CALLS}"
}

@test "without --stage the site commit lands on main and the pointers move" {
  publish
  [ "$status" -eq 0 ] || { echo "$stderr"; false; }
  [ "$(git -C "${SITE}" rev-parse main)" != "${MAIN_BEFORE}" ]
  ! git -C "${SITE}" rev-parse -q --verify "refs/heads/release/${VERSION}" >/dev/null
  grep -q 's3://pulsar-artifacts/pulsar/sbom/vanilla-latest.spdx.json' "${CALLS}"
}

@test "--stage and --no-promote together are refused" {
  publish --stage --no-promote
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"pass one"* ]]
}
