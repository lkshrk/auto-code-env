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

Superseded Renovate PRs are closed with a comment naming the commit. The run stops
cleanly after `MAX_UPGRADES_PER_RUN` applied upgrades (`0` = unlimited, the default) or
`RUN_DEADLINE_MINUTES`.

## Prerequisites

- The token behind `GITHUB_PERSONAL_ACCESS_TOKEN` (`agent-npa`) needs `contents:write`,
  `issues:write` and `pull_requests:write` on the GitOps repo. Fill `vars.GITOPS_REPO`
  in `automation.json`.
- Cluster access is declared in `lkshrk/h-cloud`. The automation runs on the
  `openhands` pod in `ai` (sandboxless), so it uses that pod's service account, which
  is otherwise scoped to `agent-sandbox`. The manifests give it **read-only** cluster
  access inside a nightly window and **no write access at all**:
  - `kubernetes/apps/ai/openhands-upgrader-rbac.yaml` — ClusterRole
    `openhands-upgrader-reader` (get/list/watch on Flux objects, workloads, pods,
    logs, events, services, endpointslices, HTTPRoutes, certificates, CRDs, and only
    its own Receiver; no secrets, no configmaps, no exec, no writes) and two
    CronJobs: `…-window-open` at 02:55 Europe/Berlin creates the ClusterRoleBinding
    for `ai/openhands` with `cleanup.kyverno.io/ttl: 3h`, `…-window-close` at 06:00
    deletes it as a backstop. The window is fail-closed: the opener has a 4-minute
    `startingDeadlineSeconds`, the binding expires via Kyverno TTL, and a
    ValidatingAdmissionPolicy pins name, roleRef, subject and TTL label of any
    binding the window SA creates. Outside the window the pod is back to
    `agent-sandbox` only; the prompt pre-flights this and exits if access is
    missing.
  - `kubernetes/apps/flux-system/flux-instance/app/receiver.yaml` — Receiver
    `openhands-upgrader` (`generic`, reusing `gh-webhook-secret`) that reconciles the
    `flux-system` GitRepository and every Kustomization. The agent POSTs to
    `webhook-receiver.flux-system.svc.cluster.local/<status.webhookPath>` after each
    push; the path comes from the Receiver status, readable with the role above.
- Egress: the `ai` namespace must be able to reach `webhook-receiver.flux-system` and,
  for the functional checks, service DNS names of other namespaces or the
  `*.h-cloud.lan` gateway.
- Tools: the agent installs `yq`, `crane`, `flux` and `helm` into `~/.openhands/bin`
  on first run; `kubectl` is already there.

Time-windowed instead of run-scoped: automation runs share the pod (and service
account) with interactive Agent Canvas sessions, so Kubernetes cannot distinguish a
cron run from a chat. The window limits exposure to ~3 h a night; a manual dispatch
outside the window fails the pre-flight and does nothing. Truly per-run identities
would need the automation service to run each job in its own sandbox pod.

## Applying

```bash
OPENHANDS_SESSION_API_KEY=... python3 openhands/automations/common/apply.py openhands/automations/orc/h-cloud-upgrader
```

`common/apply.py` reads `automation.json`, renders `prompt.md` with the `vars` block, finds an
existing automation named `h-cloud-upgrader` via `GET /api/automation/v1`, and updates
it (`PATCH`) or creates it (`POST /api/automation/v1/preset/prompt`). `--dry-run`
prints the body. `OPENHANDS_URL` overrides the base URL, default
`http://openhands.ai.svc.cluster.local:8000`.

Trigger a run by hand:

```bash
curl -X POST "$OPENHANDS_URL/api/automation/v1/<id>/dispatch" -H "X-Session-API-Key: $OPENHANDS_SESSION_API_KEY"
```
