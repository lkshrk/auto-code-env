#!/usr/bin/env bash
set -euo pipefail

script=image/scripts/30-tools.sh

test "$(grep -Fxc '    omni --config "$OMNI_CONFIG" --yes sync --retry-failed' "$script")" = 1
grep -F -B1 'omni --config "$OMNI_CONFIG" --yes sync --retry-failed' "$script" \
  | grep -Fx '  if ! omni --config "$OMNI_CONFIG" --yes tools sync "$group"; then' >/dev/null

echo ok
