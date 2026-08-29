#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

run_container() {
  docker run --rm --platform linux/amd64 --tmpfs /opt:rw,mode=755,size=512m -v "$repo_root:/src:ro" ubuntu:26.04 bash -euo pipefail -c "$1"
}

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /src/runtimes/wsl/provision.sh
  bash /src/runtimes/wsl/provision.sh

  test "$(getent passwd agent | cut -d: -f6,7)" = "/home/agent:/bin/bash"
  test "$(id -nG agent)" = "agent"
  ! id -nG agent | tr " " "\n" | grep -qx sudo
  test -d /home/agent
  ! test -L /home/agent

  for path in /home/agent /home/agent/.openhands /home/agent/.claude /home/agent/.codex /home/agent/workspaces; do
    test "$(stat -c "%U:%G %a" "$path")" = "agent:agent 700"
  done
  test "$(stat -c "%U:%G %a" /etc/wsl.conf)" = "root:root 644"
  cmp -s /etc/wsl.conf /src/runtimes/wsl/wsl.conf

  test "$(node --version)" = "v22.23.2"
  test "$(npm --version)" = "10.9.8"
  test "$(npx --version)" = "10.9.8"
  test "$(uv --version)" = "uv 0.12.7"
  test "$(uvx --version)" = "uvx 0.12.7"
  test "$(stat -c "%U:%G %a" /opt/openhands)" = "root:root 755"
  test "$(stat -c "%U:%G %a" /opt/openhands/node-v22.23.2-linux-x64)" = "root:root 755"
  for path in /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/uv /usr/local/bin/uvx; do
    test "$(stat -c "%U:%G %a" "$path")" = "root:root 755"
  done

  ! su -s /bin/sh agent -c "WSL_DISTRO_NAME=openhands-worker bash /src/runtimes/wsl/provision.sh"
  ! env WSL_DISTRO_NAME=wrong-distro bash /src/runtimes/wsl/provision.sh
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /src/runtimes/wsl/provision.sh
  printf corrupt > /opt/openhands/node-v22.23.2-linux-x64/bin/node
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test "$(cat /opt/openhands/node-v22.23.2-linux-x64/bin/node)" = corrupt
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /src/runtimes/wsl/provision.sh
  rm /usr/local/bin/uv
  printf foreign > /usr/local/bin/uv
  chmod 0755 /usr/local/bin/uv
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test "$(cat /usr/local/bin/uv)" = foreign
'

run_container '
  ln -s /src/runtimes/wsl/provision.sh /tmp/provision
  env WSL_DISTRO_NAME=openhands-worker bash /tmp/provision
  cmp -s /etc/wsl.conf /src/runtimes/wsl/wsl.conf
'

run_container '
  mkdir /tmp/assets
  cp /src/runtimes/wsl/provision.sh /tmp/assets/provision.sh
  ln -s /src/runtimes/wsl/wsl.conf /tmp/assets/wsl.conf
  if env WSL_DISTRO_NAME=openhands-worker bash /tmp/assets/provision.sh; then
    exit 1
  fi
  test -L /tmp/assets/wsl.conf
'

run_container '
  useradd --create-home --shell /bin/sh --user-group agent
  if env WSL_DISTRO_NAME=openhands-worker bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
'

run_container '
  useradd --create-home --home-dir /srv/agent --shell /bin/bash --user-group agent
  if env WSL_DISTRO_NAME=openhands-worker bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
'

run_container '
  mkdir /home/agent
  if env WSL_DISTRO_NAME=openhands-worker bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  ! id agent >/dev/null 2>&1
  test "$(stat -c "%U:%G %a" /home/agent)" = "root:root 755"
'

run_container '
  useradd --create-home --shell /bin/bash --user-group agent
  getent group sudo >/dev/null || groupadd sudo
  usermod -aG sudo agent
  if env WSL_DISTRO_NAME=openhands-worker bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
'

run_container '
  ln -s /tmp /home/agent
  if env WSL_DISTRO_NAME=openhands-worker bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  ! id agent >/dev/null 2>&1
  test -L /home/agent
'

run_container '
  useradd --create-home --shell /bin/bash --user-group agent
  chown root:root /home/agent
  if env WSL_DISTRO_NAME=openhands-worker bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
'

run_container '
  useradd --create-home --shell /bin/bash --user-group agent
  ln -s /tmp /home/agent/.codex
  if env WSL_DISTRO_NAME=openhands-worker bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test -L /home/agent/.codex
'

run_container '
  useradd --create-home --shell /bin/bash --user-group agent
  touch /home/agent/.claude
  if env WSL_DISTRO_NAME=openhands-worker bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test -f /home/agent/.claude
'

run_container '
  useradd --create-home --shell /bin/bash --user-group agent
  chmod 0700 /home/agent
  mkdir /home/agent/.codex
  chown root:root /home/agent/.codex
  chmod 0700 /home/agent/.codex
  if env WSL_DISTRO_NAME=openhands-worker bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test "$(stat -c "%U:%G %a" /home/agent/.codex)" = "root:root 700"
'

run_container '
  useradd --create-home --shell /bin/bash --user-group agent
  useradd --create-home --shell /bin/bash --user-group other
  chmod 0700 /home/agent
  mkdir /home/agent/.claude
  chown other:other /home/agent/.claude
  chmod 0700 /home/agent/.claude
  if env WSL_DISTRO_NAME=openhands-worker bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test "$(stat -c "%U:%G %a" /home/agent/.claude)" = "other:other 700"
'

run_container '
  useradd --create-home --shell /bin/bash --user-group agent
  chmod 0700 /home/agent
  mkdir /home/agent/workspaces
  chown agent:agent /home/agent/workspaces
  chmod 0755 /home/agent/workspaces
  if env WSL_DISTRO_NAME=openhands-worker bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test "$(stat -c "%U:%G %a" /home/agent/workspaces)" = "agent:agent 755"
'

run_container '
  useradd --create-home --shell /bin/bash --user-group agent
  chmod 0700 /home/agent
  printf victim > /tmp/victim
  chmod 0600 /tmp/victim
  ln -s /tmp/victim /home/agent/.codex
  if env WSL_DISTRO_NAME=openhands-worker bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test "$(cat /tmp/victim)" = victim
  test "$(stat -c "%U:%G %a" /tmp/victim)" = "root:root 600"
'

run_container '
  ln -s /tmp /etc/wsl.conf
  if env WSL_DISTRO_NAME=openhands-worker bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test -L /etc/wsl.conf
'

run_container '
  mkdir /etc/wsl.conf
  if env WSL_DISTRO_NAME=openhands-worker bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test ! -e /etc/wsl.conf/wsl.conf
'
