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
    'test -z "${NODE_OPTIONS+x}" || exit 65' \
    'case "${1:-}" in' \
    '  --version) printf "%s\n" v24.20.0 ;;' \
    '  -e)' \
    '    case "${3:-}" in' \
    '      \{*) case "$3" in *\"unexpected\"*) exit 86 ;; *) printf ok ;; esac ;;' \
    '      *) grep -F "\"name\":\"$4\"" "$3" >/dev/null && grep -F "\"version\":\"$5\"" "$3" >/dev/null || exit 86; printf "%s@%s\n" "$4" "$5" ;;' \
    '    esac ;;' \
    '  */npx-cli.js) test "${2:-}" = --version && printf "%s\n" 11.19.0 ;;' \
    '  */npm-cli.js)' \
    '    if test "${2:-}" = --version; then printf "%s\n" 11.19.0; exit 0; fi' \
    '    test "$(id -un)" = agent || exit 81' \
    '    test "$HOME" = /home/agent || exit 82' \
    '    test "$PATH" = /usr/local/bin:/usr/bin:/bin || exit 83' \
    '    test "$NPM_CONFIG_USERCONFIG" = /dev/null && test "$NPM_CONFIG_GLOBALCONFIG" = /etc/openhands/npmrc && test "$NPM_CONFIG_USERCONFIG" != "$NPM_CONFIG_GLOBALCONFIG" || exit 87' \
    '    shift' \
    '    test "$1" = --prefix && prefix=$2 && shift 2' \
    '    test "$1" = --cache && test "$2" = /home/agent/.cache/npm && shift 2' \
    '    if test "$1" = --global && test "$2" = --depth=0 && test "$3" = --json && test "$4" = ls; then' \
    '      json="{\"dependencies\":{\"@openhands/agent-canvas\":{\"version\":\"1.16.0\"},\"@agentclientprotocol/claude-agent-acp\":{\"version\":\"0.63.0\"},\"@agentclientprotocol/codex-acp\":{\"version\":\"1.1.7\"},\"@anthropic-ai/claude-code\":{\"version\":\"2.1.251\"},\"@openai/codex\":{\"version\":\"0.151.0\"}}}"' \
    '      test ! -e /tmp/fixture-extra-package || json="{\"dependencies\":{\"@openhands/agent-canvas\":{\"version\":\"1.16.0\"},\"@agentclientprotocol/claude-agent-acp\":{\"version\":\"0.63.0\"},\"@agentclientprotocol/codex-acp\":{\"version\":\"1.1.7\"},\"@anthropic-ai/claude-code\":{\"version\":\"2.1.251\"},\"@openai/codex\":{\"version\":\"0.151.0\"},\"unexpected\":{\"version\":\"1.0.0\"}}}"' \
    '      printf "%s\n" "$json"' \
    '      exit 0' \
    '    fi' \
    '    test "$1" = --global && test "$2" = --no-audit && test "$3" = --no-fund && test "$4" = --no-update-notifier && shift 4' \
    '    case "$1" in' \
    '      --ignore-scripts) mode=no-scripts; shift; test "$1" = install && shift ;;' \
    '      --strict-allow-scripts) mode=claude-only; test "$2" = --allow-scripts=@anthropic-ai/claude-code && test "$3" = install && shift 3 ;;' \
    '      *) exit 88 ;;' \
    '    esac' \
    '    test "$mode" != claude-only || { test "$#" = 1 && test "$1" = @anthropic-ai/claude-code@2.1.251; } || exit 89' \
    '    test "$mode" != claude-only || { test "$(node --version)" = v24.20.0; } || exit 90' \
    '    printf "%s:%s\n" "$mode" "$*" >> /tmp/npm-calls' \
    '    printf "%s\n" "$@" >> /tmp/npm-installs' \
    '    mkdir -p "$prefix/lib/node_modules/@openhands" "$prefix/lib/node_modules/@agentclientprotocol" "$prefix/lib/node_modules/@anthropic-ai" "$prefix/lib/node_modules/@openai" "$prefix/bin"' \
    '    for spec do' \
    '      case "$spec" in' \
    '        @openhands/agent-canvas@1.16.0) name=@openhands/agent-canvas version=1.16.0 bin=agent-canvas ;;' \
    '        @agentclientprotocol/claude-agent-acp@0.63.0) name=@agentclientprotocol/claude-agent-acp version=0.63.0 bin=claude-agent-acp ;;' \
    '        @agentclientprotocol/codex-acp@1.1.7) name=@agentclientprotocol/codex-acp version=1.1.7 bin=codex-acp ;;' \
    '        @anthropic-ai/claude-code@2.1.251) name=@anthropic-ai/claude-code version=2.1.251 bin=claude ;;' \
    '        @openai/codex@0.151.0) name=@openai/codex version=0.151.0 bin=codex ;;' \
    '        *) exit 85 ;;' \
    '      esac' \
    '      package="$prefix/lib/node_modules/$name"' \
    '      mkdir -p "$package/bin"' \
    '      if test -e /tmp/fixture-wrong-package && test "$bin" = agent-canvas; then version=0.0.0; fi' \
    '      printf "{\"name\":\"%s\",\"version\":\"%s\"}\n" "$name" "$version" > "$package/package.json"' \
    '      output=$version' \
    '      test "$bin" != claude || output="2.1.251 (Claude Code)"' \
    '      test "$bin" != codex || output="codex-cli 0.151.0"' \
    '      printf "#!/bin/sh\ncase \"\${1:-}\" in --version) printf \"%%s\\n\" \"%s\" ;; *) exit 0 ;; esac\n" "$output" > "$package/bin/$bin"' \
    '      chmod 0700 "$package/bin/$bin"' \
    '      ln -sf "../lib/node_modules/$name/bin/$bin" "$prefix/bin/$bin"' \
    '      test ! -e /tmp/fixture-npm-fail || test "$bin" != agent-canvas || exit 84' \
    '    done' \
    '    test ! -e /tmp/fixture-corrupt-agent-root || chmod 0755 "$prefix"' \
    '    test ! -e /tmp/fixture-extra-package || { mkdir -p "$prefix/lib/node_modules/unexpected/bin"; printf "{\"name\":\"unexpected\",\"version\":\"1.0.0\"}\n" > "$prefix/lib/node_modules/unexpected/package.json"; printf "#!/bin/sh\n" > "$prefix/lib/node_modules/unexpected/bin/unexpected"; chmod 0700 "$prefix/lib/node_modules/unexpected/bin/unexpected"; ln -sf ../lib/node_modules/unexpected/bin/unexpected "$prefix/bin/unexpected"; }' \
    '    test ! -e /tmp/fixture-foreign-bin || { rm "$prefix/bin/codex"; ln -s /tmp/foreign-bin "$prefix/bin/codex"; }' \
    '    test ! -e /tmp/fixture-extra-bin || ln -sf ../lib/node_modules/@openai/codex/bin/codex "$prefix/bin/unexpected" ;;' \
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
    'test -z "${UV_TOOL_DIR+x}" || exit 65' \
    'if test -e /tmp/fixture-uv-version-output; then cat /tmp/fixture-uv-version-output; else' \
    '  printf "%s\n" "uv 0.12.7 (a0b1c2d3 2026-08-29 x86_64-unknown-linux-gnu)"' \
    'fi' \
    > "/tmp/fixture-src/$uv_directory/uv"
  printf '%s\n' \
    '#!/bin/sh' \
    'test -z "${UV_TOOL_DIR+x}" || exit 65' \
    'if test -e /tmp/fixture-uvx-version-output; then cat /tmp/fixture-uvx-version-output; else' \
    '  printf "%s\n" "uvx 0.12.7 (a0b1c2d3 2026-08-29 x86_64-unknown-linux-gnu)"' \
    'fi' \
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
    'test -z "${HOME+x}${CURL_CA_BUNDLE+x}${SSL_CERT_FILE+x}${SSL_CERT_DIR+x}" || exit 73' \
    'test "$#" -eq 17' \
    'test "$1" = --disable' \
    'test "$2" = --fail' \
    'test "$3" = --location' \
    'test "$4" = --proto' \
    'test "$5" = =https' \
    'test "$6" = --proto-redir' \
    'test "$7" = =https' \
    'test "$8" = --tlsv1.2' \
    'test "$9" = --tls-max' \
    'test "${10}" = 1.3' \
    'test "${11}" = --cacert' \
    'test "${12}" = /etc/ssl/certs/ca-certificates.crt' \
    'test "${13}" = --retry' \
    'test "${14}" = 3' \
    'test "${15}" = --output' \
    'output=${16}' \
    'url=${17}' \
    'node_source=/fixtures/node-v24.20.0-linux-x64.tar.xz' \
    'if test -e /tmp/fixture-reserved-manifest; then node_source=/fixtures/reserved-node-v24.20.0-linux-x64.tar.xz; fi' \
    'case "$url" in' \
    '  https://nodejs.org/dist/v24.20.0/SHASUMS256.txt)' \
    '    hash=$(/usr/bin/sha256sum "$node_source"); hash=${hash%% *}' \
    '    printf "%s  %s\n" "$hash" node-v24.20.0-linux-x64.tar.xz > "$output" ;;' \
    '  https://nodejs.org/dist/v24.20.0/node-v24.20.0-linux-x64.tar.xz)' \
    '    /usr/bin/cp -- "$node_source" "$output"' \
    '    if test -e /tmp/fixture-corrupt-node-download; then printf corrupt >> "$output"; fi ;;' \
    '  https://github.com/astral-sh/uv/releases/download/0.12.7/uv-x86_64-unknown-linux-gnu.tar.gz.sha256)' \
    '    hash=$(/usr/bin/sha256sum /fixtures/uv-x86_64-unknown-linux-gnu.tar.gz); hash=${hash%% *}' \
    '    printf "%s  %s\n" "$hash" uv-x86_64-unknown-linux-gnu.tar.gz > "$output" ;;' \
    '  https://github.com/astral-sh/uv/releases/download/0.12.7/uv-x86_64-unknown-linux-gnu.tar.gz)' \
    '    /usr/bin/cp -- /fixtures/uv-x86_64-unknown-linux-gnu.tar.gz "$output" ;;' \
    '  *) exit 72 ;;' \
    'esac' > /usr/bin/curl
  for command in find sha256sum sort tar; do
    cp "/usr/bin/$command" "/usr/bin/$command.fixture-real"
  done
  printf '%s\n' \
    '#!/bin/sh' \
    'test -z "${TAR_OPTIONS+x}" || exit 73' \
    'if test -e /tmp/fixture-fail-tar-list && test "${1:-}" = --quoting-style=escape; then' \
    '  /usr/bin/tar.fixture-real "$@"' \
    '  exit 74' \
    'fi' \
    'exec /usr/bin/tar.fixture-real "$@"' > /usr/bin/tar
  printf '%s\n' \
    '#!/bin/sh' \
    'if test -e /tmp/fixture-fail-find && test "${2:-}" = -type && test "${3:-}" = l; then' \
    '  /usr/bin/find.fixture-real "$@"' \
    '  exit 75' \
    'fi' \
    'exec /usr/bin/find.fixture-real "$@"' > /usr/bin/find
  printf '%s\n' \
    '#!/bin/sh' \
    'if test -e /tmp/fixture-fail-sort; then' \
    '  /usr/bin/sort.fixture-real "$@"' \
    '  exit 76' \
    'fi' \
    'exec /usr/bin/sort.fixture-real "$@"' > /usr/bin/sort
  printf '%s\n' \
    '#!/bin/sh' \
    'case "$*" in' \
    '  *node-v24.20.0-linux-x64/*) if test -e /tmp/fixture-fail-sha256sum; then' \
    '    /usr/bin/sha256sum.fixture-real "$@"' \
    '    exit 77' \
    '  fi ;;' \
    'esac' \
    'exec /usr/bin/sha256sum.fixture-real "$@"' > /usr/bin/sha256sum
  chmod 0755 /usr/bin/apt-get /usr/bin/curl /usr/bin/find /usr/bin/mv /usr/bin/sha256sum /usr/bin/sort /usr/bin/tar /usr/bin/uname
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
  mkdir /tmp/poison-home
  printf "%s\n" "--proxy http://127.0.0.1:1" > /tmp/poison-home/.curlrc
  printf poison > /tmp/poison-ca
  HOME=/tmp/poison-home CURL_CA_BUNDLE=/tmp/poison-ca SSL_CERT_FILE=/tmp/poison-ca \
    SSL_CERT_DIR=/tmp NODE_OPTIONS=--require=/tmp/poison.js TAR_OPTIONS=--version \
    UV_TOOL_DIR=/tmp/poison PATH=/tmp/inherited-path:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash /src/runtimes/wsl/provision.sh
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
  for path in /home/agent/.local /home/agent/.cache /home/agent/.cache/npm; do
    test "$(stat -c "%U:%G %a" "$path")" = "agent:agent 700"
  done
  test "$(stat -c "%U:%G %a" /etc/openhands)" = "root:root 755"
  test "$(stat -c "%U:%G %a" /etc/openhands/npmrc)" = "root:root 644"
  test ! -s /etc/openhands/npmrc
  printf "%s\n" \
    @openhands/agent-canvas@1.16.0 \
    @agentclientprotocol/claude-agent-acp@0.63.0 \
    @agentclientprotocol/codex-acp@1.1.7 \
    @openai/codex@0.151.0 \
    @anthropic-ai/claude-code@2.1.251 \
    @openhands/agent-canvas@1.16.0 \
    @agentclientprotocol/claude-agent-acp@0.63.0 \
    @agentclientprotocol/codex-acp@1.1.7 \
    @openai/codex@0.151.0 \
    @anthropic-ai/claude-code@2.1.251 > /tmp/npm-installs.expected
  cmp -s /tmp/npm-installs.expected /tmp/npm-installs
  printf "%s\n" \
    "no-scripts:@openhands/agent-canvas@1.16.0 @agentclientprotocol/claude-agent-acp@0.63.0 @agentclientprotocol/codex-acp@1.1.7 @openai/codex@0.151.0" \
    "claude-only:@anthropic-ai/claude-code@2.1.251" \
    "no-scripts:@openhands/agent-canvas@1.16.0 @agentclientprotocol/claude-agent-acp@0.63.0 @agentclientprotocol/codex-acp@1.1.7 @openai/codex@0.151.0" \
    "claude-only:@anthropic-ai/claude-code@2.1.251" > /tmp/npm-calls.expected
  cmp -s /tmp/npm-calls.expected /tmp/npm-calls
  test "$(/home/agent/.local/bin/claude --version)" = "2.1.251 (Claude Code)"
  test "$(/home/agent/.local/bin/codex --version)" = "codex-cli 0.151.0"
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
  touch /tmp/fixture-corrupt-node-download
  bash /src/runtimes/wsl/provision.sh && exit 1
  cmp -s /etc/wsl.conf /src/runtimes/wsl/wsl.conf
  test ! -e /opt/openhands/node-v24.20.0-linux-x64
  test ! -e /usr/local/bin/uv
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-reserved-manifest
  if bash /src/runtimes/wsl/provision.sh; then
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
    printf "%s\n" "$output" > /tmp/fixture-uv-version-output
    if /bin/bash /src/runtimes/wsl/provision.sh; then
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
  rm /tmp/fixture-uv-version-output
  printf "%s\n" "uv 0.12.7 (a0b1c2d3 2026-08-29 x86_64-unknown-linux-gnu)" > /tmp/fixture-uvx-version-output
  if /bin/bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test ! -e /opt/openhands/node-v24.20.0-linux-x64
  test ! -e /usr/local/bin/uvx
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  failures=0
  for producer in tar-list find sort sha256sum; do
    rm -rf /opt/openhands
    rm -f /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/uv /usr/local/bin/uvx
    rm -f /tmp/fixture-fail-*
    touch "/tmp/fixture-fail-$producer"
    if bash /src/runtimes/wsl/provision.sh; then
      printf "producer failure was ignored: %s\n" "$producer" >&2
      failures=$((failures + 1))
    fi
    if test -e /opt/openhands/node-v24.20.0-linux-x64 || test -e /usr/local/bin/node ||
      test -e /usr/local/bin/npm || test -e /usr/local/bin/npx || test -e /usr/local/bin/uv ||
      test -e /usr/local/bin/uvx || compgen -G "/opt/openhands/.node-stage.*" >/dev/null ||
      compgen -G "/usr/local/bin/.uv-stage.*" >/dev/null; then
      printf "producer failure left committed or staged files: %s\n" "$producer" >&2
      failures=$((failures + 1))
    fi
  done
  test "$failures" -eq 0
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

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-wrong-package
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-extra-package
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-foreign-bin
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test -L /home/agent/.local/bin/codex
  test "$(readlink /home/agent/.local/bin/codex)" = /tmp/foreign-bin
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-extra-bin
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test -L /home/agent/.local/bin/unexpected
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-corrupt-agent-root
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test "$(stat -c "%a" /home/agent/.local)" = 755
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-npm-fail
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test "$(stat -c "%U:%G %a" /home/agent/.local)" = "agent:agent 700"
  test ! -e /home/agent/.local/bin/claude
  test -e /home/agent/.local/lib/node_modules/@openhands/agent-canvas/package.json
  rm /tmp/fixture-npm-fail
  bash /src/runtimes/wsl/provision.sh
  test "$(/home/agent/.local/bin/claude --version)" = "2.1.251 (Claude Code)"
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /src/runtimes/wsl/provision.sh
  printf CLAUDE_CODE_OAUTH_TOKEN > /home/agent/.claude/credentials.json
  printf OPENAI_API_KEY > /home/agent/.codex/auth.json
  bash /src/runtimes/wsl/provision.sh
  test "$(cat /home/agent/.claude/credentials.json)" = CLAUDE_CODE_OAUTH_TOKEN
  test "$(cat /home/agent/.codex/auth.json)" = OPENAI_API_KEY
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /src/runtimes/wsl/provision.sh
  mkdir -p /home/agent/.cache/npm/unrelated/deep
  chown -R agent:agent /home/agent/.cache/npm/unrelated
  chmod 0777 /home/agent/.cache/npm/unrelated/deep
  ln -s /tmp /home/agent/.cache/npm/unrelated/deep-link
  bash /src/runtimes/wsl/provision.sh
  test -L /home/agent/.cache/npm/unrelated/deep-link
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  useradd --create-home --shell /bin/bash --user-group agent
  chmod 0700 /home/agent
  mkdir /home/agent/.local
  chown root:root /home/agent/.local
  chmod 0700 /home/agent/.local
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test "$(stat -c "%U:%G %a" /home/agent/.local)" = "root:root 700"
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  useradd --create-home --shell /bin/bash --user-group agent
  chmod 0700 /home/agent
  mkdir -p /home/agent/.cache/npm
  chown root:root /home/agent/.cache/npm
  chmod 0700 /home/agent/.cache /home/agent/.cache/npm
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test "$(stat -c "%U:%G %a" /home/agent/.cache/npm)" = "root:root 700"
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  ln -s /tmp /etc/openhands
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test -L /etc/openhands
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  mkdir /etc/openhands
  printf foreign > /etc/openhands/npmrc
  if bash /src/runtimes/wsl/provision.sh; then
    exit 1
  fi
  test "$(cat /etc/openhands/npmrc)" = foreign
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
      node=/opt/openhands/node-v24.20.0-linux-x64/bin/node
      prefix=/home/agent/.local
      for package in \
        @openhands/agent-canvas@1.16.0 \
        @agentclientprotocol/claude-agent-acp@0.63.0 \
        @agentclientprotocol/codex-acp@1.1.7 \
        @anthropic-ai/claude-code@2.1.251 \
        @openai/codex@0.151.0; do
        name=${package%@*}
        version=${package##*@}
        "$node" -e "const p = require(process.argv[1]); process.exit(p.name === process.argv[2] && p.version === process.argv[3] ? 0 : 1)" \
          "$prefix/lib/node_modules/$name/package.json" "$name" "$version"
      done
      for command in agent-canvas claude-agent-acp codex-acp claude codex; do
        test -L "$prefix/bin/$command"
      done
      test "$(runuser -u agent -- env -i HOME=/home/agent PATH=/home/agent/.local/bin:/usr/sbin:/usr/bin:/sbin:/bin claude --version)" = "2.1.251 (Claude Code)"
      test "$(runuser -u agent -- env -i HOME=/home/agent PATH=/home/agent/.local/bin:/usr/sbin:/usr/bin:/sbin:/bin codex --version)" = "codex-cli 0.151.0"
    '
fi
