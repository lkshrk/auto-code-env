#!/usr/bin/env bash
set -euo pipefail

before=${1:-}
after=${2:-}
platform=${PLATFORM:-linux/amd64}
large_layer_bytes=${LARGE_LAYER_BYTES:-5242880}
max_changed_bytes=${MAX_CHANGED_BYTES:-10485760}

[[ -n "$before" && -n "$after" ]] || {
  echo "usage: $0 <before-image> <after-image>" >&2
  exit 2
}

for tool in docker jq awk; do
  command -v "$tool" >/dev/null || { echo "layer-reuse: missing $tool" >&2; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

layers() {
  local ref=$1 output=$2 os=${platform%/*} arch=${platform#*/} raw digest
  raw="$tmp/index.json"
  docker buildx imagetools inspect --raw "$ref" > "$raw"
  if jq -e '.manifests' "$raw" >/dev/null; then
    digest=$(jq -r --arg os "$os" --arg arch "$arch" '.manifests[] | select(.platform.os == $os and .platform.architecture == $arch) | .digest' "$raw" | head -1)
    [[ -n "$digest" ]] || { echo "layer-reuse: platform not found: $platform in $ref" >&2; exit 1; }
    docker buildx imagetools inspect --raw "$ref@$digest" > "$raw"
  fi
  jq -r '.layers[] | [.digest, .size] | @tsv' "$raw" > "$output"
}

layers "$before" "$tmp/before"
layers "$after" "$tmp/after"

read -r changed_bytes large_layers < <(
  awk -v limit="$large_layer_bytes" '
    NR == FNR { seen[$1] = 1; next }
    !seen[$1] { bytes += $2; if ($2 > limit) large += 1 }
    END { print bytes + 0, large + 0 }
  ' "$tmp/before" "$tmp/after"
)

printf 'layer-reuse: changed=%s bytes large-layers=%s platform=%s\n' "$changed_bytes" "$large_layers" "$platform"
(( large_layers == 0 )) || { echo "layer-reuse: changed layer exceeds $large_layer_bytes bytes" >&2; exit 1; }
(( changed_bytes <= max_changed_bytes )) || { echo "layer-reuse: changed bytes exceed $max_changed_bytes" >&2; exit 1; }
