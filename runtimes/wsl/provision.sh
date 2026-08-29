#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' 'provisioning must run as root' >&2
    exit 1
fi

if [ "${WSL_DISTRO_NAME:-}" != 'openhands-worker' ]; then
    printf '%s\n' 'provisioning must run in openhands-worker' >&2
    exit 1
fi

if ! id agent >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --user-group agent
fi

install -d -o agent -g agent -m 0700 \
    /home/agent/.openhands \
    /home/agent/.claude \
    /home/agent/.codex \
    /home/agent/workspaces
install -o root -g root -m 0644 "$(dirname "$0")/wsl.conf" /etc/wsl.conf
