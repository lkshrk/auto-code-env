#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
entrypoint="$repo_root/runtimes/wsl/runtime/container-entrypoint.sh"
unit="$repo_root/runtimes/wsl/runtime/agent-canvas.service"
nginx_site="$repo_root/runtimes/wsl/runtime/nginx-site.conf"
distro_config="$repo_root/runtimes/wsl/wsl-distribution.conf"
containerfile="$repo_root/runtimes/wsl/Containerfile"
canvas_patch="$repo_root/runtimes/wsl/runtime/patch-agent-canvas-automation.mjs"

for file in "$entrypoint" "$unit" "$nginx_site" "$distro_config" "$containerfile" "$canvas_patch"; do
  test -f "$file"
done
grep -F 'OpenHands/OpenHands#16217' "$canvas_patch"
grep -F 'Remove this patch when' "$canvas_patch"

grep -Fx 'User=agent' "$unit"
grep -Fx 'LoadCredential=local_backend_api_key' "$unit"
grep -F 'CREDENTIALS_DIRECTORY' "$unit"
grep -F 'ExecStart=/bin/bash -eu -c' "$unit"
grep -F 'test -r "$$credential"' "$unit"
grep -F 'test -n "$$LOCAL_BACKEND_API_KEY"' "$unit"
grep -F '/home/agent/.local/bin/agent-canvas --public' "$unit"
grep -F 'listen 443 ssl;' "$nginx_site"
grep -F 'proxy_pass http://127.0.0.1:8000;' "$nginx_site"
grep -F 'proxy_set_header Upgrade $http_upgrade;' "$nginx_site"
grep -F 'proxy_set_header Connection "upgrade";' "$nginx_site"
grep -F 'proxy_read_timeout 86400;' "$nginx_site"
grep -F 'proxy_send_timeout 86400;' "$nginx_site"
grep -Fx 'defaultUid = 1000' "$distro_config"
grep -Fx 'defaultName = openhands-worker' "$distro_config"
grep -F 'ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b' "$containerfile"
grep -F "ubuntu:x:1000:1000:Ubuntu:/home/ubuntu:/bin/bash" "$containerfile"
grep -F "ubuntu:x:1000:" "$containerfile"
grep -F '/usr/sbin/userdel -r ubuntu' "$containerfile"
grep -F '/usr/sbin/groupdel ubuntu' "$containerfile"
grep -F '! -e /home/ubuntu' "$containerfile"
grep -F 'OPENHANDS_IMAGE_BUILD=1' "$containerfile"
grep -F 'openhands-agent-server==1.44.0' "$containerfile"
grep -F 'openhands-automation==1.9.0' "$containerfile"
grep -F 'patch-agent-canvas-automation.mjs' "$containerfile"
grep -F 'uv run --no-project --with openhands-automation==1.9.0 python -m uvicorn openhands.automation.app:app' "$containerfile"
grep -F 'systemd-sysv' "$containerfile"
grep -F 'test -x /sbin/init' "$containerfile"
grep -F 'test -x /usr/bin/systemctl' "$containerfile"
grep -F 'test ! -e /etc/systemd/system/multi-user.target.wants/nginx.service' "$containerfile"
grep -Fx 'EXPOSE 443' "$containerfile"

