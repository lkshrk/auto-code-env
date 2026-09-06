#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && until [ -e .git ]; do [ "$PWD" = / ] && exit 1; cd ..; done && pwd)
fixture_image=auto-code-env-wsl-stage5a-fixture:ubuntu-26.04

ensure_fixture_image() {
  if docker image inspect "$fixture_image" >/dev/null 2>&1 &&
    docker run --rm "$fixture_image" /usr/bin/python3 -c 'import queue'; then
    return
  fi
  printf '%s\n' \
    'FROM ubuntu:26.04' \
    'RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-minimal xz-utils && rm -rf /var/lib/apt/lists/*' |
    docker build --quiet --tag "$fixture_image" -
}

setup_fixture() {
  local node_archive=node-v24.20.0-linux-x64.tar.xz
  local node_directory=node-v24.20.0-linux-x64
  local arm_node_archive=node-v24.20.0-linux-arm64.tar.xz
  local arm_node_directory=node-v24.20.0-linux-arm64
  local reserved_node_archive=reserved-node-v24.20.0-linux-x64.tar.xz
  local uv_archive=uv-x86_64-unknown-linux-gnu.tar.gz
  local uv_directory=uv-x86_64-unknown-linux-gnu

  mkdir -p "/tmp/fixture-src/$node_directory/bin"
  mkdir -p "/tmp/fixture-src/$node_directory/lib/node_modules/npm/bin"
  mkdir -p "/tmp/fixture-src/$node_directory/lib/node_modules/npm/node_modules/example"
  mkdir -p "/tmp/fixture-src/$uv_directory" /fixtures

  mkdir -p /opt/openhands-build/omni
  cp /src/openhands/worker/image/provision.sh /opt/openhands-build/provision.sh
  cp /src/openhands/worker/image/rootfs-wsl/etc/wsl.conf /opt/openhands-build/wsl.conf
  cp /src/openhands/worker/image/omni/settings.json /opt/openhands-build/omni/settings.json

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
  cp -a "/tmp/fixture-src/$node_directory" "/tmp/fixture-src/$arm_node_directory"
  tar -cJf "/fixtures/$arm_node_archive" -C /tmp/fixture-src "$arm_node_directory"
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
  cp -a "/tmp/fixture-src/$uv_directory" "/tmp/fixture-src/uv-aarch64-unknown-linux-gnu"
  sed -i 's/x86_64-unknown-linux-gnu/aarch64-unknown-linux-gnu/g' /tmp/fixture-src/uv-aarch64-unknown-linux-gnu/uv /tmp/fixture-src/uv-aarch64-unknown-linux-gnu/uvx
  tar -czf /fixtures/uv-aarch64-unknown-linux-gnu.tar.gz -C /tmp/fixture-src uv-aarch64-unknown-linux-gnu

  mkdir -p /tmp/fixture-src/omni
  printf '%s\n' \
    '#!/bin/sh' \
    'if test "${1:-}" = --version; then printf "%s\\n" "omni version v0.10.14 (fixture)"; exit 0; fi' \
    'test "$1" = --config && test -f "$2" && test "$2" != /etc/openhands/omni/settings.json && test "$3" = --cache-dir && test "$5" = --state-dir && test "$7" = --yes && test "$8" = tools && test "$9" = sync && test "${10}" = --group || exit 91' \
    'group=${11}' \
    'touch "$(dirname "$2")/.omni-config.lock"; cp "$2" "$2.bak"' \
    'printf "%s|%s|%s|%s|%s|%s|%s\\n" "$group" "$(id -un)" "${NPM_CONFIG_IGNORE_SCRIPTS-}" "${NPM_CONFIG_STRICT_ALLOW_SCRIPTS-}" "${NPM_CONFIG_ALLOW_SCRIPTS-}" "$2" "$(stat -c "%U:%G %a" "$(dirname "$2")")/$(stat -c "%U:%G %a" "$2")" >> /tmp/omni-calls' \
    'test ! -e /tmp/fixture-omni-fail-after-artifacts || test "$group" != openhands-agent-no-scripts || exit 97' \
    'if test -e /tmp/fixture-omni-term-after-artifacts && test "$group" = openhands-system; then pid=$PPID; while test "$pid" -gt 1; do args=$(ps -o args= -p "$pid"); case "$args" in *provision.sh*) kill -TERM "$pid"; sleep 1; exit 99 ;; esac; pid=$(ps -o ppid= -p "$pid" | tr -d " "); done; exit 99; fi' \
    'case "$group" in' \
    '  openhands-system)' \
    '    test "$(id -u)" = 0 && test "$4" = /var/cache/openhands/omni && test "$6" = /var/lib/openhands/omni || exit 92' \
    '    if test ! -e /usr/bin/rbw; then printf "%s\\n" "#!/bin/sh" "case \"\${1:-}\" in" "  --version) printf \"%s\\n\" \"rbw 1.13.2\" ;;" "  *) exit 0 ;;" "esac" > /usr/bin/rbw; chmod 0755 /usr/bin/rbw; fi; chmod 0666 /tmp/omni-calls ;;' \
    '  openhands-agent-no-scripts)' \
    '    test "$(id -un)" = agent && test "$4" = /home/agent/.cache/omni && test "$6" = /home/agent/.local/state/omni && test "$NPM_CONFIG_IGNORE_SCRIPTS" = true && test -z "${NPM_CONFIG_STRICT_ALLOW_SCRIPTS-}${NPM_CONFIG_ALLOW_SCRIPTS-}" || exit 93' \
    '    for path in /home/agent/.local/bin /home/agent/.local/lib /home/agent/.local/lib/node_modules; do test ! -L "$path" && test "$(stat -c "%U:%G %a" "$path")" = "agent:agent 700" || exit 96; done' \
    '    if test ! -e /home/agent/.local/bin/agent-canvas; then for path in /home/agent/.local/lib/node_modules/@openhands /home/agent/.local/lib/node_modules/@agentclientprotocol /home/agent/.local/lib/node_modules/@anthropic-ai /home/agent/.local/lib/node_modules/@openai; do test ! -e "$path" || exit 98; done; fi' \
    '    /usr/local/bin/node /opt/openhands/node-v24.20.0-linux-*/lib/node_modules/npm/bin/npm-cli.js --prefix /home/agent/.local --cache /home/agent/.cache/npm --global --no-audit --no-fund --no-update-notifier --ignore-scripts install @openhands/agent-canvas@1.16.0 @agentclientprotocol/claude-agent-acp@0.63.0 @agentclientprotocol/codex-acp@1.1.7 @openai/codex@0.151.0 ;;' \
    '  openhands-agent-claude)' \
    '    test "$(id -un)" = agent && test "$4" = /home/agent/.cache/omni && test "$6" = /home/agent/.local/state/omni && test "$NPM_CONFIG_STRICT_ALLOW_SCRIPTS" = true && test "$NPM_CONFIG_ALLOW_SCRIPTS" = @anthropic-ai/claude-code && test -z "${NPM_CONFIG_IGNORE_SCRIPTS-}" || exit 94' \
    '    /usr/local/bin/node /opt/openhands/node-v24.20.0-linux-*/lib/node_modules/npm/bin/npm-cli.js --prefix /home/agent/.local --cache /home/agent/.cache/npm --global --no-audit --no-fund --no-update-notifier --strict-allow-scripts --allow-scripts=@anthropic-ai/claude-code install @anthropic-ai/claude-code@2.1.251 ;;' \
    '  *) exit 95 ;;' \
    'esac' > /tmp/fixture-src/omni/omni
  chmod 0755 /tmp/fixture-src/omni/omni
  printf license > /tmp/fixture-src/omni/LICENSE
  printf readme > /tmp/fixture-src/omni/README.md
  tar -czf /fixtures/omni_linux_x86_64.tar.gz -C /tmp/fixture-src/omni LICENSE README.md omni
  cp /fixtures/omni_linux_x86_64.tar.gz /fixtures/omni_linux_arm64.tar.gz

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
    'if test -n "${FIXTURE_RACE_DEST:-}" && test "$last" = "$FIXTURE_RACE_DEST"; then' \
    '  printf foreign > "$last"' \
    '  chmod 0755 "$last"' \
    '  exit 0' \
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
  printf '%s\n' \
    '#!/bin/sh' \
    'case "${1:-}" in' \
    '  -W)' \
    '    case "${3:-}" in rbw) test ! -e /tmp/fixture-counterfeit-rbw || { printf "ii  9.9.9-1\\n"; exit 0; }; printf "ii  1.13.2-7\\n" ;; python3-minimal|python3) printf "ii \\n" ;; *) exit 1 ;; esac ;;' \
    '  -S) case "${2:-}" in /usr/bin/rbw) printf "rbw: /usr/bin/rbw\\n" ;; /usr/bin/python3) printf "python3-minimal: /usr/bin/python3\\n" ;; *) exit 1 ;; esac ;;' \
    '  *) exit 1 ;;' \
    'esac' > /usr/bin/dpkg-query
  printf '%s\n' \
    '#!/bin/sh' \
    'test "${1:-}" = --verify || exit 1' \
    'case "${2:-}" in rbw) test ! -e /tmp/fixture-dpkg-verify-nonzero || exit 1; if test -e /tmp/fixture-rbw-dpkg-verify-output; then cat /tmp/fixture-rbw-dpkg-verify-output; elif test -e /tmp/fixture-dpkg-verify-fail; then printf "??5?????? /usr/bin/rbw\\n"; fi ;; python3-minimal) test ! -e /tmp/fixture-python-dpkg-verify-nonzero || exit 1; if test -e /tmp/fixture-python-dpkg-verify-output; then cat /tmp/fixture-python-dpkg-verify-output; elif test -e /tmp/fixture-python-dpkg-verify-fail; then printf "??5?????? /usr/bin/python3\\n"; fi ;; python3) test ! -e /tmp/fixture-python-stdlib-dpkg-verify-nonzero || exit 1; if test -e /tmp/fixture-python-stdlib-dpkg-verify-output; then cat /tmp/fixture-python-stdlib-dpkg-verify-output; elif test -e /tmp/fixture-python-stdlib-dpkg-verify-fail; then printf "??5?????? /usr/lib/python3/queue.py\\n"; fi ;; *) exit 1 ;; esac' \
    > /usr/bin/dpkg
  printf '%s\n' '#!/bin/sh' 'machine_arch=${FIXTURE_UNAME:-x86_64}' 'printf "%s\n" "$machine_arch" > /tmp/fixture-machine-arch' 'printf "%s\n" "$machine_arch"' > /usr/bin/uname
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
    'case "$(cat /tmp/fixture-machine-arch)" in' \
    '  x86_64|amd64) node_arch=x64; uv_target=x86_64-unknown-linux-gnu ;;' \
    '  aarch64|arm64) node_arch=arm64; uv_target=aarch64-unknown-linux-gnu ;;' \
    '  *) exit 72 ;;' \
    'esac' \
    'node_archive="node-v24.20.0-linux-$node_arch.tar.xz"' \
    'node_source="/fixtures/$node_archive"' \
    'if test -e /tmp/fixture-reserved-manifest; then node_source=/fixtures/reserved-node-v24.20.0-linux-x64.tar.xz; fi' \
    'case "$url" in' \
    '  https://nodejs.org/dist/v24.20.0/SHASUMS256.txt)' \
    '    hash=$(/usr/bin/sha256sum "$node_source"); hash=${hash%% *}' \
    '    printf "%s  %s\n" "$hash" "$node_archive" > "$output" ;;' \
    '  https://nodejs.org/dist/v24.20.0/node-v24.20.0-linux-*.tar.xz)' \
    '    test "$url" = "https://nodejs.org/dist/v24.20.0/$node_archive" || exit 72' \
    '    /usr/bin/cp -- "$node_source" "$output"' \
    '    if test -e /tmp/fixture-corrupt-node-download; then printf corrupt >> "$output"; fi ;;' \
    '  https://github.com/astral-sh/uv/releases/download/0.12.7/uv-*.tar.gz.sha256)' \
    '    test "$url" = "https://github.com/astral-sh/uv/releases/download/0.12.7/uv-$uv_target.tar.gz.sha256" || exit 72' \
    '    hash=$(/usr/bin/sha256sum "/fixtures/uv-$uv_target.tar.gz"); hash=${hash%% *}' \
    '    printf "%s  %s\n" "$hash" "uv-$uv_target.tar.gz" > "$output" ;;' \
    '  https://github.com/astral-sh/uv/releases/download/0.12.7/uv-*.tar.gz)' \
    '    test "$url" = "https://github.com/astral-sh/uv/releases/download/0.12.7/uv-$uv_target.tar.gz" || exit 72' \
    '    /usr/bin/cp -- "/fixtures/uv-$uv_target.tar.gz" "$output" ;;' \
    '  https://github.com/lkshrk/omni/releases/download/v0.10.14/checksums.txt)' \
    '    case "$(cat /tmp/fixture-machine-arch)" in x86_64|amd64) omni_target=x86_64 ;; aarch64|arm64) omni_target=arm64 ;; *) exit 72 ;; esac' \
    '    hash=$(/usr/bin/sha256sum "/fixtures/omni_linux_$omni_target.tar.gz"); hash=${hash%% *}; printf "%s  omni_linux_%s.tar.gz\\ndeadbeef  other\\n" "$hash" "$omni_target" > "$output" ;;' \
    '  https://github.com/lkshrk/omni/releases/download/v0.10.14/omni_linux_*.tar.gz)' \
    '    case "$(cat /tmp/fixture-machine-arch)" in x86_64|amd64) omni_target=x86_64 ;; aarch64|arm64) omni_target=arm64 ;; *) exit 72 ;; esac' \
    '    test "$url" = "https://github.com/lkshrk/omni/releases/download/v0.10.14/omni_linux_$omni_target.tar.gz" || exit 72' \
    '    /usr/bin/cp -- "/fixtures/omni_linux_$omni_target.tar.gz" "$output" ;;' \
    '  *) exit 72 ;;' \
    'esac' > /usr/bin/curl
  for command in find sha256sum stat tar; do
    cp "/usr/bin/$command" "/usr/bin/$command.fixture-real"
  done
  printf '%s\n' \
    '#!/bin/sh' \
    'test -z "${TAR_OPTIONS+x}" || exit 73' \
    'if test -e /tmp/fixture-fail-tar-list && test "${1:-}" = --quoting-style=escape; then' \
    '  /usr/bin/tar.fixture-real "$@"' \
    '  exit 74' \
    'fi' \
    'if test -e /tmp/fixture-fail-tar-digest && test "${1:-}" = --create; then' \
    '  /usr/bin/tar.fixture-real "$@"' \
    '  exit 78' \
    'fi' \
    'test "${1:-}" != --create || printf "%s\n" tar >> /tmp/node-digest-processes' \
    'exec /usr/bin/tar.fixture-real "$@"' > /usr/bin/tar
  printf '%s\n' \
    '#!/bin/sh' \
    'case "$*" in *node-v24.20.0-linux-x64*) printf "%s\n" find >> /tmp/node-digest-processes ;; esac' \
    'if test -e /tmp/fixture-fail-safety-find && test "${1:-}" = -P && test "${3:-}" = -mindepth; then' \
    '  /usr/bin/find.fixture-real "$@"' \
    '  exit 75' \
    'fi' \
    'if test -e /tmp/fixture-fail-link-find && test "${2:-}" = -type && test "${3:-}" = l; then' \
    '  /usr/bin/find.fixture-real "$@"' \
    '  exit 76' \
    'fi' \
    'exec /usr/bin/find.fixture-real "$@"' > /usr/bin/find
  printf '%s\n' \
    '#!/bin/sh' \
    'case "$*" in *node-v24.20.0-linux-x64/*) exit 79 ;; esac' \
    'test "$#" -ne 0 || printf "%s\n" sha256sum >> /tmp/node-digest-processes' \
    'if test -e /tmp/fixture-fail-sha256sum && test "$#" -eq 0; then' \
    '  /usr/bin/sha256sum.fixture-real "$@"' \
    '  exit 77' \
    'fi' \
    'exec /usr/bin/sha256sum.fixture-real "$@"' > /usr/bin/sha256sum
  printf '%s\n' \
    '#!/bin/sh' \
    'case "$*" in *node-v24.20.0-linux-x64*) printf "%s\n" stat >> /tmp/node-digest-processes ;; esac' \
    'exec /usr/bin/stat.fixture-real "$@"' > /usr/bin/stat
  chmod 0755 /usr/bin/apt-get /usr/bin/curl /usr/bin/dpkg /usr/bin/dpkg-query /usr/bin/find /usr/bin/mv /usr/bin/sha256sum /usr/bin/stat /usr/bin/tar /usr/bin/uname
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
  touch /tmp/fixture-omni-fail-after-artifacts
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test "$(stat -c "%U:%G %a" /etc/openhands/omni)" = "root:root 755"
  test "$(stat -c "%U:%G %a" /etc/openhands/omni/settings.json)" = "root:root 644"
  cmp -s /etc/openhands/omni/settings.json /src/openhands/worker/image/omni/settings.json
  test ! -e /etc/openhands/omni/.omni-config.lock
  test ! -e /etc/openhands/omni/settings.json.bak
  ! compgen -G "/var/lib/openhands/omni/.config.*" >/dev/null
  ! compgen -G "/home/agent/.cache/omni/.config.*" >/dev/null
'

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
    /bin/bash /opt/openhands-build/provision.sh
  test ! -e /tmp/inherited-path-used
  : > /tmp/node-digest-processes
  benchmark_started=$(/usr/bin/date +%s%N)
  /bin/bash /opt/openhands-build/provision.sh
  benchmark_elapsed_ms=$((($(/usr/bin/date +%s%N) - benchmark_started) / 1000000))
  printf "node-digest benchmark: rerun_ms=%s tracked_processes=%s tar=%s sha256sum=%s find=%s stat=%s\n" \
    "$benchmark_elapsed_ms" "$(wc -l < /tmp/node-digest-processes)" \
    "$(grep -c ^tar$ /tmp/node-digest-processes)" "$(grep -c ^sha256sum$ /tmp/node-digest-processes)" \
    "$(grep -c ^find$ /tmp/node-digest-processes)" "$(grep -c ^stat$ /tmp/node-digest-processes)"
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
  test "$(stat -c "%U:%G %a" /etc/openhands/omni)" = "root:root 755"
  test "$(stat -c "%U:%G %a" /etc/openhands/omni/settings.json)" = "root:root 644"
  cmp -s /etc/openhands/omni/settings.json /src/openhands/worker/image/omni/settings.json
  test ! -e /etc/openhands/omni/.omni-config.lock
  test ! -e /etc/openhands/omni/settings.json.bak
  ! compgen -G "/var/lib/openhands/omni/.config.*" >/dev/null
  ! compgen -G "/home/agent/.cache/omni/.config.*" >/dev/null
  test "$(stat -c "%U:%G %a" /var/cache/openhands/omni)" = "root:root 755"
  test "$(stat -c "%U:%G %a" /var/lib/openhands/omni)" = "root:root 755"
  test "$(stat -c "%U:%G %a" /home/agent/.cache/omni)" = "agent:agent 700"
  test "$(stat -c "%U:%G %a" /home/agent/.local/state/omni)" = "agent:agent 700"
  printf "%s\n" \
    "openhands-system|root|||" \
    "openhands-agent-no-scripts|agent|true||" \
    "openhands-agent-claude|agent||true|@anthropic-ai/claude-code" \
    "openhands-system|root|||" \
    "openhands-agent-no-scripts|agent|true||" \
    "openhands-agent-claude|agent||true|@anthropic-ai/claude-code" > /tmp/omni-calls.prefix.expected
  cut -d "|" -f 1-5 /tmp/omni-calls > /tmp/omni-calls.prefix
  cmp -s /tmp/omni-calls.prefix.expected /tmp/omni-calls.prefix
  test "$(cut -d "|" -f 6 /tmp/omni-calls | sort -u | wc -l)" = 6
  test "$(awk -F "|" '\''BEGIN { ok = 1 } $2 == "root" { ok = ok && $6 ~ /^\/var\/lib\/openhands\/omni\/\.config\.[[:alnum:]]{6}\/settings\.json$/ && $7 == "root:root 700/root:root 600"; next } $2 == "agent" { ok = ok && $6 ~ /^\/home\/agent\/\.cache\/omni\/\.config\.[[:alnum:]]{6}\/settings\.json$/ && $7 == "agent:agent 700/agent:agent 600"; next } { ok = 0 } END { exit !(NR == 6 && ok) }'\'' /tmp/omni-calls; echo $?)" = 0
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
  cmp -s /etc/wsl.conf /src/openhands/worker/image/rootfs-wsl/etc/wsl.conf

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
  marker_digest=$(/usr/bin/awk "NR == 1 && NF == 3 && \$1 == \"v2\" && \$2 == \"sha256\" && \$3 ~ /^[0-9a-f]{64}$/ { print \$3; next } { exit 1 } END { if (NR != 1) exit 1 }" "$node_home/.openhands-manifest")
  printf "v2 sha256 %s\n" "$marker_digest" > /tmp/manifest.expected
  cmp -s /tmp/manifest.expected "$node_home/.openhands-manifest"
  test "$(stat -c "%U:%G" /usr/local/bin/node)" = "root:root"
  test "$(readlink /usr/local/bin/node)" = "$node_home/bin/node"
  for path in /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/uv /usr/local/bin/uvx; do
    test "$(stat -c "%U:%G %a" "$path")" = "root:root 755"
  done
  printf "#!/bin/sh\nexec %s/bin/node %s/lib/node_modules/npm/bin/npm-cli.js \"\$@\"\n" "$node_home" "$node_home" > /tmp/npm.expected
  printf "#!/bin/sh\nexec %s/bin/node %s/lib/node_modules/npm/bin/npx-cli.js \"\$@\"\n" "$node_home" "$node_home" > /tmp/npx.expected
  cmp -s /tmp/npm.expected /usr/local/bin/npm
  cmp -s /tmp/npx.expected /usr/local/bin/npx

  ! su -s /bin/sh agent -c "WSL_DISTRO_NAME=openhands-worker bash /opt/openhands-build/provision.sh"
  ! env WSL_DISTRO_NAME=wrong-distro bash /opt/openhands-build/provision.sh
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  printf "%s\n" "#!/bin/sh" "touch /tmp/foreign-uv-executed" > /usr/local/bin/uv
  chmod 0755 /usr/local/bin/uv
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  cmp -s /etc/wsl.conf /src/openhands/worker/image/rootfs-wsl/etc/wsl.conf
  test "$(stat -c "%U:%G %a" /etc/wsl.conf)" = "root:root 644"
  test ! -e /tmp/foreign-uv-executed
  test ! -e /opt/openhands/node-v24.20.0-linux-x64
  test ! -e /usr/local/bin/node
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  printf "%s\n" "#!/bin/sh" "touch /tmp/foreign-node-executed" > /opt/openhands/node-v24.20.0-linux-x64/bin/node
  rm /usr/local/bin/uvx
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test ! -e /tmp/foreign-node-executed
  test ! -e /usr/local/bin/uvx
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  printf corrupt > /opt/openhands/node-v24.20.0-linux-x64/lib/node_modules/npm/node_modules/example/index.js
  rm /usr/local/bin/uvx
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test "$(cat /opt/openhands/node-v24.20.0-linux-x64/lib/node_modules/npm/node_modules/example/index.js)" = corrupt
  test ! -e /usr/local/bin/uvx
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  printf extra > /opt/openhands/node-v24.20.0-linux-x64/lib/.openhands-manifest
  rm /usr/local/bin/node
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test "$(cat /opt/openhands/node-v24.20.0-linux-x64/lib/.openhands-manifest)" = extra
  test ! -e /usr/local/bin/node
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  rm /opt/openhands/node-v24.20.0-linux-x64/lib/node_modules/npm/node_modules/example/index.js
  rm /usr/local/bin/uvx
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test ! -e /opt/openhands/node-v24.20.0-linux-x64/lib/node_modules/npm/node_modules/example/index.js
  test ! -e /usr/local/bin/uvx
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  chmod 0600 /opt/openhands/node-v24.20.0-linux-x64/lib/node_modules/npm/node_modules/example/index.js
  rm /usr/local/bin/node
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test "$(stat -c "%a" /opt/openhands/node-v24.20.0-linux-x64/lib/node_modules/npm/node_modules/example/index.js)" = 600
  test ! -e /usr/local/bin/node
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  chown agent:agent /opt/openhands/node-v24.20.0-linux-x64/lib/node_modules/npm/node_modules/example/index.js
  rm /usr/local/bin/node
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test "$(stat -c "%U:%G" /opt/openhands/node-v24.20.0-linux-x64/lib/node_modules/npm/node_modules/example/index.js)" = agent:agent
  test ! -e /usr/local/bin/node
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  rm /opt/openhands/node-v24.20.0-linux-x64/bin/npm
  ln -s ../lib/node_modules/npm/bin/npx-cli.js /opt/openhands/node-v24.20.0-linux-x64/bin/npm
  rm /usr/local/bin/node
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test "$(readlink /opt/openhands/node-v24.20.0-linux-x64/bin/npm)" = ../lib/node_modules/npm/bin/npx-cli.js
  test ! -e /usr/local/bin/node
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  node_home=/opt/openhands/node-v24.20.0-linux-x64
  cp "$node_home/.openhands-manifest" /tmp/manifest.expected
  touch -d @123 "$node_home" "$node_home/bin" "$node_home/bin/node"
  bash /opt/openhands-build/provision.sh
  cmp -s /tmp/manifest.expected "$node_home/.openhands-manifest"
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  node_home=/opt/openhands/node-v24.20.0-linux-x64
  cp "$node_home/.openhands-manifest" /tmp/manifest.expected
  /usr/bin/truncate -s -1 "$node_home/.openhands-manifest"
  bash /opt/openhands-build/provision.sh
  cmp -s /tmp/manifest.expected "$node_home/.openhands-manifest"
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  node_home=/opt/openhands/node-v24.20.0-linux-x64
  printf "arbitrary non-v2 marker\n" > "$node_home/.openhands-manifest"
  bash /opt/openhands-build/provision.sh
  marker_digest=$(/usr/bin/awk "NR == 1 && NF == 3 && \$1 == \"v2\" && \$2 == \"sha256\" && \$3 ~ /^[0-9a-f]{64}$/ { print \$3; next } { exit 1 } END { if (NR != 1) exit 1 }" "$node_home/.openhands-manifest")
  printf "v2 sha256 %s\n" "$marker_digest" > /tmp/manifest.expected
  cmp -s /tmp/manifest.expected "$node_home/.openhands-manifest"
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  node_home=/opt/openhands/node-v24.20.0-linux-x64
  printf "D\t755\tbin\nL\t777\t../lib/node_modules/npm/bin/npm-cli.js\tbin/npm\nF\t644\t%s\tlib/example\n" \
    0000000000000000000000000000000000000000000000000000000000000000 > "$node_home/.openhands-manifest"
  bash /opt/openhands-build/provision.sh
  marker_digest=$(/usr/bin/awk "NR == 1 && NF == 3 && \$1 == \"v2\" && \$2 == \"sha256\" && \$3 ~ /^[0-9a-f]{64}$/ { print \$3; next } { exit 1 } END { if (NR != 1) exit 1 }" "$node_home/.openhands-manifest")
  printf "v2 sha256 %s\n" "$marker_digest" > /tmp/manifest.expected
  cmp -s /tmp/manifest.expected "$node_home/.openhands-manifest"
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  node_home=/opt/openhands/node-v24.20.0-linux-x64
  printf corrupt > "$node_home/lib/node_modules/npm/node_modules/example/index.js"
  printf "arbitrary non-v2 marker\n" > "$node_home/.openhands-manifest"
  cp "$node_home/.openhands-manifest" /tmp/manifest.expected
  rm /usr/local/bin/uvx
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  cmp -s /tmp/manifest.expected "$node_home/.openhands-manifest"
  test ! -e /usr/local/bin/uvx
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  node_home=/opt/openhands/node-v24.20.0-linux-x64
  printf "arbitrary non-v2 marker\n" > "$node_home/.openhands-manifest"
  cp "$node_home/.openhands-manifest" /tmp/manifest.expected
  if FIXTURE_FAIL_RENAME_DEST="$node_home/.openhands-manifest" bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  cmp -s /tmp/manifest.expected "$node_home/.openhands-manifest"
  ! compgen -G "$node_home/.openhands-manifest.*" >/dev/null
  ! compgen -G "/opt/openhands/.node-stage.*" >/dev/null
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  node_home=/opt/openhands/node-v24.20.0-linux-x64
  mkdir -m 0755 /opt/openhands/.node-stage.crash
  printf stale > /opt/openhands/.node-stage.crash/node-manifest-replacement.stale
  chmod 0644 /opt/openhands/.node-stage.crash/node-manifest-replacement.stale
  bash /opt/openhands-build/provision.sh
  test "$(cat /opt/openhands/.node-stage.crash/node-manifest-replacement.stale)" = stale
  marker_digest=$(/usr/bin/awk "NR == 1 && NF == 3 && \$1 == \"v2\" && \$2 == \"sha256\" && \$3 ~ /^[0-9a-f]{64}$/ { print \$3; next } { exit 1 } END { if (NR != 1) exit 1 }" "$node_home/.openhands-manifest")
  printf "v2 sha256 %s\n" "$marker_digest" > /tmp/manifest.expected
  cmp -s /tmp/manifest.expected "$node_home/.openhands-manifest"
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  node_home=/opt/openhands/node-v24.20.0-linux-x64
  printf stale > "$node_home/.openhands-manifest.stale"
  chmod 0644 "$node_home/.openhands-manifest.stale"
  cp "$node_home/.openhands-manifest" /tmp/manifest.expected
  rm /usr/local/bin/uvx
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  cmp -s /tmp/manifest.expected "$node_home/.openhands-manifest"
  test "$(cat "$node_home/.openhands-manifest.stale")" = stale
  test ! -e /usr/local/bin/uvx
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  node_home=/opt/openhands/node-v24.20.0-linux-x64
  printf "v2 sha256 %064d\n" 0 > "$node_home/.openhands-manifest"
  cp "$node_home/.openhands-manifest" /tmp/manifest.expected
  rm /usr/local/bin/uvx
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  cmp -s /tmp/manifest.expected "$node_home/.openhands-manifest"
  test ! -e /usr/local/bin/uvx
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  rm /usr/local/bin/node /usr/local/bin/uvx
  bash /opt/openhands-build/provision.sh
  test "$(readlink /usr/local/bin/node)" = /opt/openhands/node-v24.20.0-linux-x64/bin/node
  test "$(/usr/local/bin/uvx --version)" = "uvx 0.12.7 (a0b1c2d3 2026-08-29 x86_64-unknown-linux-gnu)"
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  chmod 0777 /opt
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  cmp -s /etc/wsl.conf /src/openhands/worker/image/rootfs-wsl/etc/wsl.conf
  test ! -e /opt/openhands
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  FIXTURE_UNAME=aarch64 bash /opt/openhands-build/provision.sh
  test -d /opt/openhands/node-v24.20.0-linux-arm64
  test "$(readlink /usr/local/bin/node)" = /opt/openhands/node-v24.20.0-linux-arm64/bin/node
  test "$(/usr/local/bin/uv --version)" = "uv 0.12.7 (a0b1c2d3 2026-08-29 aarch64-unknown-linux-gnu)"
  cmp -s /etc/wsl.conf /src/openhands/worker/image/rootfs-wsl/etc/wsl.conf
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  if FIXTURE_UNAME=armv7l bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test ! -e /opt/openhands
'

run_container '
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test ! -e /opt/openhands
'

run_container '
  OPENHANDS_IMAGE_BUILD=1 bash /opt/openhands-build/provision.sh
  test -d /opt/openhands/node-v24.20.0-linux-x64
  test ! -e /etc/wsl.conf
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  rmdir /usr/local/bin
  mkdir /tmp/foreign-bin
  ln -s /tmp/foreign-bin /usr/local/bin
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  cmp -s /etc/wsl.conf /src/openhands/worker/image/rootfs-wsl/etc/wsl.conf
  test -L /usr/local/bin
  test ! -e /opt/openhands
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-corrupt-node-download
  bash /opt/openhands-build/provision.sh && exit 1
  cmp -s /etc/wsl.conf /src/openhands/worker/image/rootfs-wsl/etc/wsl.conf
  test ! -e /opt/openhands/node-v24.20.0-linux-x64
  test ! -e /usr/local/bin/uv
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-reserved-manifest
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  cmp -s /etc/wsl.conf /src/openhands/worker/image/rootfs-wsl/etc/wsl.conf
  test ! -e /opt/openhands/node-v24.20.0-linux-x64
  test ! -e /usr/local/bin/uv
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  while IFS=: read -r destination pattern; do
    /usr/bin/rm -rf -- /opt/openhands
    /usr/bin/rm -f -- /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/uv /usr/local/bin/uvx
    if FIXTURE_FAIL_RENAME_DEST="/usr/local/bin/$destination" bash /opt/openhands-build/provision.sh; then
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
    if /bin/bash /opt/openhands-build/provision.sh; then
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
  if /bin/bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test ! -e /opt/openhands/node-v24.20.0-linux-x64
  test ! -e /usr/local/bin/uvx
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  failures=0
  for producer in tar-list safety-find link-find tar-digest sha256sum; do
    rm -rf /opt/openhands
    rm -f /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/uv /usr/local/bin/uvx
    rm -f /tmp/fixture-fail-*
    touch "/tmp/fixture-fail-$producer"
    if bash /opt/openhands-build/provision.sh; then
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
  ln -s /opt/openhands-build/provision.sh /tmp/provision
  env WSL_DISTRO_NAME=openhands-worker bash /tmp/provision
  cmp -s /etc/wsl.conf /src/openhands/worker/image/rootfs-wsl/etc/wsl.conf
'

run_container '
  mkdir /tmp/assets
  cp /opt/openhands-build/provision.sh /tmp/assets/provision.sh
  ln -s /src/openhands/worker/image/rootfs-wsl/etc/wsl.conf /tmp/assets/wsl.conf
  if env WSL_DISTRO_NAME=openhands-worker bash /tmp/assets/provision.sh; then
    exit 1
  fi
  test -L /tmp/assets/wsl.conf
'

run_container '
  useradd --create-home --shell /bin/sh --user-group agent
  if env WSL_DISTRO_NAME=openhands-worker bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
'

run_container '
  useradd --create-home --home-dir /srv/agent --shell /bin/bash --user-group agent
  if env WSL_DISTRO_NAME=openhands-worker bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
'

run_container '
  mkdir /home/agent
  if env WSL_DISTRO_NAME=openhands-worker bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  ! id agent >/dev/null 2>&1
  test "$(stat -c "%U:%G %a" /home/agent)" = "root:root 755"
'

run_container '
  useradd --create-home --shell /bin/bash --user-group agent
  getent group sudo >/dev/null || groupadd sudo
  usermod -aG sudo agent
  if env WSL_DISTRO_NAME=openhands-worker bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
'

run_container '
  ln -s /tmp /home/agent
  if env WSL_DISTRO_NAME=openhands-worker bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  ! id agent >/dev/null 2>&1
  test -L /home/agent
'

run_container '
  useradd --create-home --shell /bin/bash --user-group agent
  chown root:root /home/agent
  if env WSL_DISTRO_NAME=openhands-worker bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
'

run_container '
  useradd --create-home --shell /bin/bash --user-group agent
  ln -s /tmp /home/agent/.codex
  if env WSL_DISTRO_NAME=openhands-worker bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test -L /home/agent/.codex
'

run_container '
  useradd --create-home --shell /bin/bash --user-group agent
  touch /home/agent/.claude
  if env WSL_DISTRO_NAME=openhands-worker bash /opt/openhands-build/provision.sh; then
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
  if env WSL_DISTRO_NAME=openhands-worker bash /opt/openhands-build/provision.sh; then
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
  if env WSL_DISTRO_NAME=openhands-worker bash /opt/openhands-build/provision.sh; then
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
  if env WSL_DISTRO_NAME=openhands-worker bash /opt/openhands-build/provision.sh; then
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
  if env WSL_DISTRO_NAME=openhands-worker bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test "$(cat /tmp/victim)" = victim
  test "$(stat -c "%U:%G %a" /tmp/victim)" = "root:root 600"
'

run_container '
  ln -s /tmp /etc/wsl.conf
  if env WSL_DISTRO_NAME=openhands-worker bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test -L /etc/wsl.conf
'

run_container '
  mkdir /etc/wsl.conf
  if env WSL_DISTRO_NAME=openhands-worker bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test ! -e /etc/wsl.conf/wsl.conf
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-wrong-package
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-extra-package
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  useradd -K HOME_MODE=0700 -K UMASK=0077 --create-home --shell /bin/bash --user-group agent
  mkdir /tmp/foreign-npm-root
  ln -s /tmp/foreign-npm-root /home/agent/.local
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test -L /home/agent/.local
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-foreign-bin
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test -L /home/agent/.local/bin/codex
  test "$(readlink /home/agent/.local/bin/codex)" = /tmp/foreign-bin
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-extra-bin
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test -L /home/agent/.local/bin/unexpected
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-corrupt-agent-root
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test "$(stat -c "%a" /home/agent/.local)" = 755
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-npm-fail
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test "$(stat -c "%U:%G %a" /home/agent/.local)" = "agent:agent 700"
  test ! -e /home/agent/.local/bin/claude
  test -e /home/agent/.local/lib/node_modules/@openhands/agent-canvas/package.json
  rm /tmp/fixture-npm-fail
  bash /opt/openhands-build/provision.sh
  test "$(/home/agent/.local/bin/claude --version)" = "2.1.251 (Claude Code)"
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  printf CLAUDE_CODE_OAUTH_TOKEN > /home/agent/.claude/credentials.json
  printf OPENAI_API_KEY > /home/agent/.codex/auth.json
  bash /opt/openhands-build/provision.sh
  test "$(cat /home/agent/.claude/credentials.json)" = CLAUDE_CODE_OAUTH_TOKEN
  test "$(cat /home/agent/.codex/auth.json)" = OPENAI_API_KEY
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  mkdir -p /home/agent/.cache/npm/unrelated/deep
  chown -R agent:agent /home/agent/.cache/npm/unrelated
  chmod 0777 /home/agent/.cache/npm/unrelated/deep
  ln -s /tmp /home/agent/.cache/npm/unrelated/deep-link
  bash /opt/openhands-build/provision.sh
  test -L /home/agent/.cache/npm/unrelated/deep-link
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  useradd --create-home --shell /bin/bash --user-group agent
  chmod 0700 /home/agent
  mkdir /home/agent/.local
  chown root:root /home/agent/.local
  chmod 0700 /home/agent/.local
  if bash /opt/openhands-build/provision.sh; then
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
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test "$(stat -c "%U:%G %a" /home/agent/.cache/npm)" = "root:root 700"
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  useradd --create-home --shell /bin/bash --user-group agent
  chmod 0700 /home/agent
  mkdir -p /home/agent/.local/lib/node_modules /tmp/external-openai/codex/bin
  chown -R agent:agent /home/agent/.local /tmp/external-openai
  chmod 0700 /home/agent/.local /home/agent/.local/lib /home/agent/.local/lib/node_modules
  printf "{\"name\":\"@openai/codex\",\"version\":\"0.151.0\"}\n" > /tmp/external-openai/codex/package.json
  printf "#!/bin/sh\n" > /tmp/external-openai/codex/bin/codex
  chmod 0700 /tmp/external-openai/codex/bin/codex
  printf sentinel > /tmp/external-openai/sentinel
  ln -s /tmp/external-openai /home/agent/.local/lib/node_modules/@openai
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test "$(cat /tmp/external-openai/sentinel)" = sentinel
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  ln -s /tmp /etc/openhands
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test -L /etc/openhands
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  mkdir /etc/openhands
  printf foreign > /etc/openhands/npmrc
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test "$(cat /etc/openhands/npmrc)" = foreign
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  bash /opt/openhands-build/provision.sh
  test "$(stat -c "%U:%G %a" /usr/bin/rbw)" = "root:root 755"
  test "$(/usr/bin/rbw --version)" = "rbw 1.13.2"
  test -L /usr/bin/python3
  case "$(readlink /usr/bin/python3)" in python3.[0-9]*) ;; *) exit 1 ;; esac
  test "$(stat -Lc "%U:%G %a" /usr/bin/python3)" = "root:root 755"
  /usr/bin/python3 -c "import queue"
  test "$(stat -c "%U:%G %a" /usr/local/libexec)" = "root:root 755"
  pinentry=/usr/local/libexec/openhands-rbw-pinentry
  test "$(stat -c "%U:%G %a" "$pinentry")" = "root:root 755"
  credentials=$(mktemp -d)
  trap "rm -rf -- \"$credentials\"" EXIT
  printf "\000%%\r\nA\377" > "$credentials/rbw_master"
  printf "%s\n" "OK rbw credential pinentry ready" "OK" "OK" "OK" "OK" "D %00%25%0D%0A%41%FF" "OK" > /tmp/pinentry.expected
  printf "%s\n" "SETTITLE rbw" "SETPROMPT Master Password" "SETDESC unlock" "SETERROR retry" "GETPIN" |
    env -i PATH=/usr/bin:/bin CREDENTIALS_DIRECTORY="$credentials" "$pinentry" --timeout 0 > /tmp/pinentry.actual 2>/tmp/pinentry.stderr
  cmp -s /tmp/pinentry.expected /tmp/pinentry.actual
  test ! -s /tmp/pinentry.stderr
  printf "%s\n" "OK rbw credential pinentry ready" "OK" "OK" "ERR 83886179 unexpected pinentry prompt" > /tmp/pinentry-wrong.expected
  printf "%s\n" "SETTITLE rbw" "SETPROMPT One-time Password" "GETPIN" |
    env -i PATH=/usr/bin:/bin CREDENTIALS_DIRECTORY="$credentials" "$pinentry" > /tmp/pinentry-wrong.actual 2>/tmp/pinentry.stderr
  cmp -s /tmp/pinentry-wrong.expected /tmp/pinentry-wrong.actual
  test ! -s /tmp/pinentry.stderr
  printf "%s\n" "OK rbw credential pinentry ready" "ERR 83886179 unsupported pinentry command" > /tmp/pinentry-unknown.expected
  printf "%s\n" "OPTION grab" |
    env -i PATH=/usr/bin:/bin CREDENTIALS_DIRECTORY="$credentials" "$pinentry" > /tmp/pinentry-unknown.actual 2>/tmp/pinentry.stderr
  cmp -s /tmp/pinentry-unknown.expected /tmp/pinentry-unknown.actual
  test ! -s /tmp/pinentry.stderr
  rm "$credentials/rbw_master"
  printf "%s\n" "OK rbw credential pinentry ready" "OK" "ERR 83886179 credential unavailable" > /tmp/pinentry-missing.expected
  printf "%s\n" "SETPROMPT Master Password" "GETPIN" |
    env -i PATH=/usr/bin:/bin CREDENTIALS_DIRECTORY="$credentials" "$pinentry" > /tmp/pinentry-missing.actual 2>/tmp/pinentry.stderr
  cmp -s /tmp/pinentry-missing.expected /tmp/pinentry-missing.actual
  test ! -s /tmp/pinentry.stderr
  : > "$credentials/rbw_master"
  printf "%s\n" "OK rbw credential pinentry ready" "OK" "ERR 83886179 empty credential" > /tmp/pinentry-empty.expected
  printf "%s\n" "SETPROMPT Master Password" "GETPIN" |
    env -i PATH=/usr/bin:/bin CREDENTIALS_DIRECTORY="$credentials" "$pinentry" > /tmp/pinentry-empty.actual 2>/tmp/pinentry.stderr
  cmp -s /tmp/pinentry-empty.expected /tmp/pinentry-empty.actual
  test ! -s /tmp/pinentry.stderr
  printf secret > "$credentials/rbw_master"
  printf "%s\n" "OK rbw credential pinentry ready" "OK" > /tmp/pinentry-bye.expected
  printf "%s\n" "BYE" |
    env -i PATH=/usr/bin:/bin CREDENTIALS_DIRECTORY="$credentials" "$pinentry" > /tmp/pinentry-bye.actual 2>/tmp/pinentry.stderr
  cmp -s /tmp/pinentry-bye.expected /tmp/pinentry-bye.actual
  test ! -s /tmp/pinentry.stderr
  bash /opt/openhands-build/provision.sh
  test "$(stat -c "%U:%G %a" "$pinentry")" = "root:root 755"
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  mkdir -p /usr/local/libexec
  printf foreign > /usr/local/libexec/openhands-rbw-pinentry
  chmod 0755 /usr/local/libexec/openhands-rbw-pinentry
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test "$(cat /usr/local/libexec/openhands-rbw-pinentry)" = foreign
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-dpkg-verify-fail
  printf "#!/bin/sh\ntouch /tmp/rbw-executed\n" > /usr/bin/rbw
  chmod 0755 /usr/bin/rbw
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test ! -e /tmp/rbw-executed
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-python-dpkg-verify-fail
  printf "#!/bin/sh\ntouch /tmp/python-executed\n" > /usr/bin/python3
  chmod 0755 /usr/bin/python3
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test ! -e /tmp/python-executed
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-python-dpkg-verify-nonzero
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-python-stdlib-dpkg-verify-fail
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  rm /usr/bin/python3
  printf "#!/bin/sh\\nprintf \"%%s:%%s:%%s\\\\n\" \"\$1\" \"\$2\" \"\$3\" >> /tmp/python-invocations\\nexit 1\\n" > /usr/bin/python3
  chmod 0755 /usr/bin/python3
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test "$(cat /tmp/python-invocations)" = "-I:-c:import queue"
  test ! -e /usr/local/libexec/openhands-rbw-pinentry
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  mkdir /tmp/python-cwd-shadow
  printf "raise SystemExit(1)\\n" > /tmp/python-cwd-shadow/queue.py
  cd /tmp/python-cwd-shadow
  bash /opt/openhands-build/provision.sh
