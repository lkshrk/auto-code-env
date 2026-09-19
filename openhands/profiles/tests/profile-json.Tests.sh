#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && until [ -e .git ]; do [ "$PWD" = / ] && exit 1; cd ..; done && pwd)

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
assert set(profile) == {"agent", "secrets", "skills", "mcp_servers", "retired_secrets"}, sorted(profile)
assert set(profile["agent"]) == {"system_message_suffix"}, sorted(profile["agent"])
assert profile["retired_secrets"] == ["CODER_SESSION_TOKEN"], profile["retired_secrets"]
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

python3 - "$repo_root/openhands/profiles/orc.json" "$repo_root/openhands/profiles/common.json" <<'PY'
import json, sys
profile = json.load(open(sys.argv[1]))
common = json.load(open(sys.argv[2]))
assert set(profile) == {"agent"}, sorted(profile)
assert profile["agent"] == {"kind": "openhands"}, profile["agent"]
assert common["mcp_servers"]["coder"] is None
assert common["mcp_servers"]["litellm-tools"]["url"] == "https://api.ai.h-cloud.lan/mcp/"
PY

echo 'PASS: profile JSON files parse and match expected schema/values'