docker run --rm -v "$repo_root:/src:ro" ubuntu:26.04 bash -euo pipefail -c '
  entrypoint=/src/runtimes/wsl/runtime/container-entrypoint.sh
  mkdir -p /etc/nginx/tls
  existing_user=$(getent passwd 1000 | cut -d: -f1)
  existing_group=$(getent group 1000 | cut -d: -f1)
  usermod -l agent "$existing_user"
  groupmod -n agent "$existing_group"
  usermod -d /home/agent -m agent
  mkdir -p /home/agent/.local/bin
  printf "#!/bin/sh\nprintf \"%%s\n\" \"\$LOCAL_BACKEND_API_KEY\" > /tmp/canvas-key\nexec sleep 30\n" > /home/agent/.local/bin/agent-canvas
  chmod 0755 /home/agent/.local/bin/agent-canvas
  printf "#!/bin/sh\ncase \"\${1:-}\" in -t) exit 0 ;; esac\nexec sleep 30\n" > /usr/sbin/nginx
  chmod 0755 /usr/sbin/nginx
  printf cert > /etc/nginx/tls/tls.crt
  printf key > /etc/nginx/tls/tls.key

  if env -u LOCAL_BACKEND_API_KEY -u LOCAL_BACKEND_API_KEY_FILE "$entrypoint"; then exit 1; fi
  if LOCAL_BACKEND_API_KEY= "$entrypoint"; then exit 1; fi
  rm /etc/nginx/tls/tls.key
  if LOCAL_BACKEND_API_KEY=key "$entrypoint"; then exit 1; fi
  printf key > /etc/nginx/tls/tls.key
  printf file-secret > /tmp/api-key
  output=$(LOCAL_BACKEND_API_KEY_FILE=/tmp/api-key "$entrypoint" & pid=$!; sleep 1; kill -TERM "$pid"; wait "$pid" || true)
  test "$(cat /tmp/canvas-key)" = file-secret
  test -z "$output"
  test ! -e /tmp/api-key-output
'

fixture=$(mktemp "${TMPDIR:-/tmp}/canvas.XXXXXX.mjs")
trap 'rm -f -- "$fixture"' EXIT
printf '%s\n' \
  'function buildAutomationCommand() {' \
  '  const uvxArgs = [];' \
  '  let source = "";' \
  '' \
  '  if (gitRef) {' \
  '    uvxArgs.push(' \
  '      "--refresh",' \
  '      "--from",' \
  '      gitUrl,' \
  '      "uvicorn",' \
  '      "openhands.automation.app:app",' \
  '    );' \
  '    source = `git (${gitRef})`;' \
  '  } else if (version) {' \
  '    // Use specific PyPI version' \
  '    uvxArgs.push(' \
  '      "--from",' \
  '      `${DEFAULT_AUTOMATION_PACKAGE}==${version}`,' \
  '      "uvicorn",' \
  '      "openhands.automation.app:app",' \
  '    );' \
  '    source = `PyPI (${version})`;' \
  '  } else {' \
  '    // Default to released PyPI version' \
  '    uvxArgs.push(' \
  '      "--from",' \
  '      `${DEFAULT_AUTOMATION_PACKAGE}==${DEFAULT_AUTOMATION_VERSION}`,' \
  '      "uvicorn",' \
  '      "openhands.automation.app:app",' \
  '    );' \
  '    source = `PyPI (${DEFAULT_AUTOMATION_VERSION}, default)`;' \
  '  }' \
  '  return {' \
  '    command: "uvx",' \
  '    args: uvxArgs,' \
  '    source,' \
  '  };' \
  '}' > "$fixture"
node "$canvas_patch" "$fixture"
node --check "$fixture"
grep -F '"--no-project"' "$fixture"
grep -F '"--refresh",' "$fixture"
grep -F '"python",' "$fixture"
grep -F '"-m",' "$fixture"
if grep -F 'uvxArgs' "$fixture"; then exit 1; fi
if grep -F 'command: "uvx"' "$fixture"; then exit 1; fi
if sed -n '/else if (version)/,/} else {/p' "$fixture" | grep -F 'uvxArgs.push('; then exit 1; fi
if sed -n '/} else {/,/return {/p' "$fixture" | grep -F 'uvxArgs.push('; then exit 1; fi
if node "$canvas_patch" "$fixture"; then exit 1; fi

docker run --rm -v "$repo_root:/src:ro" ubuntu:26.04 bash -euo pipefail -c '
  credential_command() {
    credential="$CREDENTIALS_DIRECTORY/local_backend_api_key"
    test -r "$credential"
    LOCAL_BACKEND_API_KEY=$(<"$credential")
    test -n "$LOCAL_BACKEND_API_KEY"
  }
  credentials=$(mktemp -d)
  if CREDENTIALS_DIRECTORY="$credentials" credential_command; then exit 1; fi
  : > "$credentials/local_backend_api_key"
  if CREDENTIALS_DIRECTORY="$credentials" credential_command; then exit 1; fi
  printf key > "$credentials/local_backend_api_key"
  CREDENTIALS_DIRECTORY="$credentials" credential_command
'
