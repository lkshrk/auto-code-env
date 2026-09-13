# Settings profiles

A settings profile is a declarative JSON description of one Agent Canvas backend.
`openhands-overlay settings --file <path>` reads it and applies the difference
against the running backend at `http://127.0.0.1:8000`. Nothing here is a secret:
every credential is named by its Vaultwarden item UUID and fetched at apply time.

Each file in this directory is published as a release asset named
`profile-<name>.json`, so `common.json` ships as `profile-common.json`.

The merging, validation, and backend calls live in `../worker/image/rootfs/usr/local/lib/openhands/apply-profile.py`,
a python3 standard library script that the overlay runs and that any other
backend can run directly. See [Backends without a
worker](#backends-without-a-worker).

Profiles are explicit bootstrap/recovery inputs, not the live settings owner.
New worker setup applies the baseline once. Ordinary updates (including forced,
scheduled and replacement updates) and service/container starts never reapply it.
Update still stages release profiles for a later manual recovery command. Review
the declared changes and take a private snapshot before intentionally applying a
baseline over UI-edited settings. Sparse profile application and full captured
settings replacement remain different operations.

## Layering

`--file` may be repeated and the files are layered left to right:

```sh
openhands-overlay settings --file /etc/openhands/profile-common.json --file /etc/openhands/profile.json
```

| Section | Merge rule |
|---|---|
| `llm`, `agent`, `git_sync` | per key; a later file overrides only the keys it sets |
| `secrets` | by secret name; a later file replaces the entry that shares a name |
| `mcp_servers` | by server key; `null` explicitly removes the persisted entry |
| `skills` | by `repo_path` |
| `retired_secrets` | a later file replaces the list |

`common.json` holds what every host shares. A host profile such as
`towerr.json` holds only what is specific to that host, which today is `llm`,
`agent`, and `git_sync`. Each file is validated on its own, then the merged
result is checked for cross-section references.

`retired_secrets` explicitly names stored secrets to delete after all profile
sections apply successfully. Missing names are harmless; unrelated secrets are
preserved. A retired name cannot also be declared by the merged profile. Existing
conversations must be restarted after migration.

## Backends without a worker

`orc` is an Agent Canvas backend that runs as a Kubernetes deployment in
h-cloud, not as a WSL worker. It has no Vaultwarden and no overlay, so it runs
the applier directly:

```sh
apply-profile.py --api http://openhands:8000 --api-key-file /secrets/sessionApiKey \
  --secrets-dir /secrets/profile --state-dir /tmp/state \
  profile-common.json profile-orc.json
```

Live settings are managed directly in OpenHands. Normal Kubernetes deployment
does not apply these profiles. Run the command above explicitly for bootstrap
or recovery only, using reviewed assets and verifying their release checksums
when downloading them. A worker release is not required for live settings edits.

`--secrets-dir` holds one file per referenced secret name, and on orc it is a
projection of the `openhands-secret` Kubernetes Secret: key `LITE_LLM` is
projected to the path `LITELLM_API`, matching the secret name `common.json`
declares. The `item` UUIDs stay in the profile and are simply unused there. A
name the directory does not provide fails the run before the first backend call.
Coder tools are reached through the aggregate `litellm-tools` connection. The
`coder: null` entry removes the old dedicated connection. LiteLLM holds the
Coder credential and enforces the tool allowlist, so no host needs the Coder CLI
or a Coder token. `llm.api_key_item` is read from the file `LLM_API_KEY` and
`git_sync.token_item` from `GIT_SYNC_TOKEN`; every `secrets` entry is read from
its own name.

`orc.json` sets only `agent.kind`. Its model, base URL, and API key come from the
HelmRelease environment, and it has no git sync, so `common.json` supplies
everything else it needs: `secrets`, `skills`, and `mcp_servers`.

## Gateway cutover

Before changing live settings, verify aggregate gateway discovery, a harmless
Coder call, unauthorized-key rejection, and non-allowlisted-tool rejection.
Confirm the shared Coder identity and scopes match the intended workspace/template
boundary; a tool-name allowlist does not constrain workspace bash commands.

Back up live settings privately, then explicitly remove the dedicated Coder
connection and retired OpenHands token through the settings UI/API or the reviewed
migration profile. Verify settings without printing credentials and start fresh
conversations; existing conversations may retain old configuration. Keep the
LiteLLM upstream token. Prepare rollback before retiring any old credential.
Neither worker publication nor a profile Job is a live cutover prerequisite.

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
{ "secrets": { "LITELLM_API": { "item": "e11c580d-59d0-4b50-a932-bcde5c4e1b57", "prefix": "Bearer " } } }
```

`prefix` is prepended to the fetched material before it is stored as the
Canvas secret and wherever an MCP header references the secret. The LiteLLM
gateway requires `Bearer ` in `x-litellm-api-key`, and the dotfiles `apm.yml`
expects the `LITELLM_API` variable to carry that prefix already.

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
`headers`; a stdio server sets `command` and may set `args` and `env`. A server
cannot set both `url` and `command`.

A header or env value is either a literal string or `{"secret": "NAME"}`, which
resolves to the Canvas secret of that name. The name must be declared in the
merged `secrets` section or the profile is refused. Env names are upper-case
environment variable names.

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


## Private backup / restore of active settings

`backup-profile.py` is a standalone **stdlib Python 3 CLI for POSIX hosts**. It is
an operator-triggered snapshot, not a reconciliation loop. Its
`openhands-settings-snapshot` version 1 JSON format is **not** the declarative
profile schema above and must not be passed to `apply-profile.py`.

```sh
umask 077
mkdir -p "$HOME/private-backups"
python3 openhands/profiles/backup-profile.py backup "$HOME/private-backups/settings.json" \
  --api http://127.0.0.1:18000 --api-key-file /private/session-api-key
python3 openhands/profiles/backup-profile.py preview "$HOME/private-backups/settings.json"
python3 openhands/profiles/backup-profile.py restore "$HOME/private-backups/settings.json"
# Explicit mutation, only after reviewing the scope below:
python3 openhands/profiles/backup-profile.py restore "$HOME/private-backups/settings.json" \
  --api http://127.0.0.1:18000 --api-key-file /private/session-api-key --apply
```

Use the actual **agent-server origin**, not an automation backend; the script
calls `/api/settings`. `--api` accepts HTTPS or HTTP on a literal loopback IP
(not `localhost`). URL credentials, paths, queries, fragments, redirects and
proxies are refused/disabled. TLS uses normal certificate verification. Each
request has a 15-second socket timeout and a 16 MiB response limit. No retries
are automatic. The API key is read from a private regular file, never a CLI
argument value. Symlink input files and group/world-accessible input files are
refused; use a trusted private parent directory too. Output is newly created
0600, never overwritten (including symlinks). The complete serialized UTF-8
snapshot is limited to 16 MiB, including all custom secrets; oversized backups
fail before writing snapshot bytes. A failed backup removes its
incomplete output; an interrupted process may leave an incomplete private file.

**Backups may contain plaintext credentials**, even without `--include-secrets`.
The settings GET explicitly requests `X-Expose-Secrets: plaintext` so embedded
LLM/MCP credentials can be restored. Redacted settings are not usable backups.
Never commit, publish, attach, or place snapshots in web/workspace/shared roots.
Encrypt them with your approved at-rest encryption tool before transporting or
archiving them; protect decryption keys separately and minimize plaintext
retention. File permissions alone are not at-rest encryption. Preview and errors
print counts/status only, not settings values, secret names, URLs, or response
bodies.

### Scope and completeness

* Replaces **all active `agent_settings`**, including LLM, MCP, agent context,
  and agent-kind-specific configuration. It also restores all persisted
  `conversation_settings` defaults. New conversations pick up these defaults;
  existing conversations are not changed.
* The API is recursive merge-patch, not PUT. The script computes nested deletion
  markers so stale MCP servers, headers, environment variables and other managed
  map entries are removed. Lists are replaced.
* Restore eligibility depends on the destination. Explicit agent nulls are
  supported only when unchanged and omitted from the patch. Changing a value
  to null, introducing a null-bearing subtree, or replacing a null-bearing array
  fails before mutation. Agent-kind switches compare against an empty base;
  null-bearing switches, including current SDK default variants, are rejected.
  This conservative contract avoids guessing schema-dependent default resets.
  Conversation-default nulls follow their separate API semantics.
* Successful backup or offline preview does not guarantee restoration onto a
  fresh or different destination. For full disaster recovery, use a tested backup
  of OpenHands persisted state. Restored settings are read back and compared
  exactly before custom-secret writes; other normalization mismatches cause a
  reported partial failure rather than silently reporting success.
* Default `custom_secrets: null` means **custom secrets were omitted**, not that
  there were none. Restore leaves the custom-secret store untouched and is
  incomplete if the restored configuration needs missing custom secrets.
  Use `--include-secrets` on **backup and applied restore** to include all custom
  secret names, descriptions and plaintext values. An included empty list means
  the source had none. Included secrets are **upserted**, never deleted; unrelated
  destination secrets always survive. Thus this is complete for the captured
  managed scope, not an exact replacement of the entire secret store.
* Excludes `misc_settings`, active profile pointers, saved profile catalogs,
  provider-connection stores, OAuth/subscription state outside agent settings,
  automation/git-sync configuration, installed skill files, conversations,
  history, workspaces, and filesystem data. Referenced provider connections,
  skills, binaries and paths must already exist at the destination. This is not
  a full instance disaster-recovery backup.

Snapshot envelope, complete known agent field set, schema versions, conversation
fields, basic credential/map shapes, secret names/types, duplicate keys and
non-finite JSON values are checked before mutation. The stdlib CLI deliberately
does not reimplement every SDK model validator: the server validates the settings
PATCH. Supported contracts are agent schema 5 (`openhands`/`acp`) and conversation
schema 1. CI requires paired server/SDK 1.44.0 (the worker image pin) and
1.46.0 contract tests. These are not interchangeable with an arbitrary newer server. Other versions/agent field sets fail closed.
Do not hand-edit snapshots or restore across untested server versions.

Restore without `--apply` and `preview` are **offline**, validate the snapshot and
print counts only; they do not predict a destination diff or validate remote
compatibility. Quiesce other settings writers before backup/restore: there is no
cross-request snapshot lock or compare-and-swap. A restore applies one settings
PATCH, verifies it, then upserts custom secrets individually. This sequence is
**nontransactional**; a failure or timeout can leave some changes applied, and no
rollback is attempted. Investigate privately before retrying. Backup with custom
secrets also spans several reads and requires a quiet source for consistency.

### Tests

```sh
OPENHANDS_SUPPRESS_BANNER=1 python -m unittest discover \
  -s openhands/worker/tests -p test_backup_profile.py -v
```

The dedicated `settings-contracts` CI matrix installs exact server/SDK pairs
1.44.0 and 1.46.0 in separate Python 3.12 environments on Ubuntu 24.04, with
`agent-client-protocol==0.10.1` (inside both published SDK requirements) and the
worker's `posthog>=6,<7` compatibility constraint. Dependency setup and `pip check`
fail the job on incompatibility. It runs `settings-contracts.py`, which checks the
installed versions and fails for missing imports, empty discovery or skipped tests.
Both the snapshot suite and `test_applier_contract.py` are mandatory; the Docker
transport/failure-injection suite remains separate. The applier contract fixture
uses real `MCPServerPatch` and `PersistedSettings.update` for generated patches and
agent-kind reconstruction, with loopback HTTP only and synthetic credentials.

To run that same gate in an already provisioned compatible environment:

```sh
EXPECTED_OPENHANDS_VERSION=1.44.0 OPENHANDS_SUPPRESS_BANNER=1 \
  python openhands/worker/tests/settings-contracts.py
```

Tests need an already-installed OpenHands agent-server/SDK; the CLI itself needs
only the standard library. Model roundtrips call the real `PersistedSettings`
merge implementation with synthetic settings, including fail-closed agent-kind
changes, null transitions and unchanged nulls.
A loopback-only HTTP fixture is necessary to exercise the subprocess CLI's file
permissions, exposure/auth headers, redirect/proxy behavior, output redaction,
opt-in gates and partial failures without exporting or modifying user settings.
The fixture delegates settings mutation to the real model, not a mock merge.
