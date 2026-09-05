# h-cloud-upgrader automation

Nightly OpenHands automation that keeps the h-cloud GitOps repository's dependencies
current: Helm charts (HelmRepository, OCI), Flux `OCIRepository` refs, container image
tags and renovate-annotated pins. Each dependency is handled on its own — researched,
bumped in one commit, pushed, reconciled by Flux and verified live on the cluster —
before the next one is touched. Anything risky or unclear becomes a GitHub issue the
operator answers instead of a silent change.

| File | Purpose |
|---|---|
| `prompt.md` | The upgrade policy the agent executes. Placeholders are filled from `automation.json` `vars`. |
| `automation.json` | Request body: cron trigger, model, timeout, and the `vars` block. |
| `smoke.json` | Var overrides and report assertions for `common/smoke.py`. |

## Behaviour per dependency

1. **Embargo**: a version younger than 48 h is not taken; the newest version older
   than 48 h is used instead, or the dependency waits for the next run.
2. **Decision memory**: issues labelled `h-cloud-upgrader` in the GitOps repo are the
   memory. Open + unanswered → skip. `/skip` → skip that target for good. `/defer` →
   skip for 14 days. `/update` → apply on the next run and close the issue.
3. **Research**: release notes for every version between current and target from the
   source repo (found via chart metadata / OCI labels / Renovate `depName`), open
   upstream issues about the target, web search (cluster-local SearXNG) as fallback.
   Findings are compared with how the repo actually uses the dependency.
4. **Decide**: clean notes, no relevant issues, no CRD/value changes (majors included) →
   apply. Anything else, or any doubt → open an issue `upgrade: <name> <cur> -> <new>`
   with a summary, links, risk read and suggested action, then continue.
5. **Apply**: edit only that dependency's pins, validate with the repo's validator
   (or `flux build ... --dry-run`), commit `chore(deps): update <name> to <target>`,
   push to `main`, `flux reconcile` source → kustomization → helmrelease.
6. **Health gate**: Kustomization Ready on the new revision, HelmRelease Ready on the
   target chart, rollouts complete, pods Ready with stable restart counts, new tag in
   the pod spec, endpoints present, no new Warning events. Then a functional check:
   health endpoint plus a real request (API call, login page, DNS query, metrics
   scrape, PromQL `up`, a consumer of an infra component still working) via the
   Service DNS name or `*.h-cloud.lan` HTTPRoute, and a log diff for new
   error/panic lines. Polled up to `HEALTH_TIMEOUT_MINUTES`.
7. **On failure**: one fix-forward attempt if the cause is clear (renamed value, new
   required value, CRD ordering), otherwise `git revert`, push, reconcile, confirm the
   gate passes on the reverted state, open an issue with the evidence.

Superseded Renovate PRs are closed with a comment naming the commit. There is no run
deadline: every inventory row must end with a terminal disposition (`applied`,
`asked:#N`, `reverted:#N`, `failed`, `skipped:embargo`, `skipped:already-decided`,
`skipped:already-latest`), and the run ends only when the work list is empty. Risk and
"major" are reasons to ask, never to skip silently. `MAX_UPGRADES_PER_RUN` (`0` =
unlimited, the default) is a testing knob that caps how many dependencies reach the bump
step. The automation `timeout` (12 h) is the platform's hard stop, not a pacing target.

## Prerequisites

- The token behind `GITHUB_PERSONAL_ACCESS_TOKEN` (`agent-npa`) needs `contents:write`,
  `issues:write` and `pull_requests:write` on the GitOps repo. Fill `vars.GITOPS_REPO`
  in `automation.json`.
- Cluster access is declared in `lkshrk/h-cloud`. The automation runs on the
  `openhands` pod in `ai` (sandboxless), so it uses that pod's service account, which
  is otherwise scoped to `agent-sandbox`. The manifests give it **read-only** cluster
  access and **no write access at all**:
  - `kubernetes/apps/ai/openhands-reader-rbac.yaml` — ClusterRole `openhands-reader`
    (get/list/watch on Flux objects, workloads, pods, logs, events, services,
    endpointslices, HTTPRoutes, certificates, CRDs, and only its own Receiver; no
    secrets, no configmaps, no exec, no writes), bound permanently to `ai/openhands`.
    The prompt pre-flights this and exits if access is missing.
  - `kubernetes/apps/flux-system/flux-instance/app/receiver.yaml` — Receiver
    `openhands-upgrader` (`generic`, reusing `gh-webhook-secret`) that reconciles the
    `flux-system` GitRepository and every Kustomization. The agent POSTs to
    `webhook-receiver.flux-system.svc.cluster.local/<status.webhookPath>` after each
    push; the path comes from the Receiver status, readable with the role above.
