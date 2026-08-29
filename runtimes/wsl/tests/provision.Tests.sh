#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
fixture_image=auto-code-env-wsl-stage5a-fixture:ubuntu-26.04

ensure_fixture_image() {
  if docker image inspect "$fixture_image" >/dev/null 2>&1; then
    return
  fi
  printf '%s\n' \
    'FROM ubuntu:26.04' \
    'RUN apt-get update && apt-get install -y --no-install-recommends xz-utils && rm -rf /var/lib/apt/lists/*' |
    docker build --quiet --tag "$fixture_image" -
}

setup_fixture() {
  local node_archive=node-v24.20.0-linux-x64.tar.xz
  local node_directory=node-v24.20.0-linux-x64
  local reserved_node_archive=reserved-node-v24.20.0-linux-x64.tar.xz
  local uv_archive=uv-x86_64-unknown-linux-gnu.tar.gz
  local uv_directory=uv-x86_64-unknown-linux-gnu

  mkdir -p "/tmp/fixture-src/$node_directory/bin"
  mkdir -p "/tmp/fixture-src/$node_directory/lib/node_modules/npm/bin"
  mkdir -p "/tmp/fixture-src/$node_directory/lib/node_modules/npm/node_modules/example"
  mkdir -p "/tmp/fixture-src/$uv_directory" /fixtures

  printf '%s\n' \
    '#!/bin/sh' \
    'case "${1:-}" in' \
    '  --version) printf "%s\n" v24.20.0 ;;' \
    '  */npm-cli.js|*/npx-cli.js) test "${2:-}" = --version && printf "%s\n" 11.19.0 ;;' \
    '  *) exit 64 ;;' \
    'esac' > "/tmp/fixture-src/$node_directory/bin/node"
  chmod 0755 "/tmp/fixture-src/$node_directory/bin/node"
  printf '%s\n' 'fixture npm cli' > "/tmp/fixture-src/$node_directory/lib/node_modules/npm/bin/npm-cli.js"
  printf '%s\n' 'fixture npx cli' > "/tmp/fixture-src/$node_directory/lib/node_modules/npm/bin/npx-cli.js"
  printf '%s\n' 'fixture dependency' > "/tmp/fixture-src/$node_directory/lib/node_modules/npm/node_modules/example/index.js"
  ln -s ../lib/node_modules/npm/bin/npm-cli.js "/tmp/fixture-src/$node_directory/bin/npm"
  ln -s ../lib/node_modules/npm/bin/npx-cli.js "/tmp/fixture-src/$node_directory/bin/npx"
  tar -cJf "/fixtures/$node_archive" -C /tmp/fixture-src "$node_directory"
  printf '%s\n' counterfeit > "/tmp/fixture-src/$node_directory/.openhands-manifest"
  tar -cJf "/fixtures/$reserved_node_archive" -C /tmp/fixture-src "$node_directory"
  rm "/tmp/fixture-src/$node_directory/.openhands-manifest"
  test "$(od -An -tx1 -N6 "/fixtures/$node_archive" | tr -d ' \n')" = fd377a585a00

  printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\n" "${FIXTURE_UV_VERSION_OUTPUT:-uv 0.12.7 (a0b1c2d3 2026-08-29 x86_64-unknown-linux-gnu)}"' \
    > "/tmp/fixture-src/$uv_directory/uv"
  printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\n" "${FIXTURE_UVX_VERSION_OUTPUT:-uvx 0.12.7 (a0b1c2d3 2026-08-29 x86_64-unknown-linux-gnu)}"' \
    > "/tmp/fixture-src/$uv_directory/uvx"
  chmod 0755 "/tmp/fixture-src/$uv_directory/uv" "/tmp/fixture-src/$uv_directory/uvx"
  tar -czf "/fixtures/$uv_archive" -C /tmp/fixture-src "$uv_directory"

  cp /usr/bin/mv /usr/bin/mv.fixture-real
  printf '%s\n' \
    '#!/bin/sh' \
    'test "$PATH" = /usr/sbin:/usr/bin:/sbin:/bin || exit 73' \
    'last=' \
    'for argument do last=$argument; done' \
    'if test -n "${FIXTURE_FAIL_RENAME_DEST:-}" && test "$last" = "$FIXTURE_FAIL_RENAME_DEST"; then' \
    '  printf "%s\n" "$last" >> /tmp/rename-failures' \
    '  exit 70' \
    'fi' \
    'exec /usr/bin/mv.fixture-real "$@"' > /usr/bin/mv
  printf '%s\n' \
    '#!/bin/sh' \
    'test "$PATH" = /usr/sbin:/usr/bin:/sbin:/bin || exit 73' \
    'printf "%s\n" "$*" >> /tmp/apt-calls' \
    'case "$*" in' \
    '  update|"install -y --no-install-recommends ca-certificates curl xz-utils") exit 0 ;;' \
    '  *) exit 71 ;;' \
    'esac' > /usr/bin/apt-get
  printf '%s\n' '#!/bin/sh' 'printf "%s\n" "${FIXTURE_UNAME:-x86_64}"' > /usr/bin/uname
  printf '%s\n' \
    '#!/bin/sh' \
    'test "$PATH" = /usr/sbin:/usr/bin:/sbin:/bin || exit 73' \
    'test "$#" -eq 10' \
    'test "$1" = --fail' \
    'test "$2" = --location' \
    'test "$3" = --proto' \
    'test "$4" = =https' \
    'test "$5" = --tlsv1.2' \
    'test "$6" = --retry' \
    'test "$7" = 3' \
    'test "$8" = --output' \
    'output=$9' \
    'url=${10}' \
    'node_source=/fixtures/node-v24.20.0-linux-x64.tar.xz' \
    'if test "${FIXTURE_RESERVED_MANIFEST:-}" = 1; then node_source=/fixtures/reserved-node-v24.20.0-linux-x64.tar.xz; fi' \
    'case "$url" in' \
    '  https://nodejs.org/dist/v24.20.0/SHASUMS256.txt)' \
    '    hash=$(/usr/bin/sha256sum "$node_source"); hash=${hash%% *}' \
    '    printf "%s  %s\n" "$hash" node-v24.20.0-linux-x64.tar.xz > "$output" ;;' \
    '  https://nodejs.org/dist/v24.20.0/node-v24.20.0-linux-x64.tar.xz)' \
    '    /usr/bin/cp -- "$node_source" "$output"' \
    '    if test "${FIXTURE_CORRUPT_NODE_DOWNLOAD:-}" = 1; then printf corrupt >> "$output"; fi ;;' \
    '  https://github.com/astral-sh/uv/releases/download/0.12.7/uv-x86_64-unknown-linux-gnu.tar.gz.sha256)' \
    '    hash=$(/usr/bin/sha256sum /fixtures/uv-x86_64-unknown-linux-gnu.tar.gz); hash=${hash%% *}' \
    '    printf "%s  %s\n" "$hash" uv-x86_64-unknown-linux-gnu.tar.gz > "$output" ;;' \
    '  https://github.com/astral-sh/uv/releases/download/0.12.7/uv-x86_64-unknown-linux-gnu.tar.gz)' \
    '    /usr/bin/cp -- /fixtures/uv-x86_64-unknown-linux-gnu.tar.gz "$output" ;;' \
    '  *) exit 72 ;;' \
    'esac' > /usr/bin/curl
  chmod 0755 /usr/bin/apt-get /usr/bin/curl /usr/bin/mv /usr/bin/uname
}

