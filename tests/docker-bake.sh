#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker buildx bake --file "$repo_dir/docker-bake.hcl" --print go | jq -e '
  .target.go.dockerfile == "Containerfile.devbox"
  and .target.go.args.DOTFILES_COMMIT == "80e4e773eece899ae854445230688a42aca76d4b"
' >/dev/null

echo ok
