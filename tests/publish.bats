#!/usr/bin/env bats
# publish.sh: everything after the push that tells people an update exists.
#
# It writes three things users and the next night read: the R2 pointers
# (vanilla-latest.spdx.json is the baseline tomorrow's changelog diffs
# against), the site commit (the page that says what changed), and the SBOMs
# on the images. Each has failed quietly before: an all-zeros baseline
# changelog was one missing credential away from blanking the published one,
# the first site commit was skipped because `git diff` ignores untracked
# files, a rebase silently reverted a renderer fix, and a hand-run build used
# to define the baseline the next scheduled build diffed against.
# publish-stage.bats covers --stage; this covers the rest.
#
# The real publish.sh runs against a local bare repository standing in for the
# site. aws is a fake R2 backed by a directory, so a test can read back what
# was uploaded and in what order. podman answers the two questions publish.sh
# asks it: the image's baked manifest (fields as in /usr/share/pulsar/
# manifest.json on a Pulsar 44.20261008.0 host) and the changelog diff, which
# the stub runs for real -- the copied sbom-changelog.sh, inside the stage
# directory it was handed, with the environment it was handed.

bats_require_minimum_version 1.5.0

VERSION=44.20261011.2
BUCKET=pulsar-artifacts

setup() {
  for v in "${!PULSAR_@}"; do unset "${v}"; done
  unset R2_ACCOUNT_ID R2_ENDPOINT R2_BUCKET R2_CREDENTIALS_FILE AWS_ACCESS_KEY_ID \
    AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION AWS_REQUEST_CHECKSUM_CALCULATION \
    GITHUB_REF_NAME REGISTRY_AUTH_FILE PREV_DIGEST IMAGE IMAGE_NVIDIA
  # Nothing from the user's git config: a credential helper there must never
  # see a test's token (2026-09-27), and a signing setting would fail commits.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  REAL_GIT="$(command -v git)"
  BIN="${BATS_TEST_TMPDIR}/bin"; mkdir -p "${BIN}"; PATH="${BIN}:${PATH}"
  export CALLS="${BATS_TEST_TMPDIR}/calls"; : > "${CALLS}"

  TREE="${BATS_TEST_TMPDIR}/tree"; mkdir -p "${TREE}/scripts" "${TREE}/docs/guides"
  cp "${BATS_TEST_DIRNAME}/../scripts/publish.sh" "${BATS_TEST_DIRNAME}/../scripts/sbom-changelog.sh" "${TREE}/scripts/"
  echo "the OS repo" > "${TREE}/README.md"
  echo "a doc" > "${TREE}/docs/agents.md"
  echo "a nested doc" > "${TREE}/docs/guides/steam.md"
  # The SBOM generator: N packages named after the image, so what was uploaded
  # can be traced back to which image it describes. rpm-sbom.bats tests the
  # real one.
  cat > "${TREE}/scripts/rpm-sbom.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in *nvidia*) n="${SBOM_N_NVIDIA:-151}" ;; *) n="${SBOM_N_VANILLA:-150}" ;; esac
jq -n --arg ref "$1" --argjson n "${n}" \
  '{spdxVersion: "SPDX-2.3", name: $ref, packages: [range($n) | {name: "p\(.)", versionInfo: "1-1.fc44"}]}'
EOF
  # exits 0 having written nothing, like a renderer with no themes to export
  printf '#!/usr/bin/env python3\n' > "${TREE}/scripts/render-theme-wallpapers.py"
  chmod +x "${TREE}/scripts/"*

  export R2="${BATS_TEST_TMPDIR}/r2" AWS_ENV="${BATS_TEST_TMPDIR}/aws-env"
  mkdir -p "${R2}"; : > "${AWS_ENV}"
  # `aws s3 cp SRC DST --endpoint-url URL`, against ${R2}/<bucket>/<key>. A
  # missing key fails the way the CLI does (a 404 on HeadObject, exit 1); a
  # missing local file is refused before any request.
  cat > "${BIN}/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "${CALLS}"
echo "${AWS_ACCESS_KEY_ID:-}|${AWS_SECRET_ACCESS_KEY:-}|${AWS_DEFAULT_REGION:-}|${AWS_REQUEST_CHECKSUM_CALCULATION:-}" >> "${AWS_ENV}"
[ "$1 $2" = "s3 cp" ] && [ "$5" = --endpoint-url ] && [ -n "$6" ] || { echo "aws stub: unexpected: $*" >&2; exit 252; }
case "$3" in
  s3://*)
    [ -f "${R2}/${3#s3://}" ] || { echo "fatal error: An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 1; }
    cp "${R2}/${3#s3://}" "$4" ;;
  *)
    [ -f "$3" ] || { echo "The user-provided path $3 does not exist." >&2; exit 255; }
    mkdir -p "$(dirname "${R2}/${4#s3://}")"
    cp "$3" "${R2}/${4#s3://}" ;;
esac
EOF
  # podman run <image> cat manifest.json, and the changelog diff:
  # podman run --rm -v <stage>:/w:z -w /w -e K=V... fedora:44 bash -c '<cmd>'
  cat > "${BIN}/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "${CALLS}"
[ "$1" = run ] || exit 125
shift
vol= envs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rm) ;;
    -v) vol="${2%:/w:z}"; shift ;;
    -w) shift ;;
    -e) envs+=("$2"); shift ;;
    *) break ;;
  esac
  shift
