#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
entrypoint="$repo_root/runtimes/wsl/runtime/container-entrypoint.sh"
unit="$repo_root/runtimes/wsl/runtime/agent-canvas.service"
nginx_site="$repo_root/runtimes/wsl/runtime/nginx-site.conf"
distro_config="$repo_root/runtimes/wsl/wsl-distribution.conf"
containerfile="$repo_root/runtimes/wsl/Containerfile"

for file in "$entrypoint" "$unit" "$nginx_site" "$distro_config" "$containerfile"; do
  test -f "$file"
done

grep -Fx 'User=agent' "$unit"
grep -Fx 'LoadCredential=local_backend_api_key' "$unit"
grep -F 'CREDENTIALS_DIRECTORY' "$unit"
grep -F '/home/agent/.local/bin/agent-canvas --public' "$unit"
grep -F 'listen 443 ssl;' "$nginx_site"
grep -F 'proxy_pass http://127.0.0.1:8000;' "$nginx_site"
grep -Fx 'defaultUid = 1000' "$distro_config"
grep -Fx 'defaultName = openhands-worker' "$distro_config"
grep -F 'ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b' "$containerfile"
grep -F 'OPENHANDS_IMAGE_BUILD=1' "$containerfile"
grep -F 'openhands-agent-server==1.44.0' "$containerfile"
grep -F 'openhands-automation==1.9.0' "$containerfile"
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
