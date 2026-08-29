#!/usr/bin/env bash
set -euo pipefail

script=image/scripts/50-finalize.sh
path_line=$(grep -n -F 'PATH="$opt/.local/bin:$PATH"' "$script" | cut -d: -f1)
corepack_line=$(grep -n -F '"$opt/.local/bin/corepack" enable' "$script" | cut -d: -f1)

test -n "$path_line"
test "$path_line" -lt "$corepack_line"

echo ok