'

run_container '
  verifier_source="source <(sed '\''/^trap cleanup EXIT$/,\$d'\'' /opt/openhands-build/provision.sh)"
  for package in rbw python; do
    case "$package" in
      rbw) output=/tmp/fixture-rbw-dpkg-verify-output; verifier=assert_rbw_package ;;
      python) output=/tmp/fixture-python-dpkg-verify-output; verifier=assert_python_package ;;
    esac
    printf "missing /usr/share/man/man1/%s.1.gz\\nmissing    /usr/share/doc/%s/copyright\\n" "$package" "$package" > "$output"
    bash -euo pipefail -c "$verifier_source; $verifier"
    for line in \
      "missing /usr/bin/$package" \
      "??5?????? /usr/share/man/man1/$package.1.gz" \
      "missing /etc/$package.conf" \
      "unexpected /usr/share/doc/$package/copyright"; do
      printf "%s\\n" "$line" > "$output"
      if bash -euo pipefail -c "$verifier_source; $verifier"; then
        exit 1
      fi
    done
    printf "missing /usr/share/doc/%s/copyright\\nunexpected line\\n" "$package" > "$output"
    if bash -euo pipefail -c "$verifier_source; $verifier"; then
      exit 1
    fi
  done
  : > /tmp/fixture-python-dpkg-verify-output
  printf "missing /usr/share/doc/python3/copyright\\n" > /tmp/fixture-python-stdlib-dpkg-verify-output
  bash -euo pipefail -c "$verifier_source; assert_python_package"
  printf "??5?????? /usr/lib/python3/queue.py\\n" > /tmp/fixture-python-stdlib-dpkg-verify-output
  if bash -euo pipefail -c "$verifier_source; assert_python_package"; then
    exit 1
  fi
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-dpkg-verify-nonzero
  if bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  if FIXTURE_RACE_DEST=/usr/local/libexec/openhands-rbw-pinentry bash /opt/openhands-build/provision.sh; then
    exit 1
  fi
  test "$(cat /usr/local/libexec/openhands-rbw-pinentry)" = foreign
  ! compgen -G "/usr/local/libexec/.openhands-rbw-pinentry.*" >/dev/null
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  useradd -K HOME_MODE=0700 -K UMASK=0077 --create-home --shell /bin/bash --user-group agent
  mkdir -p /var/lib/openhands/omni /home/agent/.cache/omni
  chown agent:agent /home/agent/.cache /home/agent/.cache/omni
  chmod 0700 /home/agent/.cache /home/agent/.cache/omni
  mkdir -m 0700 /var/lib/openhands/omni/.config.Abc123 /home/agent/.cache/omni/.config.Def456
  touch /var/lib/openhands/omni/.config.Abc123/settings.json /home/agent/.cache/omni/.config.Def456/settings.json
  chown -R agent:agent /home/agent/.cache/omni/.config.Def456
  bash /opt/openhands-build/provision.sh
  test ! -e /var/lib/openhands/omni/.config.Abc123
  test ! -e /home/agent/.cache/omni/.config.Def456
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  useradd -K HOME_MODE=0700 -K UMASK=0077 --create-home --shell /bin/bash --user-group agent
  mkdir -p /var/lib/openhands/omni
  mkdir -m 0700 /var/lib/openhands/omni/.config.invalid
  printf keep > /var/lib/openhands/omni/.config.invalid/keep
  if bash /opt/openhands-build/provision.sh; then exit 1; fi
  test "$(cat /var/lib/openhands/omni/.config.invalid/keep)" = keep
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  useradd -K HOME_MODE=0700 -K UMASK=0077 --create-home --shell /bin/bash --user-group agent
  mkdir -p /home/agent/.cache/omni /tmp/foreign-omni-config
  printf keep > /tmp/foreign-omni-config/keep
  chown -R agent:agent /home/agent/.cache
  chmod 0700 /home/agent/.cache /home/agent/.cache/omni
  ln -s /tmp/foreign-omni-config /home/agent/.cache/omni/.config.Abc123
  if bash /opt/openhands-build/provision.sh; then exit 1; fi
  test "$(cat /tmp/foreign-omni-config/keep)" = keep
