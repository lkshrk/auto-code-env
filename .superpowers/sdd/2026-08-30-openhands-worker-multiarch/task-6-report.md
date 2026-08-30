# Task 6 report — Omni convergence

## RED

Added runtime validation requiring `runtimes/wsl/omni/settings.json`; before
creation, the test trace stopped at `test -f .../omni/settings.json`.

## Change

- Added schema-v24, no-discovery/no-dots Omni desired state with explicit `apt`
  and `npm` providers and reusable system/no-script/Claude groups.
- Bootstraps checksum-verified Omni `v0.10.4` for `x86_64` and `arm64`.
- Leaves only `ca-certificates`, `curl`, and `xz-utils` in pre-Omni apt.
- Runs system sync as root; runs two agent syncs with separate cache/state and
  lifecycle environment: deny all scripts, then allow Claude Code only.
- Preserves Node/uv bootstrap and all package, ownership, binary, and rbw
  post-verification.
- Removes duplicate `nginx` apt installation from the image build.

## Verification

- `bash runtimes/wsl/tests/provision.Tests.sh` — pass; persistent fixture covers
  both Omni archives/checksums, rerun idempotence, root/agent state separation,
  package groups, and lifecycle environment split.
- `bash runtimes/wsl/tests/image.Tests.sh` — pass.
- `bash runtimes/wsl/tests/runtime.Tests.sh` — pass.
- `bash -n ...`, `shellcheck ...`, `jq empty ...`, and `git diff --check` — pass.
- Native amd64 BuildKit smoke attempted. Build reached the provisioning layer,
  then Docker returned `mkdir: No space left on device` before Omni download or
  package convergence. This is a local Docker storage limit, not a test failure.

## Note

While wiring the fixture, found `env -i` discarded lifecycle environment
variables. `run_agent_omni` now forwards only the three explicit npm lifecycle
variables, so no-script and Claude-only behavior reaches Omni's npm process.

## Follow-up — immutable canonical config

Native arm64 smoke showed Omni creates `.omni-config.lock` and
`settings.json.bak` beside its config. The canonical root-owned config now
remains immutable: each root/agent sync gets a newly copied, private temporary
config directory, while its existing cache/state directory remains persistent.
The temporary directory is validated before deletion, deleted after both
success and failure, and deletion failure is fatal. The fixture makes Omni
write both artifacts and verifies the canonical directory and all temporary
directories are clean after both provisioning passes.

Follow-up static checks (`bash -n`, ShellCheck, JSON validation, runtime suite,
and `git diff --check`) pass. The full fixture was rerun through all expected
negative security cases; native BuildKit remains blocked by local Docker
storage exhaustion.

Controller verification after `bef885f`: persistent full
`bash runtimes/wsl/tests/provision.Tests.sh` exited `0`.

## Follow-up — npm scan skeleton

Native arm64 smoke confirmed the root Omni group, including the exact rbw
package, then failed before agent installation because npm's bulk scan needs
the global prefix skeleton to exist. The fixture first required that skeleton
and failed at the missing `~/.local/bin` path. `preflight_agent_npm_paths` now
creates only the agent-owned, mode-0700 `bin`, `lib`, and `lib/node_modules`
directories before agent Omni sync; package scope directories remain created by
npm. A pre-existing `.local` symlink is rejected before Omni runs. Bash syntax,
ShellCheck, runtime validation, and diff checks pass.
