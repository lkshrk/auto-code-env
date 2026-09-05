#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
entrypoint="$repo_root/worker/rootfs-oci/usr/local/sbin/container-entrypoint"
unit="$repo_root/worker/rootfs/etc/systemd/system/agent-canvas.service"
modules_dropin="$repo_root/worker/rootfs-wsl/etc/systemd/system/systemd-modules-load.service.d/10-wsl.conf"
prune_service="$repo_root/worker/rootfs-wsl/etc/systemd/system/openhands-run-prune.service"
prune_timer="$repo_root/worker/rootfs-wsl/etc/systemd/system/openhands-run-prune.timer"
overlay="$repo_root/worker/rootfs/usr/local/sbin/openhands-overlay"
applier="$repo_root/worker/rootfs/usr/local/lib/openhands/apply-profile.py"
firewall="$repo_root/worker/windows/firewall.ps1"
keepalive="$repo_root/worker/windows/keepalive.ps1"
nginx_site="$repo_root/worker/rootfs/etc/nginx/conf.d/openhands.conf"
distro_config="$repo_root/worker/rootfs-wsl/etc/wsl-distribution.conf"
containerfile="$repo_root/worker/Containerfile"
canvas_patch="$repo_root/worker/patches/patch-agent-canvas-automation.mjs"
ingress_smoke="$repo_root/worker/tests/agent-canvas-ingress-smoke.mjs"
omni_settings="$repo_root/worker/omni/settings.json"

for file in "$entrypoint" "$unit" "$modules_dropin" "$prune_service" "$prune_timer" "$overlay" "$firewall" "$keepalive" "$nginx_site" "$distro_config" "$containerfile" "$canvas_patch" "$ingress_smoke" "$omni_settings"; do
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
grep -Fx 'User=agent' "$prune_service"
grep -Fx 'Type=oneshot' "$prune_service"
grep -F -- '-mindepth 1 -maxdepth 1 -type d -mmin +1440 -exec /bin/rm -rf {} +' "$prune_service"
grep -F 'test -d "$runs" || exit 0' "$prune_service"
grep -Fx 'ReadWritePaths=-/home/agent/.openhands/agent-canvas/workspaces/automation-runs' "$prune_service"
grep -Fx 'OnUnitActiveSec=1h' "$prune_timer"
grep -Fx 'WantedBy=timers.target' "$prune_timer"
grep -F 'systemctl enable --now nginx.service agent-canvas.service openhands-run-prune.timer' "$overlay"
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
grep -F 'worker/omni/settings.json /opt/openhands-build/omni/settings.json' "$containerfile"
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
rootfs_copy='COPY --chown=root:root worker/rootfs/ /'
oci_copy='COPY --chown=root:root worker/rootfs-oci/ /'
wsl_copy='COPY --chown=root:root worker/rootfs-wsl/ /'
wsl_stage=$(sed -n '/^FROM provisioned AS wsl$/,$p' "$containerfile")
pre_wsl=$(sed '/^FROM provisioned AS wsl$/,$d' "$containerfile")
oci_stage=$(sed -n '/^FROM provisioned AS oci$/,/^FROM oci AS smoke$/p' "$containerfile")
grep -Fx "$rootfs_copy" <<< "$pre_wsl"
grep -Fx "$oci_copy" <<< "$oci_stage"
if grep -Fx "$oci_copy" <<< "$wsl_stage"; then exit 1; fi
grep -Fx "$wsl_copy" <<< "$wsl_stage"
if grep -Fx "$wsl_copy" <<< "$pre_wsl"; then exit 1; fi
grep -F 'install -y --no-install-recommends systemd systemd-sysv libpam-systemd dbus-user-session locales' <<< "$wsl_stage"
grep -F 'locale-gen en_US.UTF-8 C.UTF-8' <<< "$wsl_stage"
if grep -F 'locale-gen' <<< "$pre_wsl"; then exit 1; fi
grep -F 'chmod 0755 /usr/local/sbin/openhands-overlay' <<< "$wsl_stage"
grep -Fx 'MASTER_PASSWORD_FILE=/run/openhands-rbw-master' "$overlay"
grep -F 'rbw config set pinentry "$PINENTRY"' "$overlay"
grep -F 'systemctl enable --now nginx.service agent-canvas.service' "$overlay"
grep -F 'OH_ALLOW_CORS_ORIGINS_' "$overlay"
grep -F 'x-access-token' "$overlay"
grep -F '/proc/net/tcp6' "$overlay"
grep -F 'egress) egress' "$overlay"
grep -F '/home/agent/.git-credentials' "$overlay"
grep -F -- '--password-stdin) PASSWORD_STDIN=1' "$overlay"
grep -Fx 'INGRESS=http://127.0.0.1:8000' "$overlay"
grep -Fx 'CA_CERTIFICATE=/usr/local/share/ca-certificates/openhands-lan-ca.crt' "$overlay"
grep -Fx 'WORK_DIRECTORY=/run/openhands-overlay' "$overlay"
test -x "$applier"
grep -Fx 'APPLIER=/usr/local/lib/openhands/apply-profile.py' "$overlay"
grep -F -- '--secrets-dir "$WORK_DIRECTORY" --state-dir "$STATE_DIRECTORY"' "$overlay"
grep -F -- '--print secret-items' "$overlay"
grep -F 'X-Session-API-Key' "$applier"
grep -F 'PATCH", "/api/settings"' "$applier"
grep -F 'PUT", "/api/settings/secrets"' "$applier"
grep -F 'POST", "/api/skills/install"' "$applier"
grep -F 'PUT", "/api/automation/v1/git-sync/config"' "$applier"
grep -F 'POST", "/api/settings/mcp/%s"' "$applier"
grep -F 'PATCH", "/api/settings/mcp/%s"' "$applier"
grep -F 'X-Expose-Secrets' "$applier"
grep -F 'prune_apm_mcp' "$overlay"
grep -F 'placeholder = "${env:"' "$overlay"
if grep -q 'omni agents sync' "$overlay"; then echo 'the agents layer must be gone'; exit 1; fi
grep -F 'PATH="$AGENT_HOME/.local/bin:$PATH"' "$overlay"
grep -F 'runuser -u agent -- env HOME="$AGENT_HOME"' "$overlay"
grep -F 'var/lib/openhands/overlay' "$overlay"
grep -F 'GET", "/api/automation/v1/git-sync/status"' "$applier"
grep -F 'update-ca-certificates' "$overlay"
grep -F 'tar --numeric-owner --create --gzip --file - --directory /' "$overlay"
grep -F 'tar --numeric-owner --extract --gzip --file - --directory /' "$overlay"
for subcommand in 'ca) ca "$@" ;;' 'settings) settings "$@" ;;' 'state) state "$@" ;;'; do
  grep -F "$subcommand" "$overlay"