- Egress: the `ai` namespace must be able to reach `webhook-receiver.flux-system` and,
  for the functional checks, service DNS names of other namespaces or the
  `*.h-cloud.lan` gateway.
- Base image: Linux x86_64, Python 3.11+, bash, git, curl and uv. No sudo, Docker,
  Talos credentials or cluster writes are needed for setup.
- Tools: `bootstrap/setup.py` runs before the agent on every scheduled/manual run.
  `bootstrap/tools.lock.json` pins kubectl, gh, Mike Farah yq v4, crane, flux, Helm,
  jq, just and Flate (v0.6.1, matching the GitOps repo's Mise and CI pins).
  Download and executable SHA-256 values are checked before execution; the source
  of each official checksum is recorded in the lock. No runtime `latest` lookup.
  Cache location: `~/.openhands/toolchains/h-cloud-upgrader/<lock-sha256>/bin`.
  Matching binaries are reused after hash and version checks; replacements are
  atomically installed under a file lock. Existing `~/.openhands/bin` is untouched.
  Unsupported platforms, failed downloads, checksums or version checks stop setup.
  The standard preset SDK setup is then run unchanged and its Python environment
  checked for YAML aliases and version parsing support.
- Validation: the prompt permits the repository's `scripts/flate-test.sh` with the
  same arguments/exclusions as `just flux validate` when unrelated Talos expressions
  break Just evaluation. No dummy commands or fabricated Talos config. Flate pin
  drift or a failing validator baseline blocks pushes. Registry authorization,
  resource read permissions and functional-check coverage are separate checks,
  not problems that the installer can fix.

Pod-scoped instead of run-scoped: automation runs share the pod (and service account)
with interactive Agent Canvas sessions, so every conversation on the pod has the same
read-only view. Truly per-run identities would need the automation service to run each
job in its own sandbox pod.

## Applying

```bash
OPENHANDS_SESSION_API_KEY=... python3 openhands/automations/common/apply.py openhands/automations/orc/h-cloud-upgrader
```

`common/apply.py` reads `automation.json`, renders `prompt.md` with the `vars` block, finds an
existing automation named `h-cloud-upgrader` via `GET /api/automation/v1`, and updates
it (`PATCH`) or creates it (`POST /api/automation/v1/preset/prompt`). `--dry-run`
prints the body. `OPENHANDS_URL` overrides the base URL, default
`http://openhands.ai.svc.cluster.local:8000`.

With `bootstrap: true`, apply packages the two reviewed bootstrap files alongside
(not instead of) the generated SDK files. It wraps the actual `setup.sh` entry point with `python3 bootstrap/setup.py`,
preserves the original SDK setup as `bootstrap/sdk-setup.sh`, and renders the
immutable toolchain PATH into the prompt. New automations stay disabled until packaging succeeds; existing ones are
switched with one PATCH. Reapplying unchanged files reuses the package. Prompt
edits preserve the bootstrap files. The smoke harness uses this same deployment
path and applies dry-run overrides before rendering.

To check only tool installation without starting an agent:

```bash
python3 openhands/automations/orc/h-cloud-upgrader/bootstrap/setup.py --tools-only
```

To update tool versions, review the upstream release, update both artifact and
executable hashes in the lock, run the tests and tools-only check, then reapply.
A lock change selects a new cache directory without changing in-flight runs.
Changing setup does not retrofit an agent that has already started.

Trigger a run by hand:

```bash
curl -X POST "$OPENHANDS_URL/api/automation/v1/<id>/dispatch" -H "X-Session-API-Key: $OPENHANDS_SESSION_API_KEY"
```

## Smoke test

```bash
OPENHANDS_SESSION_API_KEY=... python3 openhands/automations/common/smoke.py openhands/automations/orc/h-cloud-upgrader
```

Renders the prompt with `smoke.json` `vars` layered over `automation.json` (`DRY_RUN=true`,
a small budget), registers it as `h-cloud-upgrader-smoke`, dispatches
one run, waits for it, and checks the agent's final report against the `expect` and
`forbid` regexes. The shadow automation is deleted afterwards (`--keep` retains it).
With `DRY_RUN=true` the agent discovers, embargoes, researches and decides, but does not
commit, push, reconcile or open issues.
