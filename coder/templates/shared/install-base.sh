#!/usr/bin/env bash
set -euo pipefail

coder_missing_packages() {
  local package
  for package in "$@"; do
    if [[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)" != 'install ok installed' ]]; then
      printf '%s\n' "$package"
    fi
  done
}

coder_install_base() {
  command -v apt-get >/dev/null 2>&1 || return 0
  local -a packages missing
  packages=(ca-certificates curl git jq openssh-client python3)
  if [[ "${CODER_ENVIRONMENT_MODE:-legacy}" == legacy ]]; then
    packages+=(build-essential node-gyp nodejs npm stow tmux unzip)
    case ",${CODER_OMNI_STACKS:-}," in
      *,go,*) packages+=(golang-go) ;;
    esac
  fi
  mapfile -t missing < <(coder_missing_packages "${packages[@]}")
  if (( ${#missing[@]} )); then
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  coder_install_base
fi
