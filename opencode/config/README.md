# Shared OpenCode config

Every Coder workspace with OpenCode syncs this folder on start (sparse checkout of
`main` into `~/.opencode-v2/shared`) and links these into `~/.opencode-v2/config`:

- `AGENTS.md`: global instructions for every session.
- `agents/*.md`: agents (`model`, `permissions`, `steps`, `mode` in front matter).
- `commands/*.md`: slash commands.
- `skills/<name>/SKILL.md`: skills.
- `plugins/*.ts`: OpenCode v2 plugins (default export `{ id, setup }`).

Changes reach a workspace on its next start. Edit here, not in the workspace:
the checkout is reset on every sync. Models are `gw/fast` and `gw/coding`
(LiteLLM aliases set by the template per workspace owner).

Built in: agents `build` (default), `plan`, `general`, `explore` (read-only) and
the `/review` and `/init` commands. Added here:

- `review` agent: read-only reviewer on `gw/coding`. Edits are denied; shell
  runs git/gh reads and test or lint runners, anything else needs approval,
  and redirects are denied. The model is per session, so pick it when you use
  the agent directly: `opencode run --agent review -m gw/coding "..."`. As a
  subagent it runs on its own model.
- `/ticket <ID>`: implements a Linear ticket on a new branch; no push.

Plugins: `rtk` rewrites shell commands through `rtk rewrite` (shell
`create.before` hook), because rtk's own OpenCode plugin targets the v1 API
(rtk-ai/rtk#3898).

MCP: `context-mode` and `codegraph` (CodeGraphContext, embedded FalkorDB) run
locally from `~/.opencode-v2/tools`. context-mode's hook-based routing is v1-only
(mksglu/context-mode#1199), so its routing lives in `AGENTS.md`. Code mode is
built in: MCP tools are called from code through `execute`.

Remote MCP: `gateway`, the LiteLLM MCP gateway (Linear, context7,
searxng). Linear write tools are denied in the OpenCode config for every
workspace, and the `oc-workers` key only reaches the read tools server-side.
