# Shared OpenCode config

Every Coder workspace with OpenCode syncs this folder on start (sparse checkout of
`main` into `~/.opencode-v2/shared`) and links these into `~/.opencode-v2/config`:

- `AGENTS.md`: global instructions for every session.
- `agents/*.md`: agents (`model`, `permissions`, `steps`, `mode` in front matter).
- `commands/*.md`: slash commands.
- `skills/<name>/SKILL.md`: skills.

Changes reach a workspace on its next start. Edit here, not in the workspace:
the checkout is reset on every sync. Models are `gw/fast` and `gw/coding`
(LiteLLM aliases set by the template per workspace owner).
