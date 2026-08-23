#!/usr/bin/env bash
set -euo pipefail
opt=/opt/devbox

# shellcheck disable=SC2012
node_bin=$(ls -d "$opt"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$node_bin" ]; then
  for b in node npm npx corepack; do
    [ -x "$node_bin/$b" ] && ln -sf "$node_bin/$b" "$opt/.local/bin/$b"
  done
fi

rm -rf "$opt"/.cache "$opt"/.npm "$opt"/.bun/install/cache "$opt"/go/pkg/mod/cache "$opt"/.tmp
find "$opt" -name '*.pyc' -delete

chown -R root:root "$opt"
chmod -R u=rwX,go=rX "$opt"
