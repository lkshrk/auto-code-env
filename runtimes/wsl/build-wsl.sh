#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s VERSION ARCH OUTPUT_DIR\n' "${0##*/}" >&2
  exit 64
}

version=${1:-}
arch=${2:-}
output_dir=${3:-}

case $version in
  ''|*/*|*[^0-9A-Za-z._-]*) usage ;;
esac

case $arch in
  amd64|arm64) ;;
  *) usage ;;
esac

test -n "$output_dir" || usage
mkdir -p -- "$output_dir"
output_dir=$(cd "$output_dir" && pwd -P)

artifact_name="openhands-worker-${version}-${arch}.wsl"
artifact="$output_dir/$artifact_name"
checksum="$artifact.sha256"
if test -e "$artifact" || test -L "$artifact" || test -e "$checksum" || test -L "$checksum"; then
  printf 'refusing to overwrite artifact: %s\n' "$artifact" >&2
  exit 1
fi

temporary_artifact=$(mktemp "$output_dir/.${artifact_name}.XXXXXX")
temporary_checksum=$(mktemp "$output_dir/.${artifact_name}.sha256.XXXXXX")
artifact_linked=false
checksum_linked=false
published=false
cleanup() {
  if ! "$published"; then
    if "$checksum_linked" && test "$temporary_checksum" -ef "$checksum"; then
      rm -f -- "$checksum"
    fi
    if "$artifact_linked" && test "$temporary_artifact" -ef "$artifact"; then
      rm -f -- "$artifact"
    fi
  fi
  rm -f -- "$temporary_artifact" "$temporary_checksum"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
rm -f -- "$temporary_artifact" "$temporary_checksum"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
cd "$repo_root"
docker buildx bake --allow="fs.write=$output_dir" -f runtimes/wsl/docker-bake.hcl "wsl-${arch}" \
  --set "wsl-${arch}.output=type=tar,dest=${temporary_artifact}"
test -f "$temporary_artifact"

checksum_value=$(sha256sum -- "$temporary_artifact" | awk '{print $1}')
printf '%s  %s\n' "$checksum_value" "$artifact_name" > "$temporary_checksum"
artifact_linked=true
ln -- "$temporary_artifact" "$artifact"
checksum_linked=true
ln -- "$temporary_checksum" "$checksum"
published=true
