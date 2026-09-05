#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
overlay="$repo_root/worker/rootfs/usr/local/sbin/openhands-overlay"
fixture_image=auto-code-env-wsl-overlay-fixture:ubuntu-26.04-python3

test -f "$overlay"
grep -Fq 'LoadCredential=rbw_master:' "$overlay"
grep -Fq 'rbw purge' "$overlay"
grep -Fq 'systemd-ask-password --echo=no' "$overlay"
grep -Fq -- '--password-stdin' "$overlay"
if grep -Eq 'echo .*\$OVERLAY_|printf .*tls\.key' "$overlay"; then exit 1; fi

if ! docker image inspect "$fixture_image" >/dev/null 2>&1; then
  printf '%s\n' \
    'FROM ubuntu:26.04' \
    'RUN apt-get update && apt-get install -y --no-install-recommends openssl python3 && rm -rf /var/lib/apt/lists/*' |
    docker build --quiet --tag "$fixture_image" -
fi

script=$(cat <<'INNER'
set -euo pipefail
umask 022
shim=/tmp/shim
mkdir -p "$shim" /tmp/log /usr/local/libexec /etc/nginx && chmod 1777 /tmp/log && touch /tmp/log/omni /tmp/log/git && chmod 666 /tmp/log/omni /tmp/log/git
install -m 0755 /src/worker/rootfs/usr/local/sbin/openhands-overlay /usr/local/sbin/openhands-overlay
install -D -m 0755 /src/worker/rootfs/usr/local/lib/openhands/apply-profile.py /usr/local/lib/openhands/apply-profile.py
userdel -r ubuntu 2>/dev/null || true; useradd -m -u 1000 -s /bin/bash agent
mkdir -p /etc/openhands && printf 'openhands-worker 9.9.9-test\n' > /etc/openhands/release
printf '#!/bin/sh\nexit 0\n' > /usr/local/libexec/openhands-rbw-pinentry
chmod 0755 /usr/local/libexec/openhands-rbw-pinentry

openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=towerr.example -days 1 \
  -keyout /tmp/fixture.key -out /tmp/fixture.crt >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=other.example -days 1 \
  -keyout /tmp/other.key -out /tmp/other.crt >/dev/null 2>&1
printf '%064d' 7 > /tmp/fixture.api
printf 'hunter2' > /tmp/fixture.master

cat > "$shim/rbw" <<'EOF'
#!/bin/sh
echo "rbw $*" >> /tmp/log/rbw
case "$1" in
  config) mkdir -p /root/.config/rbw; touch /root/.config/rbw/config.json; exit 0 ;;
  login|sync|lock|stop-agent|purge)
    test -n "${CREDENTIALS_DIRECTORY:-}" || { echo 'no credentials directory' >&2; exit 1; }
    test "$(cat "$CREDENTIALS_DIRECTORY/rbw_master")" = "$(cat /tmp/fixture.master)" || { echo 'wrong master' >&2; exit 1; }
    exit 0 ;;
  get)
    case "$*" in
      "get --field notes 11111111-1111-1111-1111-111111111111") cat /tmp/fixture.crt ;;
      "get --field notes 22222222-2222-2222-2222-222222222222") cat /tmp/fixture.key ;;
      "get --field notes 33333333-3333-3333-3333-333333333333") cat /tmp/other.key ;;
      "get 44444444-4444-4444-4444-444444444444") cat /tmp/fixture.api; echo ;;
      "get 55555555-5555-5555-5555-555555555555") printf 'ghp_FIXTURETOKEN0000000000000000000000\n' ;;
      "get 66666666-6666-6666-6666-666666666666") printf 'sk-llm-FIXTUREKEY111111111111\n' ;;
      "get 77777777-7777-7777-7777-777777777777") printf 'sk-ant-FIXTUREANTHROPIC22222\n' ;;
      "get 88888888-8888-8888-8888-888888888888") printf 'ghs_FIXTUREGITSYNCTOKEN33333\n' ;;
      "get --field notes 99999999-9999-9999-9999-999999999999") cat /tmp/fixture.crt ;;
      "get --field notes aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa") printf 'not a certificate\n' ;;
      *) echo "unknown item $*" >&2; exit 1 ;;
    esac ;;
  *) echo "unexpected rbw $*" >&2; exit 1 ;;
