#!/usr/bin/env bats
# The preflight: every credential a night will need, tried in its first
# minute instead of when it is first used.
#
# The site's git token expired on 2026-09-05 and nothing noticed for four
# days: it is first used by the site commit, an hour in, after the images are
# public. The signer is first called twenty-five minutes into the nvidia
# build. These pin the checks that move both to the start, and the rule that
# a token near its expiry is named while there is time to renew it.
#
# curl is a stub playing both the signer and api.github.com, driven by the
# variables below, so no test touches a network.

bats_require_minimum_version 1.5.0

setup() {
  for v in "${!PULSAR_@}"; do unset "${v}"; done
  unset REGISTRY_AUTH_FILE
  NIGHTLY="${BATS_TEST_DIRNAME}/../scripts/nightly.sh"
  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${BIN}"
  PATH="${BIN}:${PATH}"
  export IMAGE=ghcr.io/arclight-digital/pulsar IMAGE_NVIDIA=ghcr.io/arclight-digital/pulsar-nvidia
  export PULSAR_CHANNEL=scheduled
  # The requests the stub saw, one per line: URL and the auth header's file
  # contents, so a test can prove the token never rode in an argument.
  export CURL_LOG="${BATS_TEST_TMPDIR}/curl.log"
  : > "${CURL_LOG}"
  export SIGNER_OK=yes GH_CODE=200 GH_PUSH=true GH_SCOPES="repo, write:packages" GH_EXPIRY=
  stub_curl
}

stub_curl() {
  cat > "${BIN}/curl" <<'STUB'
#!/usr/bin/env bash
out=/dev/null hdr= url= auth= wfmt=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -D) hdr="$2"; shift ;;
    -w) wfmt="$2"; shift ;;
    -H) case "$2" in @*) auth="$(cat "${2#@}")" ;; *) auth="ARG:$2" ;; esac; shift ;;
    --cacert|--max-time|--data-binary|--retry) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s %s\n' "${url}" "${auth}" >> "${CURL_LOG}"
case "${url}" in
  */cert)
    [ "${SIGNER_OK}" = yes ] || exit 22
    echo cert > "${out}"; exit 0 ;;
  https://api.github.com/*)
    {
      printf 'HTTP/2 %s\r\n' "${GH_CODE}"
      [ -z "${GH_SCOPES}" ] || printf 'x-oauth-scopes: %s\r\n' "${GH_SCOPES}"
      [ -z "${GH_EXPIRY}" ] || printf 'github-authentication-token-expiration: %s\r\n' "${GH_EXPIRY}"
    } > "${hdr:-/dev/null}"
    printf '{"permissions":{"push":%s}}' "${GH_PUSH}" > "${out}"
    [ -z "${wfmt}" ] || printf '%s' "${GH_CODE}"
    exit 0 ;;
esac
exit 7
STUB
  chmod +x "${BIN}/curl"
}

signer() {
  export PULSAR_SIGNER_URL=https://10.0.0.5:8443
  export PULSAR_SIGNER_TOKEN_FILE="${BATS_TEST_TMPDIR}/signer.token"
  echo sekrit-signer > "${PULSAR_SIGNER_TOKEN_FILE}"
}

git_token() {
  export PULSAR_GIT_TOKEN_FILE="${BATS_TEST_TMPDIR}/git.token"
  echo sekrit-git > "${PULSAR_GIT_TOKEN_FILE}"
}

ghcr_login() {
  export REGISTRY_AUTH_FILE="${BATS_TEST_TMPDIR}/auth.json"
  printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "$(printf 'bot:sekrit-ghcr' | base64 -w0)" > "${REGISTRY_AUTH_FILE}"
}

preflight() {
  run --separate-stderr "${NIGHTLY}" --preflight
}

@test "nothing configured checks nothing, and says so" {
  preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"signer: not configured here"* ]]
  [[ "$output" == *"site commit token: not configured here"* ]]
  [ ! -s "${CURL_LOG}" ]
}

@test "everything usable passes" {
  signer; git_token; ghcr_login
  preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"signer: answers"* ]]
  [[ "$output" == *"ghcr.io push token: usable"* ]]
  [[ "$output" == *"site commit token: usable"* ]]
}

@test "REGRESSION: a signer that does not answer fails the night in its first minute" {
  signer
  SIGNER_OK=no preflight
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"did not answer /cert"* ]]
}

@test "REGRESSION: an expired site token fails before anything is built" {
  # 2026-09-05: the token expired, and the site learned nothing for four days.
  git_token
  GH_CODE=401 preflight
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"GitHub rejects the site commit token (401)"* ]]
}

@test "a site token that cannot push is refused" {
  git_token
  GH_PUSH=false preflight
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"cannot push to arclight-digital/pulsar"* ]]
}

@test "a registry token without write:packages is refused" {
  ghcr_login
  GH_SCOPES="read:packages" preflight
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"lacks write:packages"* ]]
}

@test "a token near its expiry is named, and still passes" {
  git_token
  GH_EXPIRY="$(date -u -d '+5 days' '+%Y-%m-%d %H:%M:%S UTC')" preflight
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"site commit token expires in"* ]]
  [[ "$stderr" == *"renew it"* ]]
}

@test "a token far from expiry is not a warning" {
  git_token
  GH_EXPIRY="$(date -u -d '+200 days' '+%Y-%m-%d %H:%M:%S UTC')" preflight
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"WARNING"* ]]
}

@test "GitHub being unreachable is a warning, not a failed night" {
  git_token
  rm "${BIN}/curl"
  printf '#!/usr/bin/env bash\nexit 6\n' > "${BIN}/curl"; chmod +x "${BIN}/curl"
  preflight
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"could not reach api.github.com"* ]]
}

@test "no token ever rides in an argument" {
  signer; git_token; ghcr_login
  preflight
  [ "$status" -eq 0 ]
  # not a negated grep: bats ignores one anywhere but a test's last line
  if grep -q 'ARG:' "${CURL_LOG}"; then cat "${CURL_LOG}"; false; fi
  grep -q 'Bearer sekrit-signer' "${CURL_LOG}"
  grep -q 'token sekrit-git' "${CURL_LOG}"
  grep -q 'token sekrit-ghcr' "${CURL_LOG}"
}
