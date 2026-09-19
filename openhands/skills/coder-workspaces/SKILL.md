---
name: coder-workspaces
description: This skill should be used for development on existing Git projects, including implementing features, fixing bugs, editing repositories, running tests, and reviewing code with execution. Select and reuse prepared Coder workspaces through native MCP, even when local toolchains are available.
triggers:
- coder
- workspace
- toolchain
- install go
- install node
- install python
- docker
- playwright
- implement
- fix bug
- run tests
- repository
- refactor
---

# Working in Coder workspaces

## Scope and transport

Use Coder for development on an existing Git project, including when the local host already has the required tools. Keep discussion, research and planning outside Coder unless repository execution is needed. Allow small standalone scripts locally. Ask whether to use Coder for a new substantial project without an existing repository.

Use the native Coder MCP tools exposed through the existing aggregate LiteLLM /mcp/ connection. Discover their actual names and schemas; gateway prefixes can vary. Names below identify native operations, not a second server registration. Keep authorization in LiteLLM. Do not add per-project MCP connections, tool allowlists, credential issuers or a replacement Coder provider.

Preserve live OpenHands settings. Apply repository profiles only during explicitly authorized bootstrap or recovery. Do not copy secrets into notes, bindings, repositories or delegation prompts. Treat templates as prepared environments, not proof that a repository or credential is present.

These instructions guide agent behavior; they do not technically enforce execution location.

## Recover or select a workspace