done
for profile in "$repo_root"/openhands/profiles/*.json; do
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$profile"
done
python3 - "$repo_root/openhands/profiles/towerr.json" <<'PY'
import json, re, sys
profile = json.load(open(sys.argv[1]))
assert profile["llm"]["base_url"] == "https://api.ai.h-cloud.lan/v1", profile["llm"]
assert profile["llm"]["model"] == "openai/gpt-5.6-sol", profile["llm"]
assert re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", profile["llm"]["api_key_item"]), profile["llm"]
assert profile["agent"]["kind"] == "acp", profile["agent"]
assert profile["agent"]["acp_server"] == "claude-code", profile["agent"]
assert profile["agent"]["acp_command"] == "/home/agent/.local/bin/claude-agent-acp", profile["agent"]
assert "skills" not in profile, "shared skills belong in common.json"
assert "mcp_servers" not in profile, "shared MCP servers belong in common.json"
assert profile["secrets"]["GH_TOKEN"]["item"] == "28226043-0a70-4d54-bfb8-592086a319c0", profile["secrets"]
assert set(profile["secrets"]) == {"GH_TOKEN"}, profile["secrets"]
assert profile["git_sync"]["path"] == "openhands/automations/towerr", profile["git_sync"]
assert profile["git_sync"]["token_item"] == "28226043-0a70-4d54-bfb8-592086a319c0", profile["git_sync"]
assert profile["git_sync"]["interval_seconds"] == 0, profile["git_sync"]
PY
python3 - "$repo_root/openhands/profiles/common.json" <<'PY'
import json, re, sys
profile = json.load(open(sys.argv[1]))
assert set(profile) == {"secrets", "skills", "mcp_servers"}, sorted(profile)
assert re.fullmatch(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
    profile["secrets"]["LITELLM_API"]["item"],
), profile["secrets"]
assert profile["skills"][0]["repo_path"] == "openhands/skills/agent-sandbox-deploy", profile["skills"]
litellm = profile["mcp_servers"]["litellm-tools"]
assert litellm["url"] == "https://api.ai.h-cloud.lan/mcp/", litellm
assert litellm["headers"]["x-litellm-api-key"] == {"secret": "LITELLM_API"}, litellm
assert profile["mcp_servers"]["openaiDeveloperDocs"]["url"] == "https://developers.openai.com/mcp", profile["mcp_servers"]
PY
python3 - "$repo_root/openhands/profiles/orc.json" <<'PY'
import json, sys
profile = json.load(open(sys.argv[1]))
assert profile == {"agent": {"kind": "openhands"}}, profile
PY
grep -Fx 'ARG OPENHANDS_WORKER_VERSION=dev' "$containerfile"
grep -F 'printf "openhands-worker %s\n" "$OPENHANDS_WORKER_VERSION" > /etc/openhands/release' "$containerfile"
grep -F 'RELEASE_MARKER=/etc/openhands/release' "$overlay"
grep -F 'VERSION="$version" docker buildx bake' "$repo_root/worker/build-wsl.sh"
test "$(grep -c 'OPENHANDS_WORKER_VERSION = "${VERSION}"' "$repo_root/worker/docker-bake.hcl")" = 3
grep -F '/etc/systemd/system/agent-canvas.service.d/10-overlay.conf' "$overlay"
# A parameter default binds on every call, so a type missing on Windows
# PowerShell 5.1 breaks callers that never needed the fallback.
if grep -rn '= \[Runtime.InteropServices.RuntimeInformation\]' "$repo_root/worker/windows"; then
  echo 'RuntimeInformation must not be a parameter default'
  exit 1
fi
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
  entrypoint=/src/worker/rootfs-oci/usr/local/sbin/container-entrypoint
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