'

run_container '
  export WSL_DISTRO_NAME=openhands-worker
  touch /tmp/fixture-omni-term-after-artifacts
  set +e
  bash /opt/openhands-build/provision.sh
  status=$?
  set -e
  test "$status" = 143
  test "$(stat -c "%U:%G %a" /etc/openhands/omni)" = "root:root 755"
  test "$(stat -c "%U:%G %a" /etc/openhands/omni/settings.json)" = "root:root 644"
  cmp -s /etc/openhands/omni/settings.json /src/openhands/worker/image/omni/settings.json
  test ! -e /etc/openhands/omni/.omni-config.lock
  test ! -e /etc/openhands/omni/settings.json.bak
  ! compgen -G "/var/lib/openhands/omni/.config.*" >/dev/null
  ! compgen -G "/home/agent/.cache/omni/.config.*" >/dev/null
'

if [ "${RUN_WSL_REAL_TOOLCHAIN_TESTS:-0}" = 1 ]; then
  docker run --rm --platform linux/amd64 --tmpfs /opt:rw,exec,mode=755,size=512m \
    -v "$repo_root:/src:ro" ubuntu:26.04 bash -euo pipefail -c '
      export WSL_DISTRO_NAME=openhands-worker
      bash /opt/openhands-build/provision.sh
      bash /opt/openhands-build/provision.sh
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