run_container() {
  local setup

  setup=$(declare -f setup_fixture)
  docker run --rm \
    --tmpfs /opt:rw,exec,mode=755,size=64m \
    --tmpfs /tmp:rw,exec,mode=1777,size=64m \
    --tmpfs /fixtures:rw,mode=755,size=32m \
    --tmpfs /home:rw,exec,mode=755,size=16m \
    -v "$repo_root:/src:ro" "$fixture_image" bash -euo pipefail -c "$setup
setup_fixture
$1"
}

ensure_fixture_image

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  mkdir /tmp/inherited-path
  printf "%s\n" "#!/bin/sh" "touch /tmp/inherited-path-used" "exec /usr/bin/id \"\$@\"" > /tmp/inherited-path/id
  chmod 0755 /tmp/inherited-path/id
  PATH=/tmp/inherited-path:/usr/sbin:/usr/bin:/sbin:/bin /bin/bash /src/runtimes/wsl/provision.sh
  test ! -e /tmp/inherited-path-used
  /bin/bash /src/runtimes/wsl/provision.sh
  printf "%s\n" update "install -y --no-install-recommends ca-certificates curl xz-utils" update "install -y --no-install-recommends ca-certificates curl xz-utils" > /tmp/apt-calls.expected
  cmp -s /tmp/apt-calls.expected /tmp/apt-calls

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

  node_home=/opt/openhands/node-v24.20.0-linux-x64
  test "$("$node_home/bin/node" --version)" = "v24.20.0"
  test "$(/usr/local/bin/npm --version)" = "11.19.0"
  test "$(/usr/local/bin/npx --version)" = "11.19.0"
  test "$(/usr/local/bin/uv --version)" = "uv 0.12.7 (a0b1c2d3 2026-08-29 x86_64-unknown-linux-gnu)"
  test "$(/usr/local/bin/uvx --version)" = "uvx 0.12.7 (a0b1c2d3 2026-08-29 x86_64-unknown-linux-gnu)"
  mkdir /tmp/poison
  printf "%s\n" "#!/bin/sh" "exit 99" > /tmp/poison/node
  chmod 0755 /tmp/poison/node
  test "$(PATH=/tmp/poison:/usr/bin:/bin /usr/local/bin/npm --version)" = "11.19.0"
  test "$(PATH=/tmp/poison:/usr/bin:/bin /usr/local/bin/npx --version)" = "11.19.0"
  test "$(stat -c "%U:%G %a" /opt/openhands)" = "root:root 755"
  test "$(stat -c "%U:%G %a" "$node_home")" = "root:root 755"
  test "$(stat -c "%U:%G %a" "$node_home/.openhands-manifest")" = "root:root 644"
  test "$(stat -c "%U:%G" /usr/local/bin/node)" = "root:root"
  test "$(readlink /usr/local/bin/node)" = "$node_home/bin/node"
  for path in /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/uv /usr/local/bin/uvx; do
    test "$(stat -c "%U:%G %a" "$path")" = "root:root 755"
  done
  printf "#!/bin/sh\nexec %s/bin/node %s/lib/node_modules/npm/bin/npm-cli.js \"\$@\"\n" "$node_home" "$node_home" > /tmp/npm.expected
  printf "#!/bin/sh\nexec %s/bin/node %s/lib/node_modules/npm/bin/npx-cli.js \"\$@\"\n" "$node_home" "$node_home" > /tmp/npx.expected
  cmp -s /tmp/npm.expected /usr/local/bin/npm
  cmp -s /tmp/npx.expected /usr/local/bin/npx

  ! su -s /bin/sh agent -c "WSL_DISTRO_NAME=openhands-worker bash /src/runtimes/wsl/provision.sh"
  ! env WSL_DISTRO_NAME=wrong-distro bash /src/runtimes/wsl/provision.sh
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  printf "%s\n" "#!/bin/sh" "touch /tmp/foreign-uv-executed" > /usr/local/bin/uv
  chmod 0755 /usr/local/bin/uv
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  cmp -s /etc/wsl.conf /src/runtimes/wsl/wsl.conf
  test "$(stat -c "%U:%G %a" /etc/wsl.conf)" = "root:root 644"
  test ! -e /tmp/foreign-uv-executed
  test ! -e /opt/openhands/node-v24.20.0-linux-x64
  test ! -e /usr/local/bin/node
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /src/runtimes/wsl/provision.sh
  printf "%s\n" "#!/bin/sh" "touch /tmp/foreign-node-executed" > /opt/openhands/node-v24.20.0-linux-x64/bin/node
  rm /usr/local/bin/uvx
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test ! -e /tmp/foreign-node-executed
  test ! -e /usr/local/bin/uvx
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /src/runtimes/wsl/provision.sh
  printf corrupt > /opt/openhands/node-v24.20.0-linux-x64/lib/node_modules/npm/node_modules/example/index.js
  rm /usr/local/bin/uvx
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test "$(cat /opt/openhands/node-v24.20.0-linux-x64/lib/node_modules/npm/node_modules/example/index.js)" = corrupt
  test ! -e /usr/local/bin/uvx
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /src/runtimes/wsl/provision.sh
  printf extra > /opt/openhands/node-v24.20.0-linux-x64/extra
  rm /usr/local/bin/node
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test "$(cat /opt/openhands/node-v24.20.0-linux-x64/extra)" = extra
  test ! -e /usr/local/bin/node
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /src/runtimes/wsl/provision.sh
  rm /opt/openhands/node-v24.20.0-linux-x64/lib/node_modules/npm/node_modules/example/index.js
  rm /usr/local/bin/uvx
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test ! -e /opt/openhands/node-v24.20.0-linux-x64/lib/node_modules/npm/node_modules/example/index.js
  test ! -e /usr/local/bin/uvx
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /src/runtimes/wsl/provision.sh
  chmod 0666 /opt/openhands/node-v24.20.0-linux-x64/lib/node_modules/npm/node_modules/example/index.js
  rm /usr/local/bin/node
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test "$(stat -c "%a" /opt/openhands/node-v24.20.0-linux-x64/lib/node_modules/npm/node_modules/example/index.js)" = 666
  test ! -e /usr/local/bin/node
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /src/runtimes/wsl/provision.sh
  rm /usr/local/bin/node /usr/local/bin/uvx
  bash /src/runtimes/wsl/provision.sh
  test "$(readlink /usr/local/bin/node)" = /opt/openhands/node-v24.20.0-linux-x64/bin/node
  test "$(/usr/local/bin/uvx --version)" = "uvx 0.12.7 (a0b1c2d3 2026-08-29 x86_64-unknown-linux-gnu)"
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  chmod 0777 /opt
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  cmp -s /etc/wsl.conf /src/runtimes/wsl/wsl.conf
  test ! -e /opt/openhands
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  if FIXTURE_UNAME=aarch64 bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  cmp -s /etc/wsl.conf /src/runtimes/wsl/wsl.conf
  test ! -e /opt/openhands
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  rmdir /usr/local/bin
  mkdir /tmp/foreign-bin
  ln -s /tmp/foreign-bin /usr/local/bin
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  cmp -s /etc/wsl.conf /src/runtimes/wsl/wsl.conf
  test -L /usr/local/bin
  test ! -e /opt/openhands
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  FIXTURE_CORRUPT_NODE_DOWNLOAD=1 bash /src/runtimes/wsl/provision.sh && exit 1
  cmp -s /etc/wsl.conf /src/runtimes/wsl/wsl.conf
  test ! -e /opt/openhands/node-v24.20.0-linux-x64
  test ! -e /usr/local/bin/uv
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  if FIXTURE_RESERVED_MANIFEST=1 bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  cmp -s /etc/wsl.conf /src/runtimes/wsl/wsl.conf
  test ! -e /opt/openhands/node-v24.20.0-linux-x64
  test ! -e /usr/local/bin/uv
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  while IFS=: read -r destination pattern; do
    /usr/bin/rm -rf -- /opt/openhands
    /usr/bin/rm -f -- /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/uv /usr/local/bin/uvx
    if FIXTURE_FAIL_RENAME_DEST="/usr/local/bin/$destination" bash /src/runtimes/wsl/provision.sh; then
      exit 1
    fi
    test "$(/usr/bin/tail -n 1 /tmp/rename-failures)" = "/usr/local/bin/$destination"
    if find /usr/local/bin -maxdepth 1 -name "$pattern" -print -quit | grep -q .; then
      exit 1
    fi
  done <<EOF
