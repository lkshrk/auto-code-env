# OpenCode plugins

The control-plane image `ghcr.io/lkshrk/opencode-control-plane` (built from
[`../image/Dockerfile`](../image/Dockerfile) by
`.github/workflows/opencode-image.yaml`) is the upstream OpenCode image plus
`git`, which OpenCode needs to resolve projects, with this plugin at
`/opt/opencode/plugins/coder-workspace.ts`. It is tagged with the OpenCode
version and `sha-<commit>`.

## `coder-workspace.ts`

Workspace type `coder` for an OpenCode control plane (OpenCode 1.18.32,
`OPENCODE_EXPERIMENTAL_WORKSPACES=true`). The control plane keeps sessions and
the UI; every tool call runs in a Coder workspace of the `dev` template.

- **configure**: the repository comes from `extra.repository` or the project's
  `origin` remote (read from `.git/config`, no git binary needed). Stacks and
  Docker come from `extra.stacks`/`extra.dind` or from markers in the
  repository root (`go.mod`, `pyproject.toml`, `package.json`, `Cargo.toml`,
  `kustomization.yaml`, `Dockerfile`, ...) read through the GitHub API.
- **create**: finds the caller's Coder workspace for that stack set
  (`oc-<stacks>-<hash>`), creating or starting it with `stacks`,
  `enable_dind` and `enable_opencode`, then asks its spawner for a worktree
  and an `opencode serve`.
- **target**: the Coder port URL of that server with the session token;
  lookups are cached for 15 s.
- **remove**: stops the server and removes a clean worktree.

The workspace servers do not read the control plane's config. The file named
by `workspaceConfig` is sent to them as `OPENCODE_CONFIG_CONTENT` on create,
with `{env:NAME}` resolved on the control plane, so providers, models and
agents are defined once.

| Option | Environment fallback | Purpose |
|---|---|---|
| `coderUrl` | `CODER_URL` | Coder deployment |
| `coderToken` | `CODER_SESSION_TOKEN` | token of the `agent_owner` Coder user |
| `wildcardHost` | `CODER_WILDCARD_HOST` | host part of Coder's wildcard access URL |
| `workspaceConfig` | `OPENCODE_WORKSPACE_CONFIG` | config file sent to workspace servers |
| `githubToken` | `GITHUB_TOKEN` | optional, for stack detection on private repositories |
| `template`, `agent` | | default `dev`, `main` |
| `autostopHours` | | Coder autostop for created workspaces, default 4; activity through the proxy extends it and the next request starts a stopped workspace again |
| `localSpawner` | `OPENCODE_LOCAL_SPAWNER` | skip Coder and use a spawner on this URL (local testing) |

Local end-to-end check without Coder: run `coder/modules/opencode/spawner.py`
with a settings JSON (`port`, `binary`, `state`, `revision`), start
`opencode serve` with this plugin, `OPENCODE_EXPERIMENTAL_WORKSPACES=true` and
`OPENCODE_LOCAL_SPAWNER=http://127.0.0.1:<port>`, then
`POST /experimental/workspace?directory=<project>` with `{"type": "coder"}` and
create a session with `?workspace=<id>`.
