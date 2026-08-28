#!/usr/bin/env bash
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: 30-tools.sh GROUP..." >&2; exit 2; }

export HOME=/opt/devbox
export OMNI_HOSTNAME=devbox
export OMNI_CONFIG="$HOME/dotfiles/dotfiles/omni/.config/omni/settings.json"
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/go/bin:$HOME/.cargo/bin:$PATH"
cd "$HOME"

if [ -s /run/secrets/github_token ]; then
  GITHUB_TOKEN=$(cat /run/secrets/github_token)
  export GITHUB_TOKEN
fi

sudo apt-get update -qq
for group in "$@"; do
  omni --config "$OMNI_CONFIG" --yes tools sync "$group"
done
sudo rm -rf /var/lib/apt/lists/*
