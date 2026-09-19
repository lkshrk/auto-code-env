#!/usr/bin/env bash

set -euo pipefail

omni_release_base() {
  if [[ -z "${OMNI_VERSION:-}" ]]; then
    printf '%s\n' 'https://github.com/lkshrk/omni/releases/latest/download'
  elif [[ "$OMNI_VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'https://github.com/lkshrk/omni/releases/download/v%s\n' "${OMNI_VERSION#v}"
  else
    printf 'OMNI_VERSION must be an exact release version (for example 0.10.14)\n' >&2
    return 1
  fi
}

install_omni_release() (
  local base bin_dir arch os tmpdir
  base="$(omni_release_base)"
  bin_dir="${DIR:-$HOME/.local/bin}"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64*|arm64) arch=arm64 ;;
    *) printf 'unsupported architecture for omni install: %s\n' "$arch" >&2; exit 1 ;;
  esac
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  curl -fsSL "$base/omni_${os}_${arch}.tar.gz" -o "$tmpdir/omni.tar.gz"
  tar -xzf "$tmpdir/omni.tar.gz" -C "$tmpdir" omni
  mkdir -p "$bin_dir"
  install -Dm 755 "$tmpdir/omni" "$bin_dir/omni"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  install_omni_release
fi
