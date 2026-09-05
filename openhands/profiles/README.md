# Settings profiles

A settings profile is a declarative JSON description of one Agent Canvas backend.
`openhands-overlay settings --file <path>` reads it and applies the difference
against the running backend at `http://127.0.0.1:8000`. Nothing here is a secret:
every credential is named by its Vaultwarden item UUID and fetched at apply time.

Each file in this directory is published as a release asset named
`profile-<name>.json`, so `common.json` ships as `profile-common.json`.

## Layering

`--file` may be repeated and the files are layered left to right:

```sh
openhands-overlay settings --file /etc/openhands/profile-common.json --file /etc/openhands/profile.json
```

| Section | Merge rule |
|---|---|
| `llm`, `agent`, `git_sync`, `agents` | per key; a later file overrides only the keys it sets |
| `secrets` | by secret name; a later file replaces the entry that shares a name |
| `mcp_servers` | by server key |
| `skills` | by `repo_path` |

`common.json` holds what every host shares. A host profile such as
`towerr.json` holds only what is specific to that host, which today is `llm`,
`agent`, and `git_sync`. Each file is validated on its own, then the merged
result is checked for cross-section references.

## Schema

Every section is optional. Unknown sections and unknown keys are refused.

### `llm`

| Key | Type | Meaning |
|---|---|---|
| `model` | string | LiteLLM model identifier |
| `base_url` | string | absolute `http://` or `https://` URL |
| `api_key_item` | string | Vaultwarden item UUID holding the API key |

### `agent`

| Key | Type | Meaning |
|---|---|---|
| `kind` | `"openhands"` or `"acp"` | which agent runs the conversation |
| `acp_server` | `"claude-code"`, `"codex"`, `"gemini-cli"`, `"custom"` | ACP backend |
| `acp_command` | string or array of strings | executable and arguments |
| `acp_model` | string or null | model the ACP backend should use |

Any `acp_*` key requires `kind` to be `"acp"`.

### `secrets`

A map of secret name to `{"item": "<uuid>"}`. The name must start with a letter
and use letters, digits, and underscores. Each becomes a Canvas secret, which is
exported into the environment of the ACP subprocesses.

```json
{ "secrets": { "LITELLM_API": { "item": "e11c580d-59d0-4b50-a932-bcde5c4e1b57" } } }
```

`common.json` declares `LITELLM_API`, which the MCP header below also consumes.
`towerr.json` adds `GH_TOKEN` from the worker's GitHub PAT so `gh` and the GitHub
API work inside a conversation; layering merges the two into one set.

### `skills`

An array of skills to install. `source` is required; `ref` and `repo_path` are
optional. Layering keys these by `repo_path`.

```json
{
  "skills": [
    {
      "source": "https://github.com/lkshrk/auto-code-env.git",
      "ref": "main",
      "repo_path": "openhands/skills/agent-sandbox-deploy"
    }
  ]
}
```

### `mcp_servers`

A map of server key to one server. A remote server sets `url` and may set
`headers`; a stdio server sets `command` and may set `args`. A server cannot set
both `url` and `command`.

A header value is either a literal string or `{"secret": "NAME"}`, which resolves
to the Canvas secret of that name. The name must be declared in the merged
`secrets` section or the profile is refused.

```json
{
  "mcp_servers": {
    "litellm-tools": {
      "url": "https://api.ai.h-cloud.lan/mcp/",
      "headers": { "x-litellm-api-key": { "secret": "LITELLM_API" } }
    },
    "openaiDeveloperDocs": { "url": "https://developers.openai.com/mcp" },
    "local-notes": { "command": "notes-mcp", "args": ["--stdio"] }
  }
}
```

### `git_sync`

| Key | Type | Meaning |
|---|---|---|
| `repo_url` | string | automation repository, required |
| `branch` | string | branch to follow |
| `path` | string | directory inside the repository |
| `token_item` | string | Vaultwarden item UUID holding the sync token |
| `interval_seconds` | non-negative integer | poll interval, `0` disables polling |

### `agents`

| Key | Type | Meaning |
|---|---|---|
| `repo` | string | `owner/name` shorthand or absolute HTTPS git URL, required |
| `ref` | string | branch or tag; the `ref:` line is omitted when absent |
| `path` | string | relative directory inside the repository holding `apm.yml` |
| `targets` | array of strings | harnesses to deploy to, non-empty and required |

The overlay renders these into the omni root manifest at
`/home/agent/.config/omni/apm.yml` and runs `omni agents sync` in
`/home/agent`, both as the `agent` user. omni installs the global APM workspace
under `/home/agent/.apm` and deploys the primitives into `/home/agent/.claude`
and `/home/agent/.codex`. The manifest is rewritten only when it differs; the
sync runs every time and is the reconciliation step.

```json
{
  "agents": {
    "repo": "lkshrk/dotfiles",
    "ref": "main",
    "path": "apm/ai-plugins",
    "targets": ["claude", "codex"]
  }
}
```

```yaml
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
```
