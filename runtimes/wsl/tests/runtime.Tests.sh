#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
entrypoint="$repo_root/runtimes/wsl/runtime/container-entrypoint.sh"
unit="$repo_root/runtimes/wsl/runtime/agent-canvas.service"
modules_dropin="$repo_root/runtimes/wsl/runtime/systemd-modules-load-wsl.conf"
overlay="$repo_root/runtimes/wsl/runtime/openhands-overlay.sh"
firewall="$repo_root/runtimes/wsl/firewall.ps1"
keepalive="$repo_root/runtimes/wsl/keepalive.ps1"
nginx_site="$repo_root/runtimes/wsl/runtime/nginx-site.conf"
distro_config="$repo_root/runtimes/wsl/wsl-distribution.conf"
containerfile="$repo_root/runtimes/wsl/Containerfile"
canvas_patch="$repo_root/runtimes/wsl/runtime/patch-agent-canvas-automation.mjs"
ingress_smoke="$repo_root/runtimes/wsl/tests/agent-canvas-ingress-smoke.mjs"
omni_settings="$repo_root/runtimes/wsl/omni/settings.json"

for file in "$entrypoint" "$unit" "$modules_dropin" "$overlay" "$firewall" "$keepalive" "$nginx_site" "$distro_config" "$containerfile" "$canvas_patch" "$ingress_smoke" "$omni_settings"; do
  test -f "$file"
done
test "$(cat "$modules_dropin")" = $'[Unit]\nConditionVirtualization=!wsl'
test "$(jq -r '.version' "$omni_settings")" = 24
jq -e '
  .settings.auto_import == false and
  .settings.dots_disabled == true and
  ([.tools[].providers[].provider] | all(. == "apt" or . == "npm")) and
  ([.groups[].name] | sort) == ["openhands-agent-claude", "openhands-agent-no-scripts", "openhands-system"] and
  ([.. | objects | select(has("provider")) | .provider] | index("script") | not)
' "$omni_settings" >/dev/null
if rg -n -i 'secret|token|password|credential|api[_-]?key' "$omni_settings"; then exit 1; fi
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
if grep -F '/usr/sbin/groupdel ubuntu' "$containerfile"; then exit 1; fi
grep -F '! -e /home/ubuntu' "$containerfile"
grep -F 'OPENHANDS_IMAGE_BUILD=1' "$containerfile"
grep -F 'runtimes/wsl/omni/settings.json /opt/openhands-build/omni/settings.json' "$containerfile"
if grep -F 'apt-get install -y --no-install-recommends nginx' "$containerfile"; then exit 1; fi
grep -F 'openhands-agent-server==1.44.0' "$containerfile"
grep -F 'openhands-automation==1.9.0' "$containerfile"
grep -F 'patch-agent-canvas-automation.mjs' "$containerfile"
grep -F 'agent-canvas-ingress-smoke.mjs' "$containerfile"
grep -F 'scripts/ingress.mjs' "$containerfile"
grep -F 'node --check /home/agent/.local/lib/node_modules/@openhands/agent-canvas/scripts/ingress.mjs' "$containerfile"
grep -F 'agent-canvas-ingress-smoke.mjs /home/agent/.local/lib/node_modules/@openhands/agent-canvas/scripts/ingress.mjs' "$containerfile"
grep -F 'uv run --no-project --with openhands-automation==1.9.0 python -m uvicorn openhands.automation.app:app' "$containerfile"
grep -F 'systemd-sysv' "$containerfile"
modules_copy='systemd-modules-load-wsl.conf /etc/systemd/system/systemd-modules-load.service.d/10-wsl.conf'
wsl_stage=$(sed -n '/^FROM provisioned AS wsl$/,$p' "$containerfile")
pre_wsl=$(sed '/^FROM provisioned AS wsl$/,$d' "$containerfile")
grep -F "$modules_copy" <<< "$wsl_stage"
if grep -F "$modules_copy" <<< "$pre_wsl"; then exit 1; fi
grep -F 'install -y --no-install-recommends systemd systemd-sysv libpam-systemd dbus-user-session locales' <<< "$wsl_stage"
grep -F 'locale-gen en_US.UTF-8 C.UTF-8' <<< "$wsl_stage"
if grep -F 'locale-gen' <<< "$pre_wsl"; then exit 1; fi
overlay_copy='openhands-overlay.sh /usr/local/sbin/openhands-overlay'
grep -F "$overlay_copy" <<< "$wsl_stage"
if grep -F "$overlay_copy" <<< "$pre_wsl"; then exit 1; fi
grep -F 'chmod 0755 /usr/local/sbin/openhands-overlay' <<< "$wsl_stage"
grep -Fx 'MASTER_PASSWORD_FILE=/run/openhands-rbw-master' "$overlay"
grep -F 'rbw config set pinentry "$PINENTRY"' "$overlay"
grep -F 'systemctl enable --now nginx.service agent-canvas.service' "$overlay"
grep -F 'OH_ALLOW_CORS_ORIGINS_' "$overlay"
grep -F '/etc/systemd/system/agent-canvas.service.d/10-overlay.conf' "$overlay"
if grep -E 'RemoteAddress(es)? (Any|\*)' "$firewall"; then exit 1; fi
if grep -F 'Set-NetFirewallHyperVRule' "$firewall"; then exit 1; fi
grep -F -- '--exec /bin/sleep infinity' "$keepalive"
grep -F 'test -x /sbin/init' "$containerfile"
grep -F 'test -x /usr/bin/systemctl' "$containerfile"
grep -F 'test ! -e /etc/systemd/system/multi-user.target.wants/nginx.service' "$containerfile"
grep -Fx 'EXPOSE 443' "$containerfile"
grep -F 'FROM oci AS smoke' "$containerfile"
grep -F 'test "$(/usr/bin/id -u agent)" = 1000' "$containerfile"
grep -F 'test "$(/usr/bin/id -g agent)" = 1000' "$containerfile"
grep -F 'openssl req -x509' "$containerfile"
grep -F '/usr/sbin/nginx -t' "$containerfile"
grep -F '! -e /etc/nginx/tls/tls.key' "$containerfile"

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

ingress_dir=$(mktemp -d "${TMPDIR:-/tmp}/ingress.XXXXXX")
ingress_fixture="$ingress_dir/ingress.mjs"
trap 'rm -f -- "$fixture"; rm -rf -- "$ingress_dir"' EXIT
printf '%s\n' \
  'const server = createServer();' \
  '  server.listen(config.port, () => {' \
  '  console.log("ready");' \
  '});' > "$ingress_fixture"
node "$canvas_patch" "$ingress_fixture"
node --check "$ingress_fixture"
grep -F 'server.listen(config.port, "127.0.0.1", () => {' "$ingress_fixture"
if node "$canvas_patch" "$ingress_fixture"; then exit 1; fi

docker run --rm ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b bash -euo pipefail -c '
  test "$(getent passwd ubuntu)" = "ubuntu:x:1000:1000:Ubuntu:/home/ubuntu:/bin/bash"
  test "$(getent group ubuntu)" = "ubuntu:x:1000:"
  userdel -r ubuntu
  ! getent passwd ubuntu
  ! getent group ubuntu
  ! test -e /home/ubuntu
  useradd -K HOME_MODE=0700 -K UMASK=0077 --create-home --shell /bin/bash --user-group agent
  test "$(id -u agent)" = 1000
  test "$(id -g agent)" = 1000
  test "$(id -nG agent)" = agent
  test "$(getent passwd agent | cut -d: -f6,7)" = /home/agent:/bin/bash
'

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
