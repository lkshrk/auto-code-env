---
name: coder-workspaces
description: Use a Coder workspace instead of installing toolchains in the sandbox. Use when a task needs a language toolchain, Docker, a browser, cluster tooling, or a repository checkout that the current environment does not have.
triggers:
- coder
- workspace
- toolchain
- install go
- install node
- install python
- docker
- playwright
---

# Working in Coder workspaces

The `coder` MCP server exposes workspaces on `https://coder.h-cloud.io`. Every
template already carries the toolchains, credentials, dotfiles, and repository
checkouts a project needs. Do not `apt-get`, `pip install`, `npm install -g`,
or download toolchains into this sandbox to get a project building; create or
reuse a workspace and run the work there.

## Choose a workspace

1. `coder_list_workspaces` and reuse a running workspace whose template and
   repositories match. Start a stopped one with `coder_create_workspace_build`
   and `transition: start`.
2. Otherwise `coder_list_templates`, then `coder_get_template` for the
   parameters and presets. Project templates (`go`, `python`, `ts`, `lua`,
   `sveltekit`, `monorepo`, `civora`, `routivo`, `hermes`, `gitops`) carry
   their repositories as presets. `dev` is the general-purpose template: pick
   a preset, or set `stacks` (JSON list such as `["go","python"]`), `repos`
   (comma-separated git URLs), `enable_dind`, and `enable_playwright` in
   `rich_parameters`.
3. `coder_create_workspace` with `template_id`, `template_version_preset_id`
   when a preset fits, and a name of the form `<project>-<purpose>`. Never
   create on `dev-kubernetes` or any other Kubernetes-backed template unless
   the task asks for it.
4. Poll `coder_get_workspace` until the build is `running` and the agent is
   `connected`; `coder_get_workspace_build_logs` and
   `coder_get_workspace_agent_logs` explain a stall.

## Work inside it

- `coder_workspace_bash` runs a command as the workspace user. Repositories
  are cloned to `/home/coder/<repo-name>`; `cd` there first. Raise
  `timeout_ms` for builds and test suites, or set `background: true` and poll
  a log file. Use `coder_workspace_ls`, `coder_workspace_read_file`,
  `coder_workspace_write_file`, and `coder_workspace_edit_file` for files.
- The workspace has the project's git credentials. Commit and push from the
  workspace, on a branch, and report the branch and commit.
- Long builds and test suites belong in the workspace; keep this sandbox for
  planning, review, and reporting.

## Leave it tidy

Stop a workspace you created when the task is done
(`coder_create_workspace_build` with `transition: stop`) unless the task asks
to keep it running. Never delete workspaces.
