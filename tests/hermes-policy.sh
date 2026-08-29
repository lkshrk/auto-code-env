#!/usr/bin/env bash
set -euo pipefail

stage=$(awk '/^FROM stack-full AS stack-hermes/{inside=1} /^FROM stack-full AS stack-pilot/{inside=0} inside' image/Containerfile.devbox)
install_line=$(printf '%s\n' "$stage" | grep -n -F 'sudo apt-get install -y --no-install-recommends build-essential' | cut -d: -f1)
sync_line=$(printf '%s\n' "$stage" | grep -n -F '/opt/devbox-build/30-tools.sh agent-hermes' | cut -d: -f1)
purge_line=$(printf '%s\n' "$stage" | grep -n -F 'sudo apt-get purge -y --auto-remove build-essential' | cut -d: -f1)
clean_line=$(printf '%s\n' "$stage" | grep -n -F 'sudo rm -rf /var/lib/apt/lists/*' | cut -d: -f1)

test "$install_line" -lt "$sync_line"
test "$sync_line" -lt "$purge_line"
test "$purge_line" -lt "$clean_line"

echo ok