done
image="$1"; shift
case "${image}" in
  *pulsar-nvidia:44)
    [ "$*" = "cat /usr/share/pulsar/manifest.json" ] || exit 1
    printf '{"image":"pulsar-nvidia","variant":"nvidia-open","release":"26.10.1","version":"%s","base":"fedora-silverblue:44","built":"%s","kernel":"7.2.8-200.fc44.x86_64","nvidia_driver":"615.71.09"}\n' \
      "${MANIFEST_VERSION}" "${MANIFEST_BUILT:-2026-10-11T02:19:33Z}" ;;
  registry.fedoraproject.org/fedora:44)
    [ -n "${vol}" ] || exit 1
    cd "${vol}" && env "${envs[@]}" "$@" ;;
  *) exit 125 ;;
esac
EOF
  # dnf5 inside that container: jq and rpmdevtools are already "installed"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${BIN}/dnf5"
  printf '#!/usr/bin/env bash\necho "oras $*" >> "%s"\n' "${CALLS}" > "${BIN}/oras"
  # the retry backoff, minus the waiting
  printf '#!/usr/bin/env bash\necho "sleep $*" >> "%s"\n' "${CALLS}" > "${BIN}/sleep"
  chmod +x "${BIN}"/*
  export MANIFEST_VERSION="${VERSION}"

  # the site: main, with what publish_site reads and writes
  SITE="${BATS_TEST_TMPDIR}/site.git"
  seed_site
  MAIN_BEFORE="$(git -C "${SITE}" rev-parse main)"

  # not exported: publish.sh's own WORK comes from --work or PULSAR_BUILD_WORK
  WORK="${BATS_TEST_TMPDIR}/work"; mkdir -p "${WORK}"
  echo sha256:aaaa > "${WORK}/digest-vanilla"
  echo sha256:bbbb > "${WORK}/digest-nvidia"
  export R2_BUCKET="${BUCKET}" R2_ENDPOINT=https://r2.example AWS_ACCESS_KEY_ID=k AWS_SECRET_ACCESS_KEY=s
}

# A bare site repo whose main has the data files, an upstream.list naming
# $1 (default README.md), and anything else passed as path=content pairs.
seed_site() {
  local list="${1:-README.md}" w="${BATS_TEST_TMPDIR}/seed" kv
  rm -rf "${SITE}" "${w}"
  git init -q --bare -b main "${SITE}"
  git init -q -b main "${w}"
  mkdir -p "${w}/src/data"
  echo '{}' > "${w}/src/data/changelog.json"
  echo '{}' > "${w}/src/data/manifest.json"
  [ "${list}" = NONE ] || printf '%s\n' "${list}" > "${w}/upstream.list"
  shift || true
  for kv in "$@"; do
    mkdir -p "$(dirname "${w}/${kv%%=*}")"
    printf '%s\n' "${kv#*=}" > "${w}/${kv%%=*}"
  done
  git -C "${w}" add -A
  git -C "${w}" commit -q -m seed
  git -C "${w}" push -q "${SITE}" main
  MAIN_BEFORE="$(git -C "${SITE}" rev-parse main)"
}

publish() {
  run --separate-stderr "${TREE}/scripts/publish.sh" --version "${VERSION}" \
    --image ghcr.io/arclight-digital/pulsar --image-nvidia ghcr.io/arclight-digital/pulsar-nvidia \
    --work "${WORK}" --site-repo "file://${SITE}" --branch main "$@"
}

ok() { [ "$status" -eq 0 ] || { echo "status ${status}"; echo "$output"; echo "$stderr"; false; }; }
main_moved()    { [ "$(git -C "${SITE}" rev-parse main)" != "${MAIN_BEFORE}" ]; }
main_unmoved()  { [ "$(git -C "${SITE}" rev-parse main)" = "${MAIN_BEFORE}" ]; }
on_main()       { git -C "${SITE}" show "main:$1"; }
# R2 keys in upload order, one per line
uploads()       { sed -n "s|^aws s3 cp /[^ ]* s3://${BUCKET}/\([^ ]*\) .*|\1|p" "${CALLS}"; }
nothing_uploaded() {
  if [ -n "$(uploads)" ]; then echo "uploaded:"; uploads; return 1; fi
}
nothing_attached() {
  if grep -q '^oras attach' "${CALLS}"; then grep '^oras' "${CALLS}"; return 1; fi
}
in_r2() { cat "${R2}/${BUCKET}/$1"; }

# A PATH with what publish.sh needs to reach its tool checks, the stubs, and
# not $1, which is also taken out of the stubs.
without() {
  local sandbox="${BATS_TEST_TMPDIR}/sandbox" t
  mkdir -p "${sandbox}"
  for t in bash dirname jq git; do ln -sf "$(command -v "${t}")" "${sandbox}/${t}"; done
  rm -f "${BIN}/$1" "${sandbox}/$1"
  SANDBOX_PATH="${BIN}:${sandbox}"
}

# ---------------------------------------------------------------------------
# What it refuses, before anything is attached, uploaded or committed.
# ---------------------------------------------------------------------------

@test "an ambient VERSION is not a version: --version is still required" {
  VERSION=44.20260101.0 run --separate-stderr "${TREE}/scripts/publish.sh" \
    --image ghcr.io/arclight-digital/pulsar --image-nvidia ghcr.io/arclight-digital/pulsar-nvidia \
    --work "${WORK}" --site-repo "file://${SITE}"
  [ "$status" -eq 1 ]
  [ "$stderr" = "publish: --version is required" ]
  [ ! -s "${CALLS}" ]
}

@test "no image names is refused by name, not by an unbound variable" {
  run --separate-stderr "${TREE}/scripts/publish.sh" --version "${VERSION}" --work "${WORK}"
  [ "$status" -eq 1 ]
  [ "$stderr" = 'publish: --image (or $IMAGE) is required' ]
  run --separate-stderr "${TREE}/scripts/publish.sh" --version "${VERSION}" --work "${WORK}" \
    --image ghcr.io/arclight-digital/pulsar
  [ "$status" -eq 1 ]
  [ "$stderr" = 'publish: --image-nvidia (or $IMAGE_NVIDIA) is required' ]
  [ ! -s "${CALLS}" ]
}

@test "a missing podman is named before anything is described" {
  without podman
  run --separate-stderr env PATH="${SANDBOX_PATH}" "${TREE}/scripts/publish.sh" --version "${VERSION}" \
    --image ghcr.io/arclight-digital/pulsar --image-nvidia ghcr.io/arclight-digital/pulsar-nvidia --work "${WORK}"
  [ "$status" -eq 1 ]
  [ "$stderr" = "publish: missing: podman" ]
  [ ! -s "${CALLS}" ]
}

@test "a missing oras is named before anything is described" {
  without oras
  run --separate-stderr env PATH="${SANDBOX_PATH}" "${TREE}/scripts/publish.sh" --version "${VERSION}" \
    --image ghcr.io/arclight-digital/pulsar --image-nvidia ghcr.io/arclight-digital/pulsar-nvidia --work "${WORK}"
  [ "$status" -eq 1 ]
  [ "$stderr" = "publish: missing: oras (attaches the SBOMs to the images)" ]
  [ ! -s "${CALLS}" ]
}

@test "promoting without aws is refused before anything is described" {
  without aws
  run --separate-stderr env PATH="${SANDBOX_PATH}" "${TREE}/scripts/publish.sh" --version "${VERSION}" \
    --image ghcr.io/arclight-digital/pulsar --image-nvidia ghcr.io/arclight-digital/pulsar-nvidia --work "${WORK}"
  [ "$status" -eq 1 ]
  [ "$stderr" = "publish: missing: aws (the R2 client; install awscli or pass --dry-run)" ]
  [ ! -s "${CALLS}" ]
}

@test "a build with no recorded digest is refused, not attached to an empty one" {
  rm "${WORK}/digest-nvidia"
  publish
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no nvidia digest"* ]]
  rm "${WORK}/digest-vanilla"
  publish
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no vanilla digest"* ]]
  nothing_attached
  nothing_uploaded
}

@test "an unreadable site token stops the night before anything is published" {
  publish --git-token-file "${BATS_TEST_TMPDIR}/no-such-token"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"cannot read ${BATS_TEST_TMPDIR}/no-such-token"* ]]
  nothing_attached
  nothing_uploaded
  main_unmoved
}

@test "an SBOM with too few packages is refused before it is attached anywhere" {
  SBOM_N_VANILLA=50 publish
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"sbom-vanilla has only 50 packages"* ]]
  nothing_attached
  nothing_uploaded
}

@test "an nvidia SBOM smaller than vanilla's means the wrong image was read" {
  # nvidia is built FROM vanilla, so it can only ever carry more
  SBOM_N_NVIDIA=140 publish
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"nvidia (140) has fewer packages than vanilla (150)"* ]]
  nothing_attached
  nothing_uploaded
}

# ---------------------------------------------------------------------------
# R2: how it is reached, and what it is told.
# ---------------------------------------------------------------------------

@test "R2 credentials come from the build host's file, in its R2_* spelling" {
  # exactly what spawn-builder.sh writes to r2.env
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  export R2_CREDENTIALS_FILE="${BATS_TEST_TMPDIR}/r2.env"
  printf 'R2_ACCESS_KEY_ID=%s\nR2_SECRET_ACCESS_KEY=%s\n' r2-key-id r2-secret > "${R2_CREDENTIALS_FILE}"
  publish
  ok
  [ -n "$(uploads)" ]
  [ "$(cut -d'|' -f1,2 "${AWS_ENV}" | sort -u)" = "r2-key-id|r2-secret" ]
}

@test "an unreadable R2 credentials file is refused before anything is described" {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  export R2_CREDENTIALS_FILE="${BATS_TEST_TMPDIR}/no-such-r2.env"
  publish
  [ "$status" -eq 1 ]
  [ "$stderr" = "publish: cannot read ${R2_CREDENTIALS_FILE}" ]
  [ ! -s "${CALLS}" ]
}

@test "R2 is reached at the account's endpoint, in region auto, with the checksums it accepts" {
  unset R2_ENDPOINT
  export R2_ACCOUNT_ID=0123abcd
  publish
  ok
  # every call, the baseline download included
  [ "$(grep -c '^aws ' "${CALLS}")" -gt 0 ]
  [ "$(grep '^aws ' "${CALLS}" | grep -vc -- '--endpoint-url https://0123abcd.r2.cloudflarestorage.com$')" = 0 ]
  [ "$(cut -d'|' -f3,4 "${AWS_ENV}" | sort -u)" = "auto|when_required" ]
}

@test "promoting with no R2 is refused, and says what to set" {
  # An all-zeros changelog would otherwise be committed over the real one.
  unset R2_BUCKET
  publish
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"R2 is not configured"* ]]
  [[ "$stderr" == *"R2_ENDPOINT), and either AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or"* ]]
  [[ "$stderr" == *"R2_CREDENTIALS_FILE pointing at a file that sets them"* ]]
  [[ "$stderr" == *"PULSAR_PUBLISH"* ]]
  nothing_uploaded
  main_unmoved
}

# ---------------------------------------------------------------------------
# The pointers. A promoted build moves them; nothing else ever does.
# ---------------------------------------------------------------------------

@test "a promoted build writes its own keys, then the pointers, vanilla-latest last" {
  publish
  ok
  # The per-build key names are what the build host copies onto the pointers
  # when it releases a staged build (spawn-builder.sh r2_pointers).
  [ "$(uploads)" = "pulsar/sbom/${VERSION}-vanilla.spdx.json
pulsar/sbom/${VERSION}-nvidia.spdx.json
pulsar/changelog/${VERSION}.json
pulsar/changelog/latest.json
pulsar/sbom/nvidia-latest.spdx.json
pulsar/sbom/vanilla-latest.spdx.json" ]
  # and each describes the image it is named for
  [ "$(in_r2 "pulsar/sbom/${VERSION}-vanilla.spdx.json" | jq -r .name)" = ghcr.io/arclight-digital/pulsar:44 ]
  [ "$(in_r2 "pulsar/sbom/${VERSION}-nvidia.spdx.json" | jq -r .name)" = ghcr.io/arclight-digital/pulsar-nvidia:44 ]
  [ "$(in_r2 pulsar/sbom/vanilla-latest.spdx.json | jq -r .name)" = ghcr.io/arclight-digital/pulsar:44 ]
  [ "$(in_r2 pulsar/sbom/nvidia-latest.spdx.json | jq '.packages | length')" = 151 ]
  [ "$(in_r2 pulsar/changelog/latest.json | jq -r .to.ref)" = ghcr.io/arclight-digital/pulsar@sha256:aaaa ]
  [[ "$output" == *"published ${VERSION}"* ]]
}

@test "--no-promote writes its own keys and never a pointer, or the site" {
  publish --no-promote
  ok
  [ "$(uploads)" = "pulsar/sbom/${VERSION}-vanilla.spdx.json
pulsar/sbom/${VERSION}-nvidia.spdx.json
pulsar/changelog/${VERSION}.json" ]
  [ ! -e "${R2}/${BUCKET}/pulsar/sbom/vanilla-latest.spdx.json" ]
  main_unmoved
  [[ "$output" == *"it is not the published build"* ]]
}

@test "--no-promote with no R2 still describes the build, and uploads nothing" {
  # A manual build an hour in, image pushed: failing here would be the
  # unrecoverable half of the split. The changelog has no baseline to diff
  # against, so it is the baseline kind, and no diff container is started.
  unset R2_BUCKET R2_ENDPOINT AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  publish --no-promote
  ok
  if grep -q '^aws' "${CALLS}"; then grep '^aws' "${CALLS}"; false; fi
  if grep -q 'fedora:44' "${CALLS}"; then grep '^podman' "${CALLS}"; false; fi
  [ "$(jq .baseline "${WORK}/publish/changelog.json")" = true ]
  [ -s "${WORK}/publish/sbom-vanilla.spdx.json" ]
  main_unmoved
}

@test "a dry run attaches, uploads and commits nothing, and needs no token to do it" {
  publish --dry-run --git-token-file "${BATS_TEST_TMPDIR}/no-such-token"
  ok
  nothing_attached
  # (reading last night's baseline is fine; writing anything is not)
  nothing_uploaded
  main_unmoved
  [ -z "$(git -C "${SITE}" for-each-ref refs/heads/release)" ]
  # and still produces what it would have published
  [ "$(jq -r .version "${WORK}/publish/manifest.json")" = "${VERSION}" ]
  jq -e .summary "${WORK}/publish/changelog.json" >/dev/null
}

# ---------------------------------------------------------------------------
# The changelog.
# ---------------------------------------------------------------------------

# Last night's vanilla SBOM, as the pointer in R2 holds it: $1 packages
# (default 149, one fewer than tonight's).
seed_baseline() {
  mkdir -p "${R2}/${BUCKET}/pulsar/sbom"
  jq -n --argjson n "${1:-149}" \
    '{spdxVersion: "SPDX-2.3", packages: [range($n) | {name: "p\(.)", versionInfo: "1-1.fc44"}]}' \
    > "${R2}/${BUCKET}/pulsar/sbom/vanilla-latest.spdx.json"
}

@test "with a baseline in R2 the changelog is the diff against it, run inside Fedora" {
  seed_baseline
  publish --prev-digest sha256:9999
  ok
  grep -q '^podman run --rm -v .*:/w:z -w /w .* registry.fedoraproject.org/fedora:44 bash -c ' "${CALLS}"
  # what users see on the page
  on_main src/data/changelog.json > "${BATS_TEST_TMPDIR}/page.json"
  [ "$(jq -c .summary "${BATS_TEST_TMPDIR}/page.json")" = \
    '{"added":1,"removed":0,"upgraded":0,"downgraded":0,"changed":0}' ]
  [ "$(jq -r '.added[0].name' "${BATS_TEST_TMPDIR}/page.json")" = p149 ]
  [ "$(jq -r .from.ref "${BATS_TEST_TMPDIR}/page.json")" = ghcr.io/arclight-digital/pulsar@sha256:9999 ]
  [ "$(jq -r .to.digest "${BATS_TEST_TMPDIR}/page.json")" = sha256:aaaa ]
  [ "$(jq -r .baseline "${BATS_TEST_TMPDIR}/page.json")" = null ]
  # and the same document in R2
  [ "$(in_r2 "pulsar/changelog/${VERSION}.json" | jq -c .summary)" = "$(jq -c .summary "${BATS_TEST_TMPDIR}/page.json")" ]
}

# ---------------------------------------------------------------------------
# The site commit.
# ---------------------------------------------------------------------------

@test "a promoted build commits its changelog, manifest and upstream files to main" {
  publish
  ok
  main_moved
  [ "$(git -C "${SITE}" log -1 --format=%s main)" = "site: package changelog for ${VERSION}" ]
  [ "$(on_main src/data/changelog.json | jq -r .to.ref)" = ghcr.io/arclight-digital/pulsar@sha256:aaaa ]
  [ "$(on_main src/data/manifest.json | jq -r .version)" = "${VERSION}" ]
  [ "$(on_main upstream/README.md)" = "the OS repo" ]
}

@test "a night that changed nothing commits nothing" {
  # Every build stamps a new version, build time and changelog timestamp. A
  # byte comparison would commit every night: bot noise in a hand-written
  # history. Both nights diff against the same package set.
  seed_baseline 150
  publish
  ok
  main_moved
  MAIN_BEFORE="$(git -C "${SITE}" rev-parse main)"
  MANIFEST_VERSION=44.20261012.0 MANIFEST_BUILT=2026-10-12T02:20:01Z \
    run --separate-stderr "${TREE}/scripts/publish.sh" --version 44.20261012.0 \
    --image ghcr.io/arclight-digital/pulsar --image-nvidia ghcr.io/arclight-digital/pulsar-nvidia \
    --work "${WORK}" --site-repo "file://${SITE}" --branch main
  ok
  main_unmoved
  [[ "$output" == *"nothing to commit"* ]]
}

@test "a file dropped from upstream.list leaves the site" {
  seed_site README.md upstream/old-guide.md=gone
  publish
  ok
  [ "$(on_main upstream/README.md)" = "the OS repo" ]
  if on_main upstream/old-guide.md 2>/dev/null; then false; fi
}

@test "a glob in upstream.list copies the files it matches and skips directories" {
  seed_site 'docs/*'
  publish
  ok
  [ "$(on_main upstream/docs/agents.md)" = "a doc" ]
  if on_main upstream/docs/guides/steam.md 2>/dev/null; then false; fi
}

@test "an upstream.list that matches nothing fails the commit rather than emptying upstream/" {
  seed_site '# only a comment
nothing/*'
  publish
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"upstream.list matched nothing"* ]]
  main_unmoved
}

@test "a site repo with no upstream.list is named as the problem" {
  seed_site NONE
  publish
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"the site repo has no upstream.list"* ]]
  main_unmoved
}

@test "a theme-uniforms export that fails keeps the site's last copy" {
  seed_site README.md 'upstream/theme-uniforms.json={"themes":["nebula"]}'
  printf '#!/usr/bin/env python3\nimport sys\nsys.exit(1)\n' > "${TREE}/scripts/render-theme-wallpapers.py"
  publish
  ok
  [ "$(on_main upstream/theme-uniforms.json)" = '{"themes":["nebula"]}' ]
  [[ "$stderr" == *"keeping the site's last copy"* ]]
}

# git, logging every call; on the first push, somebody else's commit lands on
# main first, so that push is rejected the way a lost race really is.
git_wrapper() {
  export GITLOG="${BATS_TEST_TMPDIR}/git.log" CREDLOG="${BATS_TEST_TMPDIR}/cred.log" RACE="${1:-no}"
  cat > "${BIN}/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${GITLOG}"
for a in "\$@"; do
  case "\${a}" in "credential.helper=store --file="*) cat "\${a#credential.helper=store --file=}" >> "\${CREDLOG}" ;; esac
done
if [ "\${RACE}" = yes ] && [[ " \$* " == *" push "* ]] && [ ! -e "${BATS_TEST_TMPDIR}/raced" ]; then
  touch "${BATS_TEST_TMPDIR}/raced"
  w="${BATS_TEST_TMPDIR}/other"
  "${REAL_GIT}" clone -q "${SITE}" "\${w}"
  echo "a hand-written fix" > "\${w}/NOTES"
  "${REAL_GIT}" -C "\${w}" add NOTES
  "${REAL_GIT}" -C "\${w}" commit -q -m "somebody else"
  "${REAL_GIT}" -C "\${w}" push -q origin main
fi
exec "${REAL_GIT}" "\$@"
EOF
  chmod +x "${BIN}/git"
}

@test "a push that loses a race is redone on top of the commit that won it" {
  git_wrapper yes
  publish
  ok
  [ -e "${BATS_TEST_TMPDIR}/raced" ]
  [[ "$output" == *"site commit published (attempt 2)"* ]]
  # both survive: the other commit, and this build's on top of it
  [ "$(git -C "${SITE}" log -1 --format=%s main^)" = "somebody else" ]
  [ "$(on_main NOTES)" = "a hand-written fix" ]
  [ "$(on_main src/data/manifest.json | jq -r .version)" = "${VERSION}" ]
  grep -qx 'sleep 5' "${CALLS}"
}

@test "a site push that never lands fails the night after three attempts" {
  printf '#!/usr/bin/env bash\necho "pre-receive: declined" >&2\nexit 1\n' > "${SITE}/hooks/pre-receive"
  chmod +x "${SITE}/hooks/pre-receive"
  publish
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"gave up publishing the site commit after 3 attempts"* ]]
  [ "$(grep '^sleep' "${CALLS}" | tr '\n' ' ')" = "sleep 5 sleep 10 sleep 15 " ]
  main_unmoved
}

@test "the site token reaches git in a credentials file, never an argument, and is gone afterwards" {
  echo sekrit-site > "${BATS_TEST_TMPDIR}/git.token"
  git_wrapper
  publish --git-token-file "${BATS_TEST_TMPDIR}/git.token"
  ok
  main_moved
  if grep -q sekrit-site "${GITLOG}"; then cat "${GITLOG}"; false; fi
  grep -q "^-c credential.helper=store --file=${WORK}/publish/git-credentials clone " "${GITLOG}"
  grep -q "credential.helper=store --file=${WORK}/publish/git-credentials push " "${GITLOG}"
  # git-credential-store's format: one URL per line, user and password in it
  [ "$(sort -u "${CREDLOG}")" = "https://x-access-token:sekrit-site@github.com" ]
  [ ! -e "${WORK}/publish/git-credentials" ]
}

@test "with no --branch and no GITHUB_REF_NAME the site commit lands on main" {
  run --separate-stderr "${TREE}/scripts/publish.sh" --version "${VERSION}" \
    --image ghcr.io/arclight-digital/pulsar --image-nvidia ghcr.io/arclight-digital/pulsar-nvidia \
    --work "${WORK}" --site-repo "file://${SITE}"
  ok
  main_moved
}

@test "GITHUB_REF_NAME names the site branch when --branch does not" {
  git -C "${SITE}" branch next main
  GITHUB_REF_NAME=next run --separate-stderr "${TREE}/scripts/publish.sh" --version "${VERSION}" \
    --image ghcr.io/arclight-digital/pulsar --image-nvidia ghcr.io/arclight-digital/pulsar-nvidia \
    --work "${WORK}" --site-repo "file://${SITE}"
  ok
  main_unmoved
  [ "$(git -C "${SITE}" log -1 --format=%s next)" = "site: package changelog for ${VERSION}" ]
}

@test "PULSAR_BUILD_WORK and PULSAR_SITE_REPO stand in for --work and --site-repo" {
  PULSAR_BUILD_WORK="${WORK}" PULSAR_SITE_REPO="file://${SITE}" \
    run --separate-stderr "${TREE}/scripts/publish.sh" --version "${VERSION}" \
    --image ghcr.io/arclight-digital/pulsar --image-nvidia ghcr.io/arclight-digital/pulsar-nvidia --branch main
  ok
  main_moved
  grep -q '^oras attach .*pulsar@sha256:aaaa' "${CALLS}"
}

@test "a stage left by an earlier run is not reused" {
  # A clone from a run against another site repo, still in the work dir.
  # Reusing it would fetch from, and push to, that repo instead.
  local decoy="${BATS_TEST_TMPDIR}/decoy.git"
  "${REAL_GIT}" clone -q --bare "${SITE}" "${decoy}"
  mkdir -p "${WORK}/publish"
  "${REAL_GIT}" clone -q "${decoy}" "${WORK}/publish/site"
  local decoy_before; decoy_before="$(git -C "${decoy}" rev-parse main)"
  publish
  ok
  main_moved
  [ "$(git -C "${decoy}" rev-parse main)" = "${decoy_before}" ]
}
