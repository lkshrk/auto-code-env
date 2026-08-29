#!/usr/bin/env bash
set -euo pipefail

test "$(grep -Fxc '  [ "$(stat -c %a "$HOME/.codex/auth.json" 2>/dev/null || stat -f %Lp "$HOME/.codex/auth.json")" = "600" ]' tests/devbox-init.bats)" = 1
test "$(grep -Fxc '  [ "$(stat -c %a "$HOME/.tmp" 2>/dev/null || stat -f %Lp "$HOME/.tmp")" = "700" ]' tests/devbox-init.bats)" = 1
test "$(grep -Fxc '  [ "$(stat -c %a "$HOME/.ssh" 2>/dev/null || stat -f %Lp "$HOME/.ssh")" = "700" ]' tests/devbox-init.bats)" = 1
grep -Fx '  -c) /usr/bin/stat -c %a "$3" ;;' tests/helpers/gnu-stat/stat >/dev/null

echo ok
