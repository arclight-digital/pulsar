#!/usr/bin/env bats
# /etc/gitconfig makes git keep HTTPS passwords in the keyring
# (git-credential-libsecret, over oo7's Secret Service) instead of
# ~/.git-credentials. Pinned here with a stand-in helper on PATH, so no test
# touches a real keyring: git asks libsecret by default, and a `helper =`
# with no value in the user's own config clears it, as the file's comment says.

setup() {
  SYS="${BATS_TEST_DIRNAME}/../system_files/etc/gitconfig"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin"
  cat >"$T/bin/git-credential-libsecret" <<'SH'
#!/bin/sh
echo "$1" >>"$CALLS"
[ "$1" = get ] && printf 'username=u\npassword=from-keyring\n'
exit 0
SH
  chmod +x "$T/bin/git-credential-libsecret"
  export PATH="$T/bin:$PATH" CALLS="$T/calls" GIT_CONFIG_SYSTEM="$SYS" \
    GIT_CONFIG_GLOBAL="$T/global" GIT_TERMINAL_PROMPT=0
  : >"$T/global"
}

fill() {
  printf 'protocol=https\nhost=example.invalid\n\n' | git credential fill
}

@test "git's default credential helper is libsecret" {
  [ "$(git config --system --get-all credential.helper)" = libsecret ]
  run fill
  [ "$status" -eq 0 ]
  [[ "$output" == *"password=from-keyring"* ]]
  [ "$(cat "$CALLS")" = get ]
}

@test "an empty helper line in the user's config clears the system's" {
  printf '[credential]\n\thelper =\n\thelper = "!f() { echo username=me; echo password=own; }; f"\n' >"$T/global"
  run fill
  [ "$status" -eq 0 ]
  [[ "$output" == *"password=own"* ]]
  [ ! -e "$CALLS" ]
}