esac
EOF

cat > "$shim/systemd-run" <<'EOF'
#!/bin/sh
echo "systemd-run $*" >> /tmp/log/systemd-run
creds=$(mktemp -d)
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet|--pipe|--wait|--collect) shift ;;
    -E) export "$2"; shift 2 ;;
    -p)
      case "$2" in
        LoadCredential=*) spec=${2#LoadCredential=}; cp "${spec#*:}" "$creds/${spec%%:*}" ;;
        *) echo "unexpected property $2" >&2; exit 1 ;;
      esac
      shift 2 ;;
    *) break ;;
  esac
done
CREDENTIALS_DIRECTORY=$creds exec "$@"
EOF

cat > "$shim/systemd-ask-password" <<'EOF'
#!/bin/sh
cat /tmp/fixture.master
EOF

cat > "$shim/nginx" <<'EOF'
#!/bin/sh
test "$1" = -t || exit 1
test -r /etc/nginx/tls/tls.crt && test -r /etc/nginx/tls/tls.key
EOF

cat > "$shim/git" <<'EOF'
#!/bin/sh
echo "git $*" >> /tmp/log/git
EOF

cat > "$shim/omni" <<'EOF'
#!/bin/sh
echo "omni $* user=$(id -un) dir=$(pwd) home=$HOME path=$PATH" >> /tmp/log/omni
EOF

cat > "$shim/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> /tmp/log/systemctl
case "$1" in
  enable|daemon-reload|try-restart) exit 0 ;;
  is-active) printf 'active\nactive\n' ;;
  *) exit 1 ;;
esac
EOF
cat > "$shim/update-ca-certificates" <<'EOF'
#!/bin/sh
echo "update-ca-certificates $*" >> /tmp/log/update-ca-certificates
test -r /usr/local/share/ca-certificates/openhands-lan-ca.crt
EOF

