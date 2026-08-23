#!/usr/bin/env bash
set -euo pipefail
export HOME=/opt/devbox
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

sudo apt-get update -qq
bunx --bun playwright install-deps chromium firefox
sudo rm -rf /var/lib/apt/lists/*
