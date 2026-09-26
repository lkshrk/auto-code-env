# Rules for every conversation

## Tools before shell
- Linear: use the `litellm-tools_linear-*` tools for every read and write. Never scrape linear.app or guess issue state.
- Coder: use the `litellm-tools_coder-coder_*` tools to list, inspect, start and drive workspaces. Never curl the Coder API or ssh into a workspace by hand.
- GitHub: do all GitHub work with `gh` and `git` inside a Coder workspace. The workspace picks the account by repository owner: agent-npa for `lkshrk`, `loc-news`, `routivo`, `webdev-harke`, lkshrk for every other owner; for a foreign repository fork it under lkshrk with `gh repo fork`. Never call the GitHub API with curl or a token variable, and never override `GH_TOKEN`.
- Docs: `litellm-tools_context7-*` for library documentation, `litellm-tools_searxng-*` for the web.
- Before running a shell command, check whether a tool covers the job. The tool wins.

## Commands in Coder workspaces
- `litellm-tools_coder-coder_workspace_bash` blocks for up to `timeout_ms` (default 60000, maximum 300000) and the gateway may cut the call earlier. Anything that can take longer than about 20 seconds (installs, builds, test suites, clones, docker) runs detached: `background: true`, `timeout_ms: 10000`, and the command wrapped as `bash -c '...'` that writes `.agent-jobs/<id>/status`, `.agent-jobs/<id>/output.log` and `.agent-jobs/<id>/exit_code`.
- Exit code 124 with "Command continues running in background" means the launch worked. Do not launch it again.
- Poll with `litellm-tools_coder-coder_workspace_read_file` on `status`, `exit_code` and bounded slices of `output.log`. Never `sleep` inside a tool call.
- A gateway timeout is not a failed command. Read the job files before retrying anything.

## Commits
- Never add a Co-authored-by trailer or any other agent attribution to commit messages. Commit with the git identity that is already configured.

## Output discipline
- Keep every tool call well under 10000 output tokens: create a large file in pieces (create the first part, then insert the rest) and never regenerate a whole large file in one call. An empty reply from you means your previous output was cut off at the output-token cap; retry with a smaller piece.
- Before every tool call, write one short line saying what you are about to do and why; never call tools silently.
- In the shell tool, prefix commands with rtk so their output is compressed (rtk git status, rtk ls, rtk grep, rtk find, rtk kubectl get pods, rtk test <command>); if rtk is not found, run export PATH=$HOME/.openhands/bin:$PATH first, and if rtk garbles a command, rerun it as rtk proxy <command>.
- For any task with three or more steps, create a task_tracker plan before the first step and update the status of each item as soon as it is done, so progress is visible in the UI.
