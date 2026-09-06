#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && until [ -e .git ]; do [ "$PWD" = / ] && exit 1; cd ..; done && pwd)
applier="$repo_root/openhands/worker/image/rootfs/usr/local/lib/openhands/apply-profile.py"
fixture_image=auto-code-env-wsl-overlay-fixture:ubuntu-26.04-python3

test -f "$applier"
test -x "$applier"
# The release reads the applier from the image tree; a symlink shortcut would drift from it.
if find "$repo_root/openhands" -type l -name '*.py' | grep -q .; then
  echo 'the applier must be published from the image tree, not through a symlink'; exit 1
fi
head -n 1 "$applier" | grep -Fxq '#!/usr/bin/env python3'
if grep -Eq '^import (subprocess|requests)|^import yaml' "$applier"; then
  echo 'the applier must stay on the python3 standard library without subprocesses'
  exit 1
fi

if ! docker image inspect "$fixture_image" >/dev/null 2>&1; then
  printf '%s\n' \
    'FROM ubuntu:26.04' \
    'RUN apt-get update && apt-get install -y --no-install-recommends openssl python3 && rm -rf /var/lib/apt/lists/*' |
    docker build --quiet --tag "$fixture_image" -
fi

script=$(cat <<'INNER'
set -euo pipefail
umask 022
mkdir -p /tmp/log /tmp/api /tmp/state /tmp/secrets
apply=/src/openhands/worker/image/rootfs/usr/local/lib/openhands/apply-profile.py

printf 'session-key-fixture\n' > /tmp/api-key
printf 'sk-llm-FIXTUREKEY111111111111' > /tmp/secrets/LLM_API_KEY
printf 'sk-llm-FIXTUREKEY111111111111\n' > /tmp/secrets/LITELLM_API
printf 'sk-ant-FIXTUREANTHROPIC22222' > /tmp/secrets/ANTHROPIC_API_KEY
printf 'ghs_FIXTUREGITSYNCTOKEN33333' > /tmp/secrets/GIT_SYNC_TOKEN

fresh_state() {
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
}
fresh_state

python3 /src/openhands/worker/tests/fake-agent-server.py --port 8000 --state /tmp/api/state.json \
  --log /tmp/log/api --bodies /tmp/log/api-bodies --api-key-file /tmp/api-key &
for _ in $(seq 1 100); do
  if python3 -c 'import socket,sys; sys.exit(socket.socket().connect_ex(("127.0.0.1", 8000)))'; then break; fi
  sleep 0.1
done
python3 -c 'import socket,sys; sys.exit(socket.socket().connect_ex(("127.0.0.1", 8000)))'

run() {
  "$apply" --api http://127.0.0.1:8000 --api-key-file /tmp/api-key \
    --secrets-dir /tmp/secrets --state-dir /tmp/state "$@"
}

cat > /tmp/common.json <<'EOF'
{
  "llm": {"model": "common/model", "base_url": "https://common.example/v1"},
  "secrets": {
    "ANTHROPIC_API_KEY": {"item": "77777777-7777-7777-7777-777777777777"},
    "LITELLM_API": {"item": "66666666-6666-6666-6666-666666666666", "prefix": "Bearer "}
  },
  "skills": [
    {"source": "https://github.com/lkshrk/auto-code-env.git", "ref": "common", "repo_path": "openhands/skills/agent-sandbox-deploy"},
    {"source": "https://github.com/lkshrk/auto-code-env.git", "ref": "main", "repo_path": "openhands/skills/common-only"}
  ],
  "mcp_servers": {
    "litellm-tools": {
      "url": "https://api.ai.h-cloud.lan/mcp/",
      "headers": {"x-litellm-api-key": {"secret": "LITELLM_API"}}
    },
    "openaiDeveloperDocs": {"url": "https://developers.openai.com/mcp"}
  },
  "git_sync": {
    "repo_url": "https://github.com/lkshrk/auto-code-env.git",
    "branch": "common",
    "path": "common/automations",
    "interval_seconds": 900
  }
}
EOF

cat > /tmp/host.json <<'EOF'
{
  "llm": {
    "model": "openai/gpt-5.6-sol",
    "base_url": "https://api.ai.h-cloud.lan/v1",
    "api_key_item": "66666666-6666-6666-6666-666666666666"
  },
  "agent": {"kind": "openhands"},
  "skills": [{
    "source": "https://github.com/lkshrk/auto-code-env.git",
    "ref": "main",
    "repo_path": "openhands/skills/agent-sandbox-deploy"
  }],
  "git_sync": {
    "repo_url": "https://github.com/lkshrk/auto-code-env.git",
    "branch": "main",
    "path": "openhands/automations/orc",
    "token_item": "88888888-8888-8888-8888-888888888888",
    "interval_seconds": 0
  }
}
EOF

items=$("$apply" --print secret-items /tmp/common.json /tmp/host.json)
test "$items" = 'ANTHROPIC_API_KEY 77777777-7777-7777-7777-777777777777
GIT_SYNC_TOKEN 88888888-8888-8888-8888-888888888888
LITELLM_API 66666666-6666-6666-6666-666666666666
LLM_API_KEY 66666666-6666-6666-6666-666666666666'

test ! -e /tmp/log/api
applied=$(run /tmp/common.json /tmp/host.json)
printf '%s\n' "$applied" | grep -Fq 'settings applied: llm'
printf '%s\n' "$applied" | grep -Fq 'secrets applied: ANTHROPIC_API_KEY, LITELLM_API'
printf '%s\n' "$applied" | grep -Fq 'mcp_servers applied: litellm-tools, openaiDeveloperDocs'
printf '%s\n' "$applied" | grep -Fq 'skills applied: agent-sandbox-deploy, common-only'
printf '%s\n' "$applied" | grep -Fq 'git_sync applied: branch, interval_seconds, path, repo_url, token'
if printf '%s\n' "$applied" | grep -Eq 'sk-llm|sk-ant|ghs_'; then echo 'secret leaked to stdout'; exit 1; fi
test "$(stat -c '%a' /tmp/state/git-sync-token.sha256)" = 600

python3 - <<'PY'
import json
state = json.load(open('/tmp/api/state.json'))
agent = state['agent_settings']
assert agent['llm']['model'] == 'openai/gpt-5.6-sol', agent
assert agent['llm']['base_url'] == 'https://api.ai.h-cloud.lan/v1', agent
assert agent['llm']['api_key'] == 'sk-llm-FIXTUREKEY111111111111', agent
servers = agent['mcp_config']
assert sorted(servers) == ['litellm-tools', 'openaiDeveloperDocs'], servers
assert servers['litellm-tools']['headers'] == {'x-litellm-api-key': 'Bearer sk-llm-FIXTUREKEY111111111111'}, servers
assert state['secrets'] == {
    'ANTHROPIC_API_KEY': 'sk-ant-FIXTUREANTHROPIC22222',
    'LITELLM_API': 'Bearer sk-llm-FIXTUREKEY111111111111',
}, state['secrets']
assert state['git_sync_token'] == 'ghs_FIXTUREGITSYNCTOKEN33333', state
assert state['git_sync']['branch'] == 'main', state
assert state['git_sync']['path'] == 'openhands/automations/orc', state
assert state['git_sync']['interval_seconds'] == 0, state
paths = sorted(entry['repo_path'] for entry in state['skills'])
assert paths == ['openhands/skills/agent-sandbox-deploy', 'openhands/skills/common-only'], state['skills']
refs = dict((entry['repo_path'], entry['ref']) for entry in state['skills'])
assert refs['openhands/skills/agent-sandbox-deploy'] == 'main', refs
PY

: > /tmp/log/api
repeated=$(run /tmp/common.json /tmp/host.json)
printf '%s\n' "$repeated" | grep -Fxq 'settings unchanged'
printf '%s\n' "$repeated" | grep -Fq 'secrets applied: none changed'
printf '%s\n' "$repeated" | grep -Fq 'mcp_servers applied: none changed'
printf '%s\n' "$repeated" | grep -Fq 'skills applied: none changed'
printf '%s\n' "$repeated" | grep -Fxq 'git_sync unchanged'
if grep -Eq '^(PATCH|PUT|POST) ' /tmp/log/api; then echo 'second run must not write'; exit 1; fi

: > /tmp/log/api
mv /tmp/secrets/ANTHROPIC_API_KEY /tmp/anthropic.kept
if run /tmp/common.json /tmp/host.json > /tmp/missing.out 2> /tmp/missing.err; then
  echo 'a missing secret file must fail'
  exit 1
fi
grep -Fq 'missing material for secret ANTHROPIC_API_KEY at /tmp/secrets/ANTHROPIC_API_KEY' /tmp/missing.err
test ! -s /tmp/log/api
mv /tmp/anthropic.kept /tmp/secrets/ANTHROPIC_API_KEY

if run /tmp/common.json /tmp/host.json --secrets-dir /tmp/nowhere >/dev/null 2>&1; then
  echo 'an unreadable secrets directory must fail'
  exit 1
fi

printf 'wrong-key\n' > /tmp/bad-key
if "$apply" --api http://127.0.0.1:8000 --api-key-file /tmp/bad-key --secrets-dir /tmp/secrets \
  --state-dir /tmp/state /tmp/common.json /tmp/host.json >/dev/null 2>/tmp/forbidden.err; then
  echo 'a wrong session API key must fail'
  exit 1
fi
grep -Fq 'HTTP 403' /tmp/forbidden.err

if "$apply" --secrets-dir /tmp/secrets /tmp/common.json >/dev/null 2>&1; then
  echo 'apply must require --api'
  exit 1
fi
printf '{"nope": {}}' > /tmp/bad-section.json
if "$apply" --print secret-items /tmp/bad-section.json >/dev/null 2>&1; then
  echo 'unknown section must be rejected'
  exit 1
fi

rm -rf /tmp/state
mkdir -p /tmp/state
fresh_state
: > /tmp/log/api
orc=$(run /src/openhands/profiles/common.json /src/openhands/profiles/orc.json)
printf '%s\n' "$orc" | grep -Fq 'secrets applied: LITELLM_API'
printf '%s\n' "$orc" | grep -Fq 'mcp_servers applied: litellm-tools, openaiDeveloperDocs'
printf '%s\n' "$orc" | grep -Fq 'skills applied: agent-sandbox-deploy'
if printf '%s\n' "$orc" | grep -Fq 'git_sync'; then echo 'the orc profile must not configure git sync'; exit 1; fi
test ! -e /tmp/state/git-sync-token.sha256
python3 - <<'PY'
import json
state = json.load(open('/tmp/api/state.json'))
assert state['agent_settings']['agent_kind'] == 'openhands', state['agent_settings']
assert state['agent_settings']['llm']['model'] == 'stale/model', state['agent_settings']
assert list(state['secrets']) == ['LITELLM_API'], state['secrets']
PY

echo 'applier tests passed'
INNER
)

docker run --rm \
  --volume "$repo_root:/src:ro" \
  "$fixture_image" bash -c "$script"
