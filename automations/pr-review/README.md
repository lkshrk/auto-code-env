# pr-review automation

Central OpenHands automation that reviews pull requests across every repository the
`renovate-master` GitHub App is installed on (owners `lkshrk`, `webdev-harke`,
`routivo`, `loc-news`). GitHub `pull_request` and `issue_comment` deliveries reach the
Agent Canvas automation service through the webhook bridge; each matching event starts
one run that posts at most one review.

| File | Purpose |
|---|---|
| `prompt.md` | The review policy the agent executes. Read on every run. |
| `automation.json` | Request body for the API. Rollout variant, gated on a label. |
| `automation.final.json` | Same, without the label gate. Every PR is reviewed. |
| `apply.py` | Creates or updates the automation. Stdlib only. |

## How the policy composes

`prompt.md` handles orchestration: reading the event, skip rules, idempotency, fetching
the head commit, posting exactly one COMMENT review, hard limits. The review
methodology itself comes from OpenHands' bundled `code-review` skill (`/codereview`):
data structures, complexity, pragmatism, breaking-change risk, security, testing
evidence, dependency checks, risk assessment, verdict.

A repository overrides the reviewer by committing
`.agents/skills/custom-codereview-guide.md` on the branch under review. That is the
skill's own override contract, so it works with any OpenHands reviewer, and the skill
loads it automatically when the frontmatter carries the `/codereview` trigger:

```markdown
---
name: custom-codereview-guide
description: Repository-specific review guidance
triggers: [/codereview]
enabled: true
---

Review only the Go packages under `internal/`. Reply in German.
Security findings about the admin API do not apply: it is LAN-only behind Authentik.
Flag any new dependency that is not already in `go.mod`.
```

`enabled: false` disables reviews for that repository entirely. An override can narrow
or focus the review; it can never lift a hard limit (no pushes, no merges, no approvals,
never leak the token). `AGENTS.md` at the repo root is read as well, and the PR is held
to the conventions it states.

## Triggers and opt-outs

- Automatic on `pull_request` `opened`, `synchronize`, `ready_for_review` and `reopened`.
- On demand by commenting `@openhands review` on a pull request. This forces a fresh
  review even when the head SHA was already reviewed, and it is the only way to review a
  draft PR or a bot-authored one such as a Renovate update.
- Label `no-ai-review` on the PR suppresses all reviews.
- During rollout the automation only fires for PRs labelled `openhands-review`.

Reviews are posted as `lkshrk` with `event: COMMENT`. The automation never approves,
never requests changes and never merges; a human decides the verdict. Each review body
ends with `<!-- openhands-review sha=<head_sha> -->`, which is how the next run knows
that SHA was already reviewed.

## Applying

```bash
OPENHANDS_SESSION_API_KEY=... python3 automations/pr-review/apply.py
```

`apply.py` reads `automation.json`, injects `prompt.md` as the `prompt` field, then looks
for an existing automation named `pr-review` via `GET /api/automation/v1`. It updates it
with `PATCH /api/automation/v1/{id}` when found, otherwise creates it with
`POST /api/automation/v1/preset/prompt`. The service rebuilds the preset tarball itself
whenever the prompt changes, so a re-apply is enough to roll out a policy edit.

`OPENHANDS_URL` overrides the base URL, default
`http://openhands.ai.svc.cluster.local:8000`. `--dry-run` prints the request body without
calling the API. `--file automations/pr-review/automation.final.json` applies the
ungated variant once rollout is done.
