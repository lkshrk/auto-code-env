#!/usr/bin/env bash
set -euo pipefail
opt=/opt/devbox

shopt -s nullglob
node_bin=$(printf '%s\n' "$opt"/.nvm/versions/node/*/bin | sort -V | tail -1)
if [ -n "$node_bin" ]; then
  for b in node npm npx corepack; do
    [ -x "$node_bin/$b" ] && ln -sf "$node_bin/$b" "$opt/.local/bin/$b"
  done
  PATH="$opt/.local/bin:$PATH"
  "$opt/.local/bin/corepack" enable --install-directory "$opt/.local/bin" pnpm
  COREPACK_HOME="$opt/.corepack" "$opt/.local/bin/corepack" install --global pnpm
fi

rm -rf "$opt"/.cache "$opt"/.npm "$opt"/.bun/install/cache "$opt"/go/pkg/mod/cache "$opt"/.tmp
find "$opt" -name '*.pyc' -delete

chown -R root:root "$opt"
chmod -R u=rwX,go=rX "$opt"