1. Recover the prior conversation binding first, if present. Check both the conversation/task handoff notes and, once a candidate workspace is reachable, `~/.local/state/coder-environment/binding.json` inside it (read with `coder_workspace_read_file`; treat a missing file or unreadable JSON as "no persisted binding" and fall back to notes alone). Cross-check the two; if they disagree, trust the more recent `updated_at` but verify workspace identity, repository, directory/worktree, branch and current capabilities regardless of source. Do not silently replace a missing or unsuitable binding.
2. Identify the required repository, stacks, features and location. Every workspace is a Kubernetes pod on the `dev` template; `location=desktop` (preset "Desktop (towerr)") pins it to the tainted desktop node k8s-12 with node-local storage, and only when the user asks for the desktop. Never silently substitute local development.
3. Call coder_list_workspaces, then inspect plausible candidates with coder_get_workspace. Inventory may omit build state or effective parameters. Do not infer suitability from template names or active-version defaults alone; existing workspaces can use different versions and selections.
4. Prefer suitable running workspaces. Require the needed capabilities as a subset: a Python + Go workspace can serve Go work. Verify effective features such as Docker engine access and browser dependencies separately from language stacks. Sharing is allowed, subject to worktree and service isolation.
5. Reuse a single suitable running candidate with a brief notice, not another approval prompt. Ask for selection when multiple candidates qualify at this tier. Consider stopped candidates only when no running candidate qualifies.
6. **Before starting a stopped candidate, check the target node'''s current resource state.** Use native MCP to query:
   - coder_list_workspaces to get all workspaces; for each running workspace, inspect its build parameters (cpu, memory) and agent health metadata via coder_get_workspace
   - Inside a running workspace on the same node, run coder stat cpu, coder stat memory, coder stat disk --path /home/coder for actual usage
   - Sum per-workspace cpu and memory allocations against known host capacity (desktop node k8s-12: 6 vCPU, 24 GiB; cluster nodes: see `kubectl describe node`). If total committed allocations approach or exceed host capacity, or disk usage on /home/coder exceeds 85%, do not automatically start another workspace there. Report the constraint and ask for direction. Unknown capacity, previous successful starts, low load and an available provisioner do not establish capacity. Ask when capacity is unknown or insufficient, or multiple stopped candidates qualify. Do not use workspace execution tools as probes on stopped candidates: they may implicitly start them.
7. If none qualify, list available templates and inspect the recommendation with coder_get_template. Explain the proposed template, stacks and features and obtain approval before creation. Prefer a matching preset; account for preset precedence over individual parameters. Use template_id for the active version, or an explicitly approved template_version_id for a candidate. Never silently promote a version.

For composable dev, inspect current schemas for stacks, repos, enable_dind, enable_playwright and enable_openhands. A list parameter may require a JSON-encoded string such as ["go","python"]. Use the supplied schema rather than assumed parameter types. Enabling OpenHands is not necessary merely to operate the workspace through Coder MCP.

If Coder is unavailable, required metadata cannot be established, or an environment cannot satisfy the task, report the concrete gap and ask. Do not silently hand-build a replacement environment on the OpenHands host.

## Workspace disk hygiene

During long-running work, periodically check workspace disk usage. If /home/coder exceeds 80% utilization or Docker image/containers/cache exceed reasonable bounds:
- Run docker system prune -f to remove stopped containers, unused images and build cache
- Clean workspace .cache, .local/share/nvim (lazy.nvim clones), and similar ephemeral directories
- Use bounded calls and report reclaimed space

Do not clean project repositories, checked-out code, or configured toolchains. Report before removing anything. Do not clean on a workspace that is currently executing a delegated task or background job.

## Wait for actual readiness

Watch build logs until provisioning succeeds, then verify agent connection and startup completion. A running container and connected agent alone are not ready. Obtain the persisted agent ID from workspace resources, not Terraform plan output.

Use coder_get_workspace_build_logs and coder_get_workspace_agent_logs for failures. For composable templates, inspect /home/openhands/.local/state/coder-environment/readiness.json; require ready: true, successful required checks and evidence that the report belongs to the current startup. Do not accept an old marker after a failed restart. Verify capabilities not covered by that report separately. Do not require this custom report for unrelated templates; use their documented readiness contract.

Bound polling and requests. MCP gateway timeouts do not prove a remote command failed or stopped. Check process/job state and persisted results before retrying a mutating command. Never repeatedly recreate workspaces to hide a startup failure.

## Bind the task and execute

Record a non-secret binding in conversation/task handoff notes: repository identity, workspace UUID and owner/name, agent, absolute checkout/worktree path, branch, verified capabilities and active preview/job/delegate needs. Update it when identity changes. This is a handoff convention, not an automatically enforced registry or lease.

In addition, persist the same non-secret facts inside the workspace at `~/.local/state/coder-environment/binding.json` so a *different* conversation, or the same conversation after a restart, can recover them without relying solely on external notes:

```json
{
  "bindings": [
    {
      "conversation_id": "...",
      "task_title": "short human-readable summary",
      "repo": "owner/name",
      "checkout_path": "/home/coder/...",
      "branch": "...",
      "bound_at": "2026-09-19T12:00:00Z",
      "updated_at": "2026-09-19T12:40:00Z"
    }
  ]
}
```

Upsert your own entry by `conversation_id` using `coder_workspace_read_file` then `coder_workspace_write_file` (create the file and parent directory if absent; never overwrite other conversations' entries). Never write secrets, tokens or full task descriptions into this file. Treat an entry whose `updated_at` is older than 7 days as stale: report it, do not silently delete it, and ask before removing another conversation's stale entry.

`conversation_id` already doubles as the LiteLLM session id on every completion call, so this file is also enough to attribute LiteLLM usage/cost to a workspace or task without any additional plumbing; see `docs/research/coder-workspace-litellm-attribution.md` for how to do that join.

Discover actual paths with coder_workspace_ls; do not assume /home/coder/<repo-name> exists. Inspect Git status before editing. Preserve unfamiliar changes and use a separate worktree for independent work. Verify repository identity before fetching or changing remotes. Sharing a workspace does not make its ports, services, databases or Docker resources isolated; ask if safe co-use cannot be established.

Use coder_workspace_bash for project commands and native coder_workspace_ls, coder_workspace_read_file, coder_workspace_write_file and coder_workspace_edit_file for project files. Follow each schema encoding requirements. Keep commits, tests and authorized pushes inside the bound workspace. Do not treat workspace selection as permission to push, merge or deploy. Install project dependencies using the repository lockfiles/package manager; do not confuse ordinary project dependency installation with rebuilding a missing workspace toolchain.

Use bounded calls for short commands. For long work, start once with durable output and exit-status reporting, then poll. Preserve running jobs across gateway timeouts and avoid printing credentials from logs or environment dumps.

## Delegate and recover

Pass the non-secret binding explicitly to delegates, with separate worktree paths where needed and instructions to use the same Coder workspace. Do not assume a child conversation inherits execution location. Track unfinished delegates and their services in the parent handoff. Keep the workspace running while any delegate needs it.

After interruption, verify the old workspace and worktree before resuming. Reconcile surviving jobs and previews; do not interpret a lost conversation or expired heartbeat as idleness. Ask before abandoning an inaccessible binding or changing infrastructure.

## Leave shared work safe

Give brief notices on selection, start and stop. Avoid repeated approval requests for already authorized steps.

Stop automatically only when fresh evidence establishes that no human, agent, delegate, preview or background job needs the workspace and coordination prevents a new participant joining during the stop decision. Creator identity, zero visible sessions, timestamps or an empty agent-owned list alone are insufficient. The available native tools do not establish such coordination by themselves; leave running when that guarantee is unavailable. A finished coding task does not release a preview handed to the user; wait for explicit release. Honor explicit stop requests after identifying the target and reporting any known active needs. Never delete a workspace without explicit authorization.

**Stop-time resource reporting**: When stopping a workspace, report the final coder stat cpu, coder stat memory, coder stat disk --path /home/coder and docker system df values. This provides a baseline for future capacity planning and verifies no unexpected resource retention.