node:.node-link.*
npm:.npm.*
npx:.npx.*
uv:.uv.*
uvx:.uvx.*
EOF
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  while IFS= read -r output; do
    if FIXTURE_UV_VERSION_OUTPUT="$output" /bin/bash /src/runtimes/wsl/provision.sh; then
      exit 1
    fi
    test ! -e /opt/openhands/node-v24.20.0-linux-x64
    test ! -e /usr/local/bin/uv
  done <<EOF
uv 0.12.8 (a0b1c2d3 2026-08-29 x86_64-unknown-linux-gnu)
uvx 0.12.7 (a0b1c2d3 2026-08-29 x86_64-unknown-linux-gnu)
uv 0.12.7 (a0b1c2d3 2026-08-29 aarch64-unknown-linux-gnu)
uv 0.12.7 a0b1c2d3 2026-08-29 x86_64-unknown-linux-gnu
uv 0.12.7+1 (a0b1c2d3 2026-08-29 x86_64-unknown-linux-gnu)
uv 0.12.7 (a0b1c2d3 2026-08-29 x86_64-unknown-linux-gnu
EOF
  if FIXTURE_UVX_VERSION_OUTPUT="uv 0.12.7 (a0b1c2d3 2026-08-29 x86_64-unknown-linux-gnu)" \
    /bin/bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test ! -e /opt/openhands/node-v24.20.0-linux-x64
  test ! -e /usr/local/bin/uvx
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

if [ "${RUN_WSL_REAL_TOOLCHAIN_TESTS:-0}" = 1 ]; then
  docker run --rm --platform linux/amd64 --tmpfs /opt:rw,exec,mode=755,size=512m \
    -v "$repo_root:/src:ro" ubuntu:26.04 bash -euo pipefail -c '
      export WSL_DISTRO_NAME=openhands-worker
      bash /src/runtimes/wsl/provision.sh
      bash /src/runtimes/wsl/provision.sh
      test "$(/opt/openhands/node-v24.20.0-linux-x64/bin/node --version)" = v24.20.0
      test "$(/usr/local/bin/npm --version)" = 11.19.0
      test "$(/usr/local/bin/npx --version)" = 11.19.0
      uv_output=$(/usr/local/bin/uv --version)
      uvx_output=$(/usr/local/bin/uvx --version)
      [[ $uv_output == "uv 0.12.7 ("*" x86_64-unknown-linux-gnu)" ]]
      [[ $uvx_output == "uvx 0.12.7 ("*" x86_64-unknown-linux-gnu)" ]]
    '
fi
