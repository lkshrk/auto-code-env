#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDENTITY="$SCRIPT_DIR/../shared/github-identity.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$TEST_ROOT/bin"
export GH_TOKEN=agent-tok
export GH_TOKEN_PERSONAL=personal-tok

# Stand-in for the real gh: reports the token it was given; `repo clone|fork` creates the checkout.
cat > "$TEST_ROOT/bin/gh" <<'GH'
#!/bin/sh
echo "token=$GH_TOKEN args=$*"
if [ "$1" = repo ] && { [ "$2" = clone ] || [ "$2" = fork ]; }; then
  name=$(basename "${3%.git}")
  git init -q "$name"
fi
GH
chmod 0755 "$TEST_ROOT/bin/gh"
export PATH="$HOME/.local/bin:$TEST_ROOT/bin:$PATH"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
expect() { [ "$2" = "$3" ] || fail "$1: expected '$3', got '$2'"; }

bash "$IDENTITY" install
[ -x "$HOME/.local/bin/github-identity" ] || fail "install did not place github-identity"
[ "$(command -v gh)" = "$HOME/.local/bin/gh" ] || fail "gh shim is not first on PATH"
expect "global author" "$(git config --global user.name)" agent-npa
expect "ssh rewrite" "$(git config --global --get-all url.https://github.com/.insteadOf | tr '\n' ' ')" "git@github.com: ssh://git@github.com/ "
expect "use http path" "$(git config --global credential.https://github.com.useHttpPath)" true

token() { gh "$@" | sed -n 's/^token=\([^ ]*\).*/\1/p'; }
expect "foreign -R" "$(token issue list -R OpenHands/OpenHands)" personal-tok
expect "foreign --repo=" "$(token pr list --repo=https://github.com/OpenHands/OpenHands)" personal-tok
expect "own -R" "$(token issue list -R loc-news/civora)" agent-tok
expect "no repo context" "$(cd "$TEST_ROOT" && token api user)" agent-tok

cred() { printf 'protocol=https\nhost=github.com\npath=%s\n\n' "$1" | git credential fill | sed -n 's/^password=//p'; }

mkdir -p "$TEST_ROOT/own" && cd "$TEST_ROOT/own"
git init -q && git remote add origin git@github.com:loc-news/civora.git
expect "own checkout gh" "$(token pr list)" agent-tok
expect "own checkout push" "$(cred loc-news/civora.git)" agent-tok
[ -z "$(git config --local user.name || true)" ] || fail "own checkout got a local author"

mkdir -p "$TEST_ROOT/fork" && cd "$TEST_ROOT/fork"
git init -q
git remote add origin https://github.com/lkshrk/OpenHands.git
git remote add upstream https://github.com/OpenHands/OpenHands.git
expect "fork checkout gh" "$(token pr create --fill)" personal-tok
expect "fork author" "$(git config --local user.name)" lkshrk
expect "fork author email" "$(git config --local user.email)" 5067446+lkshrk@users.noreply.github.com
expect "fork push to own fork" "$(cred lkshrk/OpenHands.git)" personal-tok
expect "push to foreign upstream" "$(cred OpenHands/OpenHands.git)" personal-tok

cd "$TEST_ROOT"
expect "foreign clone" "$(token repo clone OpenHands/software-agent-sdk)" personal-tok
expect "cloned checkout author" "$(git -C software-agent-sdk config --local user.name)" lkshrk
expect "own clone" "$(token repo clone routivo/app)" agent-tok
[ -z "$(git -C app config --local user.name || true)" ] || fail "own clone got a local author"

expect "whoami foreign" "$(bash "$IDENTITY" whoami OpenHands/OpenHands)" personal
expect "whoami own" "$(bash "$IDENTITY" whoami webdev-harke/site)" agent

# Without a personal token everything stays on the agent account.
unset GH_TOKEN_PERSONAL
expect "no personal token" "$(token issue list -R OpenHands/OpenHands)" agent-tok
cd "$TEST_ROOT/fork"
expect "no personal token push" "$(cred OpenHands/OpenHands.git)" agent-tok

printf 'PASS: github identity picks the account by repository owner\n'
