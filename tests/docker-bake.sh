#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

normalize_calver() {
  local tag=$1 version
  [[ $tag == v* ]]
  version=${tag#v}
  [[ $version =~ ^[0-9]{4}\.[0-9]{1,2}\.[0-9]+$ ]]
  printf '%s\n' "$version"
}

test "$(normalize_calver v2026.8.1)" = 2026.8.1
! normalize_calver vnot-calver >/dev/null 2>&1
! normalize_calver 2026.8.1 >/dev/null 2>&1

DEVBOX_VERSION=2026.8.0 DEVBOX_REVISION=deadbeef \
  docker buildx bake --file "$repo_dir/docker-bake.hcl" --print devbox-go | jq -e '
  .target["devbox-go"].dockerfile == "Containerfile.devbox"
  and .target["devbox-go"].args.DOTFILES_COMMIT == "80e4e773eece899ae854445230688a42aca76d4b"
  and .target["devbox-go"].tags == ["ghcr.io/lkshrk/devbox/go:2026.8.0", "ghcr.io/lkshrk/devbox/go:latest"]
  and .target["devbox-go"].labels["org.opencontainers.image.revision"] == "deadbeef"
' >/dev/null

echo ok
