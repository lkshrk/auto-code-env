#!/usr/bin/env bash
set -euo pipefail
variant="${1:?variant}"
fail=0
# shellcheck disable=SC2001
check() { printf '%-28s' "$1"; if out=$(bash -lc "$2" 2>&1); then echo "ok  ${out%%$'\n'*}"; else echo "FAIL"; echo "$out" | sed 's/^/    /'; fail=1; fi; }

[ "$(id -u)" = 1000 ] || { echo "uid is $(id -u), want 1000"; fail=1; }
[ "$HOME" = /home/dev ] || { echo "HOME is $HOME"; fail=1; }
[ "$(stat -c %U /opt/devbox)" = root ] || { echo "/opt/devbox not root-owned"; fail=1; }
touch /opt/devbox/x 2>/dev/null && { echo "/opt/devbox writable"; fail=1; }

check "omni"        "omni --version"
check "claude"      "claude --version"
check "codex"       "codex --version"
check "gh"          "gh --version"
check "bun"         "bun --version"
check "node"        "node --version"
check "uv"          "uv --version"
check "nvim"        "nvim --version | head -1"
check "tmux"        "tmux -V"
check "zsh"         "zsh --version"

case "$variant" in
  go|full|hermes|pilot)      check "go" "go version"; check "golangci-lint" "golangci-lint --version" ;;
esac
case "$variant" in
  python|full|hermes|pilot)  check "python" "python3 --version"; check "pyright" "pyright --version" ;;
esac
case "$variant" in
  ts|full|hermes|pilot)      check "pnpm" "pnpm --version"; check "playwright deps" "ldconfig -p | grep -q libnss3" ;;
esac
case "$variant" in
  lua|full|hermes|pilot)     check "lua-language-server" "lua-language-server --version"; check "stylua" "stylua --version" ;;
esac
case "$variant" in
  full|hermes|pilot)         check "kubectl" "kubectl version --client"; check "flux" "flux --version"; check "helm" "helm version --short" ;;
esac
case "$variant" in
  hermes) check "hermes" "hermes --version"; check "hermes (foreign HOME)" "HOME=/tmp/h$$ hermes --version" ;;
  pilot)  check "pilot"  "pilot version";    check "pilot (foreign HOME)"  "HOME=/tmp/p$$ pilot version" ;;
esac

[ "${DEVBOX_SMOKE_OFFLINE:-0}" = 1 ] || check "devbox-init dots"  "DEVBOX_DOTS=1 HOME=/tmp/init$$ devbox-init true"
check "devbox-init nodots" "DEVBOX_DOTS=0 devbox-init true"

if grep -rEIl 'ghp_[A-Za-z0-9]{36}|sk-ant-[A-Za-z0-9_-]{20,}|-----BEGIN (RSA|OPENSSH|EC) PRIVATE KEY' /opt/devbox /etc 2>/dev/null | head -1 | grep -q .; then
  echo "token-like string found in image"; fail=1
fi

exit $fail
