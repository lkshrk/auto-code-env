#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVBOX_VERSION=2026.8.0 DEVBOX_REVISION=deadbeef \
  docker buildx bake --file "$repo_dir/docker-bake.hcl" --print devbox-go | jq -e '
  .target["devbox-go"].dockerfile == "Containerfile.devbox"
  and .target["devbox-go"].args.DOTFILES_COMMIT == "80e4e773eece899ae854445230688a42aca76d4b"
  and .target["devbox-go"].tags == ["ghcr.io/lkshrk/devbox/go:2026.8.0", "ghcr.io/lkshrk/devbox/go:latest"]
  and .target["devbox-go"].labels["org.opencontainers.image.revision"] == "deadbeef"
' >/dev/null

echo ok
