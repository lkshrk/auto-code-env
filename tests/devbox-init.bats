#!/usr/bin/env bats

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export FAKE_LOG="$BATS_TEST_TMPDIR/log"
  : > "$FAKE_LOG"
  export PATH="$BATS_TEST_DIRNAME/helpers/fake-bin:$PATH"
  export DEVBOX_INIT="$BATS_TEST_DIRNAME/../image/scripts/devbox-init"
  unset DEVBOX_DOTS CODEX_AUTH_JSON
}

@test "clones dotfiles when missing and syncs dots" {
  run "$DEVBOX_INIT" true
  [ "$status" -eq 0 ]
  grep -q "git clone --quiet https://github.com/lkshrk/dotfiles.git $HOME/dotfiles" "$FAKE_LOG"
  grep -q "omni --yes dots sync --use-repo" "$FAKE_LOG"
}

@test "fetches but never resets an existing checkout" {
  mkdir -p "$HOME/dotfiles/.git"
  run "$DEVBOX_INIT" true
  [ "$status" -eq 0 ]
  grep -q "git -C $HOME/dotfiles fetch --quiet origin" "$FAKE_LOG"
  ! grep -qE "git .*(reset|clean|checkout|pull)" "$FAKE_LOG"
}

@test "refuses a non-git dotfiles dir" {
  mkdir -p "$HOME/dotfiles"
  run "$DEVBOX_INIT" true
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a git checkout"* ]]
}

@test "DEVBOX_DOTS=0 skips dots sync" {
  DEVBOX_DOTS=0 run "$DEVBOX_INIT" true
  [ "$status" -eq 0 ]
  ! grep -q "dots sync" "$FAKE_LOG"
}

@test "writes codex auth from env with mode 0600" {
  CODEX_AUTH_JSON='{"k":"v"}' run "$DEVBOX_INIT" true
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.codex/auth.json")" = '{"k":"v"}' ]
  [ "$(stat -f %Lp "$HOME/.codex/auth.json" 2>/dev/null || stat -c %a "$HOME/.codex/auth.json")" = "600" ]
}

@test "creates tmp and ssh dirs with strict modes" {
  run "$DEVBOX_INIT" true
  [ "$status" -eq 0 ]
  [ "$(stat -f %Lp "$HOME/.tmp" 2>/dev/null || stat -c %a "$HOME/.tmp")" = "700" ]
  [ "$(stat -f %Lp "$HOME/.ssh" 2>/dev/null || stat -c %a "$HOME/.ssh")" = "700" ]
}

@test "execs the given command and propagates its exit code" {
  run "$DEVBOX_INIT" sh -c 'exit 7'
  [ "$status" -eq 7 ]
}

@test "never echoes env values" {
  CODEX_AUTH_JSON='SECRETVALUE' run "$DEVBOX_INIT" true
  [[ "$output" != *SECRETVALUE* ]]
}
