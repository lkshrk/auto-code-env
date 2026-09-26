#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && until [ -e .git ]; do [ "$PWD" = / ] && exit 1; cd ..; done && pwd)

for profile in "$repo_root"/openhands/profiles/*.json; do
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$profile"
done

python3 - "$repo_root/openhands/profiles/common.json" "$repo_root" <<'PY'
import json, os, re, sys
profile = json.load(open(sys.argv[1]))
for skill in profile.get("skills", []):
    repo_path = skill.get("repo_path")
    assert repo_path and re.fullmatch(r"[A-Za-z0-9_./-]+", repo_path) and ".." not in repo_path, skill
    if skill["source"].endswith("/auto-code-env.git"):
        assert os.path.isfile(os.path.join(sys.argv[2], repo_path, "SKILL.md")), skill
assert set(profile) == {"agent", "secrets", "skills", "mcp_servers", "retired_secrets"}, sorted(profile)
assert set(profile["agent"]) == {"system_message_suffix", "user_message_suffix", "load_user_skills", "load_project_skills"}, sorted(profile["agent"])
rules = open(os.path.join(sys.argv[2], "openhands/profiles/AGENTS.md")).read().strip()
assert profile["agent"]["system_message_suffix"] == rules, "common.json agent.system_message_suffix must equal openhands/profiles/AGENTS.md"
assert "litellm-tools_coder-coder_workspace_bash" in profile["agent"]["user_message_suffix"], profile["agent"]["user_message_suffix"]
# A long suffix drowns short user messages; the agent then answers the reminder instead.
suffix = profile["agent"]["user_message_suffix"]
assert len(suffix) <= 400 and "not part of the user's request" in suffix, suffix
assert profile["agent"]["load_project_skills"] is True and profile["agent"]["load_user_skills"] is True, profile["agent"]
assert profile["mcp_servers"]["github"] is None and profile["mcp_servers"]["linear"] is None, profile["mcp_servers"]
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