chmod 0755 "$shim"/*
export PATH="$shim:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"

run() { openhands-overlay "$@"; }

if run verify >/dev/null 2>&1; then echo 'verify must fail before secrets exist'; exit 1; fi
if run enable >/dev/null 2>&1; then echo 'enable must fail before secrets exist'; exit 1; fi
if run secrets --vault-url http://vault.example --email a@b --crt-id 11111111-1111-1111-1111-111111111111 --key-id 22222222-2222-2222-2222-222222222222 --api-id 44444444-4444-4444-4444-444444444444 >/dev/null 2>&1; then echo 'plain HTTP vault must be rejected'; exit 1; fi
if run secrets --vault-url https://vault.example --email a@b --crt-id nope --key-id 22222222-2222-2222-2222-222222222222 --api-id 44444444-4444-4444-4444-444444444444 >/dev/null 2>&1; then echo 'non-UUID item id must be rejected'; exit 1; fi
test ! -e /tmp/log/systemd-run

output=$(run secrets --vault-url https://vault.example --email a@b \
  --crt-id 11111111-1111-1111-1111-111111111111 \
  --key-id 22222222-2222-2222-2222-222222222222 \
  --api-id 44444444-4444-4444-4444-444444444444)
printf '%s\n' "$output" | grep -Fq 'overlay verified'
printf '%s\n' "$output" | grep -Fq 'CN = towerr.example' || printf '%s\n' "$output" | grep -Fq 'CN=towerr.example'
if printf '%s\n' "$output" | grep -Eq 'PRIVATE KEY|0000000'; then echo 'secret material leaked to stdout'; exit 1; fi

test "$(stat -c '%U:%G %a' /etc/nginx/tls/tls.crt)" = 'root:root 644'
test "$(stat -c '%U:%G %a' /etc/nginx/tls/tls.key)" = 'root:root 600'
test "$(stat -c '%U:%G %a' /etc/credstore/local_backend_api_key)" = 'root:root 600'
test "$(stat -c '%U:%G %a' /etc/credstore)" = 'root:root 700'
cmp -s /tmp/fixture.crt /etc/nginx/tls/tls.crt
cmp -s /tmp/fixture.key /etc/nginx/tls/tls.key
test "$(cat /etc/credstore/local_backend_api_key)" = "$(cat /tmp/fixture.api)"
test ! -e /run/openhands-rbw-master
grep -Fq 'LoadCredential=rbw_master:/run/openhands-rbw-master' /tmp/log/systemd-run
test "$(grep -c '^rbw login$' /tmp/log/rbw)" = 1
test "$(tail -n 1 /tmp/log/rbw)" = 'rbw purge'
grep -n '^rbw ' /tmp/log/rbw | grep -F 'rbw config set pinentry /usr/local/libexec/openhands-rbw-pinentry' >/dev/null
login_line=$(grep -n '^rbw login$' /tmp/log/rbw | cut -d: -f1)
first_get=$(grep -n '^rbw get ' /tmp/log/rbw | head -n 1 | cut -d: -f1)
test "$login_line" -lt "$first_get"

run enable | grep -Fq 'active'
grep -Fq 'systemctl enable --now nginx.service agent-canvas.service openhands-run-prune.timer' /tmp/log/systemctl

if run origin http://orc.example >/dev/null 2>&1; then echo 'plain HTTP origin must be rejected'; exit 1; fi
if run origin 'https://orc.example/path' >/dev/null 2>&1; then echo 'origin with a path must be rejected'; exit 1; fi
test ! -e /etc/systemd/system/agent-canvas.service.d/10-overlay.conf
run origin https://orc.example | grep -Fq 'origin https://orc.example'
test "$(stat -c '%U:%G %a' /etc/systemd/system/agent-canvas.service.d/10-overlay.conf)" = 'root:root 644'
grep -Fxq 'Environment=OH_ALLOW_CORS_ORIGINS_0=https://orc.example' /etc/systemd/system/agent-canvas.service.d/10-overlay.conf
grep -Fq 'systemctl daemon-reload' /tmp/log/systemctl
grep -Fq 'systemctl try-restart agent-canvas.service' /tmp/log/systemctl
run origin https://orc.example https://second.example >/dev/null
grep -Fxq 'Environment=OH_ALLOW_CORS_ORIGINS_1=https://second.example' /etc/systemd/system/agent-canvas.service.d/10-overlay.conf
test "$(grep -c '^Environment=OH_ALLOW_CORS_ORIGINS_' /etc/systemd/system/agent-canvas.service.d/10-overlay.conf)" = 2

if run github >/dev/null 2>&1; then echo 'github requires --pat-id'; exit 1; fi
if run github --pat-id nope >/dev/null 2>&1; then echo 'github must reject a non-UUID id'; exit 1; fi
gh_out=$(run github --pat-id 55555555-5555-5555-5555-555555555555)
printf '%s\n' "$gh_out" | grep -Fq 'github credential installed for agent'
if printf '%s\n' "$gh_out" | grep -Fq 'ghp_'; then echo 'token leaked to stdout'; exit 1; fi
test "$(stat -c '%U:%G %a' /home/agent/.git-credentials)" = 'agent:agent 600'
grep -Fxq 'https://x-access-token:ghp_FIXTURETOKEN0000000000000000000000@github.com' /home/agent/.git-credentials
grep -Fq 'git config --global credential.helper store' /tmp/log/git
test "$(grep -c '^rbw login$' /tmp/log/rbw)" = 2
test "$(tail -n 1 /tmp/log/rbw)" = 'rbw purge'
run status | grep -Fq 'release openhands-worker 9.9.9-test'

run secrets --vault-url https://vault.example --email a@b \
  --crt-id 11111111-1111-1111-1111-111111111111 \
  --key-id 33333333-3333-3333-3333-333333333333 \
  --api-id 44444444-4444-4444-4444-444444444444 >/dev/null 2>/tmp/mismatch || true
grep -Fq 'private key does not match certificate' /tmp/mismatch
if run enable >/dev/null 2>&1; then echo 'enable must refuse a mismatched key'; exit 1; fi
cat > "$shim/systemd-ask-password" <<'EOF'
#!/bin/sh
echo 'systemd-ask-password must not run with --password-stdin' >&2
exit 1
EOF
chmod 0755 "$shim/systemd-ask-password"

if printf '' | run github --pat-id 55555555-5555-5555-5555-555555555555 --password-stdin >/dev/null 2>&1; then echo 'empty stdin password must be rejected'; exit 1; fi

printf 'hunter2' | run secrets --password-stdin \
  --crt-id 11111111-1111-1111-1111-111111111111 \
  --key-id 22222222-2222-2222-2222-222222222222 \
  --api-id 44444444-4444-4444-4444-444444444444 | grep -Fq 'overlay verified'
cmp -s /tmp/fixture.key /etc/nginx/tls/tls.key
rm -f /home/agent/.git-credentials
printf 'hunter2' | run github --pat-id 55555555-5555-5555-5555-555555555555 --password-stdin | grep -Fq 'github credential installed for agent'
grep -Fxq 'https://x-access-token:ghp_FIXTURETOKEN0000000000000000000000@github.com' /home/agent/.git-credentials

mkdir -p /tmp/api
cat > /tmp/api/state.json <<'EOF'
{
  "agent_settings": {
    "agent_kind": "openhands",
    "llm": {"model": "stale/model", "base_url": "https://stale.example/v1", "api_key": "stale-key"},
    "mcp_config": {}
  },
  "secrets": {},
  "skills": [],
  "git_sync": {"enabled": false, "repo_url": "", "branch": "common", "path": "common/automations", "interval_seconds": 900}
}
EOF

python3 /src/worker/tests/fake-agent-server.py --port 8000 --state /tmp/api/state.json \
  --log /tmp/log/api --bodies /tmp/log/api-bodies --api-key-file /etc/credstore/local_backend_api_key &
for _ in $(seq 1 100); do
  if python3 -c 'import socket,sys; sys.exit(socket.socket().connect_ex(("127.0.0.1", 8000)))'; then break; fi
  sleep 0.1
done
python3 -c 'import socket,sys; sys.exit(socket.socket().connect_ex(("127.0.0.1", 8000)))'

cat > /tmp/common.json <<'EOF'
{
  "llm": {
    "model": "common/model",
    "base_url": "https://common.example/v1"
  },
  "secrets": {
    "ANTHROPIC_API_KEY": {"item": "77777777-7777-7777-7777-777777777777"},
    "LITELLM_API": {"item": "66666666-6666-6666-6666-666666666666"}
  },
  "skills": [
    {
      "source": "https://github.com/lkshrk/auto-code-env.git",
      "ref": "common",
      "repo_path": "openhands/skills/agent-sandbox-deploy"
    },
    {
      "source": "https://github.com/lkshrk/auto-code-env.git",
      "ref": "main",
      "repo_path": "openhands/skills/common-only"
    }
  ],
  "mcp_servers": {
    "litellm-tools": {
      "url": "https://api.ai.h-cloud.lan/mcp/",
      "headers": {"x-litellm-api-key": {"secret": "LITELLM_API"}}
    },
    "openaiDeveloperDocs": {"url": "https://developers.openai.com/mcp"},
    "local-notes": {"command": "notes-mcp", "args": ["--stdio"]}
  },
  "agents": {
    "repo": "lkshrk/dotfiles",
    "ref": "main",
    "path": "apm/ai-plugins",
    "targets": ["claude", "codex"]
  },
  "git_sync": {
    "repo_url": "https://github.com/lkshrk/auto-code-env.git",
    "branch": "common",
    "path": "common/automations",
    "interval_seconds": 900
  }
}
EOF

cat > /tmp/profile.json <<'EOF'
{
  "llm": {
    "model": "openai/gpt-5.6-sol",
    "base_url": "https://api.ai.h-cloud.lan/v1",
    "api_key_item": "66666666-6666-6666-6666-666666666666"
  },
  "agent": {
    "kind": "acp",
    "acp_server": "claude-code",
    "acp_command": "/home/agent/.local/bin/claude-agent-acp",
    "acp_model": null
  },
  "skills": [{
    "source": "https://github.com/lkshrk/auto-code-env.git",
    "ref": "main",
    "repo_path": "openhands/skills/agent-sandbox-deploy"
  }],
  "git_sync": {
    "repo_url": "https://github.com/lkshrk/auto-code-env.git",
    "branch": "main",
    "path": "openhands/automations/towerr",
    "token_item": "88888888-8888-8888-8888-888888888888",
    "interval_seconds": 0
  }
}
EOF

if printf 'hunter2' | run settings --file /src/openhands/profiles/towerr.json --password-stdin >/dev/null 2>&1; then echo 'placeholder item id must be rejected'; exit 1; fi
printf '{"nope": {}}' > /tmp/bad-section.json
if printf 'hunter2' | run settings --file /tmp/bad-section.json --password-stdin >/dev/null 2>&1; then echo 'unknown section must be rejected'; exit 1; fi
printf '{"llm": {"model": "m", "flavour": "x"}}' > /tmp/bad-key.json
if printf 'hunter2' | run settings --file /tmp/bad-key.json --password-stdin >/dev/null 2>&1; then echo 'unknown key must be rejected'; exit 1; fi
printf '{"agent": {"kind": "openhands", "acp_server": "codex"}}' > /tmp/bad-kind.json
if printf 'hunter2' | run settings --file /tmp/bad-kind.json --password-stdin >/dev/null 2>&1; then echo 'acp keys require agent.kind acp'; exit 1; fi
printf '{"mcp_servers": {"x": {"url": "https://x.example", "headers": {"h": {"secret": "MISSING"}}}}}' > /tmp/bad-mcp-secret.json
if printf 'hunter2' | run settings --file /tmp/bad-mcp-secret.json --password-stdin >/dev/null 2>&1; then echo 'an undeclared MCP header secret must be rejected'; exit 1; fi
printf '{"mcp_servers": {"x": {}}}' > /tmp/bad-mcp-empty.json
if printf 'hunter2' | run settings --file /tmp/bad-mcp-empty.json --password-stdin >/dev/null 2>&1; then echo 'an MCP server without url or command must be rejected'; exit 1; fi
printf '{"mcp_servers": {"x": {"url": "https://x.example", "command": "y"}}}' > /tmp/bad-mcp-mixed.json
if printf 'hunter2' | run settings --file /tmp/bad-mcp-mixed.json --password-stdin >/dev/null 2>&1; then echo 'an MCP server mixing url and command must be rejected'; exit 1; fi
printf '{"agents": {"repo": "lkshrk/dotfiles", "path": "/etc", "targets": ["claude"]}}' > /tmp/bad-agents-path.json
if printf 'hunter2' | run settings --file /tmp/bad-agents-path.json --password-stdin >/dev/null 2>&1; then echo 'an absolute agents.path must be rejected'; exit 1; fi
printf '{"agents": {"repo": "git@github.com:lkshrk/dotfiles.git", "targets": ["claude"]}}' > /tmp/bad-agents-repo.json
if printf 'hunter2' | run settings --file /tmp/bad-agents-repo.json --password-stdin >/dev/null 2>&1; then echo 'an SSH agents.repo must be rejected'; exit 1; fi
printf '{"agents": {"repo": "lkshrk/dotfiles", "targets": []}}' > /tmp/bad-agents-targets.json
if printf 'hunter2' | run settings --file /tmp/bad-agents-targets.json --password-stdin >/dev/null 2>&1; then echo 'an empty agents.targets must be rejected'; exit 1; fi
printf '{"agents": {"repo": "lkshrk/dotfiles", "targets": ["Claude Code"]}}' > /tmp/bad-agents-target.json
if printf 'hunter2' | run settings --file /tmp/bad-agents-target.json --password-stdin >/dev/null 2>&1; then echo 'a non-harness agents.targets entry must be rejected'; exit 1; fi
if run settings --password-stdin >/dev/null 2>&1; then echo 'settings requires at least one --file'; exit 1; fi
test ! -e /tmp/log/api

applied=$(printf 'hunter2' | run settings --file /tmp/common.json --file /tmp/profile.json --password-stdin)
printf '%s\n' "$applied" | grep -Fq 'settings applied: acp_command, acp_server, agent_kind, llm'
printf '%s\n' "$applied" | grep -Fq 'secrets applied: ANTHROPIC_API_KEY, LITELLM_API'
printf '%s\n' "$applied" | grep -Fq 'mcp_servers applied: litellm-tools, local-notes, openaiDeveloperDocs'
printf '%s\n' "$applied" | grep -Fq 'skills applied: agent-sandbox-deploy, common-only'
printf '%s\n' "$applied" | grep -Fq 'git_sync applied: branch, interval_seconds, path, repo_url, token'
printf '%s\n' "$applied" | grep -Fxq 'agents applied: synced'
printf '%s\n' "$applied" | grep -Fxq 'agents targets: 2'
if printf '%s\n' "$applied" | grep -Eq 'sk-llm|sk-ant|ghs_'; then echo 'secret leaked to stdout'; exit 1; fi
test ! -e /run/openhands-overlay
test ! -e /run/openhands-rbw-master
grep -Fxq 'PATCH /api/settings' /tmp/log/api
grep -Fxq 'PUT /api/settings/secrets' /tmp/log/api
grep -Fxq 'POST /api/settings/mcp/litellm-tools' /tmp/log/api
grep -Fxq 'POST /api/settings/mcp/openaiDeveloperDocs' /tmp/log/api
grep -Fxq 'POST /api/settings/mcp/local-notes' /tmp/log/api
grep -Fxq 'POST /api/skills/install' /tmp/log/api
grep -Fxq 'PUT /api/automation/v1/git-sync/config' /tmp/log/api
test "$(grep -c '^GET /api/settings$' /tmp/log/api)" = 1
test "$(stat -c '%U:%G %a' /var/lib/openhands/overlay/git-sync-token.sha256)" = 'root:root 600'
grep -Fq 'omni agents sync user=agent dir=/home/agent home=/home/agent' /tmp/log/omni
grep -Fq 'path=/home/agent/.local/bin:' /tmp/log/omni
test "$(grep -c '^omni ' /tmp/log/omni)" = 1
if grep -Ev '^omni agents sync ' /tmp/log/omni; then echo 'only omni agents sync may run'; exit 1; fi
test "$(stat -c '%U:%G %a' /home/agent/.config/omni/apm.yml)" = 'agent:agent 644'
test "$(stat -c '%U:%G %a' /home/agent/.config/omni)" = 'agent:agent 755'
cat > /tmp/expected-apm.yml <<'EOF'
name: openhands-worker
version: 1.0.0
dependencies:
  apm:
  - git: lkshrk/dotfiles
    path: apm/ai-plugins
    ref: main
targets:
- claude
- codex
EOF
cmp /tmp/expected-apm.yml /home/agent/.config/omni/apm.yml
python3 - <<'PY'
import json
state = json.load(open('/tmp/api/state.json'))
agent = state['agent_settings']
assert agent['agent_kind'] == 'acp', agent
assert agent['acp_server'] == 'claude-code', agent
assert agent['acp_command'] == ['/home/agent/.local/bin/claude-agent-acp'], agent
assert agent['llm']['model'] == 'openai/gpt-5.6-sol', agent
assert agent['llm']['base_url'] == 'https://api.ai.h-cloud.lan/v1', agent
assert agent['llm']['api_key'] == 'sk-llm-FIXTUREKEY111111111111', agent
servers = agent['mcp_config']
assert sorted(servers) == ['litellm-tools', 'local-notes', 'openaiDeveloperDocs'], servers
assert servers['litellm-tools'] == {
    'transport': 'http',
    'url': 'https://api.ai.h-cloud.lan/mcp/',
    'headers': {'x-litellm-api-key': 'sk-llm-FIXTUREKEY111111111111'},
    'enabled': True,
}, servers['litellm-tools']
assert servers['openaiDeveloperDocs'] == {
    'transport': 'http',
    'url': 'https://developers.openai.com/mcp',
    'enabled': True,
}, servers['openaiDeveloperDocs']
assert servers['local-notes'] == {
    'transport': 'stdio',
    'command': 'notes-mcp',
    'args': ['--stdio'],
    'enabled': True,
}, servers['local-notes']
assert state['secrets']['ANTHROPIC_API_KEY'] == 'sk-ant-FIXTUREANTHROPIC22222', state
assert state['secrets']['LITELLM_API'] == 'sk-llm-FIXTUREKEY111111111111', state
assert state['git_sync_token'] == 'ghs_FIXTUREGITSYNCTOKEN33333', state
assert state['git_sync']['path'] == 'openhands/automations/towerr', state
assert state['git_sync']['branch'] == 'main', state
assert state['git_sync']['interval_seconds'] == 0, state
paths = sorted(entry['repo_path'] for entry in state['skills'])
assert paths == ['openhands/skills/agent-sandbox-deploy', 'openhands/skills/common-only'], state['skills']
refs = dict((entry['repo_path'], entry['ref']) for entry in state['skills'])
assert refs['openhands/skills/agent-sandbox-deploy'] == 'main', refs
assert refs['openhands/skills/common-only'] == 'main', refs
PY

: > /tmp/log/api
: > /tmp/log/omni
repeated=$(printf 'hunter2' | run settings --file /tmp/common.json --file /tmp/profile.json --password-stdin)
printf '%s\n' "$repeated" | grep -Fq 'settings unchanged'
printf '%s\n' "$repeated" | grep -Fq 'secrets applied: none changed'
printf '%s\n' "$repeated" | grep -Fq 'mcp_servers applied: none changed'
printf '%s\n' "$repeated" | grep -Fq 'skills applied: none changed'
printf '%s\n' "$repeated" | grep -Fq 'git_sync unchanged'
if grep -Eq '^(PATCH|PUT|POST) ' /tmp/log/api; then echo 'second run must not write'; exit 1; fi
grep -Fxq 'GET /api/settings' /tmp/log/api
printf '%s\n' "$repeated" | grep -Fxq 'agents unchanged'
printf '%s\n' "$repeated" | grep -Fxq 'agents targets: 2'
grep -Fq 'omni agents sync user=agent dir=/home/agent' /tmp/log/omni
cmp /tmp/expected-apm.yml /home/agent/.config/omni/apm.yml

: > /tmp/log/omni
printf 'stale\n' > /home/agent/.config/omni/apm.yml
drifted=$(printf 'hunter2' | run settings --file /tmp/common.json --file /tmp/profile.json --password-stdin)
printf '%s\n' "$drifted" | grep -Fxq 'agents applied: synced'
cmp /tmp/expected-apm.yml /home/agent/.config/omni/apm.yml
test "$(stat -c '%U:%G %a' /home/agent/.config/omni/apm.yml)" = 'agent:agent 644'
grep -Fq 'omni agents sync' /tmp/log/omni

python3 - <<'PY'
import json
state = json.load(open('/tmp/api/state.json'))
state['agent_settings']['mcp_config']['litellm-tools']['headers']['x-litellm-api-key'] = 'stale'
json.dump(state, open('/tmp/api/state.json', 'w'))
PY
: > /tmp/log/api
rotated=$(printf 'hunter2' | run settings --file /tmp/common.json --file /tmp/profile.json --password-stdin)
printf '%s\n' "$rotated" | grep -Fq 'mcp_servers applied: litellm-tools'
grep -Fxq 'PATCH /api/settings/mcp/litellm-tools' /tmp/log/api
if grep -Fq 'POST /api/settings/mcp/' /tmp/log/api; then echo 'an existing MCP server must be patched, not recreated'; exit 1; fi
grep -Fq '"headers": {"x-litellm-api-key": "sk-llm-FIXTUREKEY111111111111"}' /tmp/log/api-bodies

ca_output=$(printf 'hunter2' | run ca --item 99999999-9999-9999-9999-999999999999 --password-stdin)
printf '%s\n' "$ca_output" | grep -Fq 'ca installed /usr/local/share/ca-certificates/openhands-lan-ca.crt'
test "$(stat -c '%U:%G %a' /usr/local/share/ca-certificates/openhands-lan-ca.crt)" = 'root:root 644'
cmp -s /tmp/fixture.crt /usr/local/share/ca-certificates/openhands-lan-ca.crt
grep -Fq 'update-ca-certificates' /tmp/log/update-ca-certificates
if printf 'hunter2' | run ca --item aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa --password-stdin >/dev/null 2>&1; then echo 'non-PEM CA item must be rejected'; exit 1; fi
cmp -s /tmp/fixture.crt /usr/local/share/ca-certificates/openhands-lan-ca.crt

install -d -o agent -g agent -m 0700 /home/agent/.openhands /home/agent/.claude /home/agent/.codex
printf 'canvas-state\n' > /home/agent/.openhands/settings.json
printf 'claude-state\n' > /home/agent/.claude/.credentials.json
printf 'codex-state\n' > /home/agent/.codex/auth.json
printf '[user]\n' > /home/agent/.gitconfig
chown -R agent:agent /home/agent/.openhands /home/agent/.claude /home/agent/.codex /home/agent/.gitconfig
token_digest=$(cat /var/lib/openhands/overlay/git-sync-token.sha256)
run state export > /tmp/state.tar.gz 2>/tmp/state.err
grep -Fq 'export /home/agent/.openhands' /tmp/state.err
grep -Fq 'export /var/lib/openhands/overlay' /tmp/state.err
tar -tzf /tmp/state.tar.gz > /tmp/state.list
grep -Fxq 'home/agent/.git-credentials' /tmp/state.list
grep -Fxq 'home/agent/.gitconfig' /tmp/state.list
grep -Fxq 'var/lib/openhands/overlay/git-sync-token.sha256' /tmp/state.list
rm -rf /home/agent/.openhands /home/agent/.claude /home/agent/.codex /home/agent/.git-credentials /home/agent/.gitconfig /var/lib/openhands/overlay
run state import < /tmp/state.tar.gz | grep -Fq 'state imported'
test "$(cat /home/agent/.openhands/settings.json)" = 'canvas-state'
test "$(cat /home/agent/.codex/auth.json)" = 'codex-state'
test "$(stat -c '%U:%G %a' /home/agent/.openhands)" = 'agent:agent 700'
test "$(stat -c '%U:%G %a' /home/agent/.claude)" = 'agent:agent 700'
test "$(stat -c '%U:%G %a' /home/agent/.codex)" = 'agent:agent 700'
test "$(stat -c '%U:%G %a' /home/agent/.git-credentials)" = 'agent:agent 600'
test "$(stat -c '%U:%G %a' /var/lib/openhands/overlay)" = 'root:root 700'
test "$(stat -c '%U:%G %a' /var/lib/openhands/overlay/git-sync-token.sha256)" = 'root:root 600'
test "$(cat /var/lib/openhands/overlay/git-sync-token.sha256)" = "$token_digest"
grep -Fxq 'https://x-access-token:ghp_FIXTURETOKEN0000000000000000000000@github.com' /home/agent/.git-credentials
rm -rf /home/agent/.openhands /home/agent/.claude /home/agent/.codex
mv /home/agent/.git-credentials /tmp/kept.credentials
mv /home/agent/.gitconfig /tmp/kept.gitconfig
mv /var/lib/openhands/overlay /tmp/kept.overlay
if run state export >/dev/null 2>&1; then echo 'export must fail without state'; exit 1; fi
mv /tmp/kept.credentials /home/agent/.git-credentials
mv /tmp/kept.gitconfig /home/agent/.gitconfig
mv /tmp/kept.overlay /var/lib/openhands/overlay

cat > /tmp/tcp-fixture <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F40 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1 0000000000000000 100 0 0 10 0
   1: C314A8C0:D431 08080808:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 1 0000000000000000 20 4 30 10 -1
   2: C314A8C0:D432 08080808:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 1 0000000000000000 20 4 30 10 -1
   3: C314A8C0:D433 0100007F:1F40 01 00000000:00000000 00:00000000 00000000  1000        0 1 0000000000000000 20 4 30 10 -1
   4: C314A8C0:D434 0200A8C0:0035 01 00000000:00000000 00:00000000 00000000  1000        0 1 0000000000000000 20 4 30 10 -1
   5: 0000000000000000FFFF0000C314A8C0:D435 0000000000000000FFFF00008C52768D:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 1 0000000000000000 20 4 30 10 -1
EOF
egress_out=$(run egress --from /tmp/tcp-fixture)
printf '%s\n' "$egress_out" | grep -Eq '^internet 8\.8\.8\.8 443 2 ' || { echo "expected 8.8.8.8:443 sampled twice"; printf '%s\n' "$egress_out"; exit 1; }
printf '%s\n' "$egress_out" | grep -Eq '^lan 192\.168\.0\.2 53 1 '
printf '%s\n' "$egress_out" | grep -Eq '^internet 141\.118\.82\.140 443 1 '
if printf '%s\n' "$egress_out" | grep -q '127\.0\.0\.1'; then echo 'loopback must be excluded'; exit 1; fi
test "$(printf '%s\n' "$egress_out" | grep -c '^\(lan\|internet\) ')" = 3
if run egress --minutes x >/dev/null 2>&1; then echo 'non-integer minutes must be rejected'; exit 1; fi
echo 'overlay tests passed'
INNER
)

docker run --rm \
  --volume "$repo_root:/src:ro" \
  "$fixture_image" bash -c "$script"
