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

## How the policy composes

`prompt.md` handles orchestration: reading the event, skip rules, idempotency, fetching
the head commit and the existing review context, posting exactly one COMMENT review,
hard limits. The methodology and the posting format come from two registry skills that
`profiles/common.json` installs from `OpenHands/extensions`, the same pair the registry's
`pr-review` GitHub Action uses: `code-review` (`/codereview`: data structures,
complexity, pragmatism, breaking-change risk, security, testing evidence, dependency
checks, risk assessment, verdict) and `github-pr-review` (`/github-pr-review`: one
review API call, line-anchored comments with 🔴/🟠/🟡 priority labels, suggestion
blocks, no nits). Each review ends with a 👍/👎 feedback footer.

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

## Run budget

`timeout` is 1800 seconds. At 900 the agent-server killed reviews mid-run with
`Command timed out after 900 seconds`, six of twelve runs on 2026-09-19: the review now
fetches the existing threads, downloads the head tarball and reads changed files, and
several pull requests land at once when a branch is pushed repeatedly. The pod's CPU
limit is 2 cores shared by every concurrent run, so three simultaneous reviews each get
a fraction of one.

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
OPENHANDS_SESSION_API_KEY=... python3 openhands/automations/common/apply.py openhands/automations/orc/pr-review
```

`common/apply.py` reads `automation.json`, injects `prompt.md` as the `prompt` field, resolves
`agent_profile` (a stored agent profile name; runs then use that profile's model, MCP
servers and condenser, so the spec carries no `model` of its own) to its id, then looks
for an existing automation named `pr-review` via `GET /api/automation/v1`. It updates it
with `PATCH /api/automation/v1/{id}` when found, otherwise creates it with
`POST /api/automation/v1/preset/prompt`. The service rebuilds the preset tarball itself
whenever the prompt changes, so a re-apply is enough to roll out a policy edit.

`OPENHANDS_URL` overrides the base URL, default
`http://openhands.ai.svc.cluster.local:8000`. `--dry-run` prints the request body without
calling the API, with `agent_profile` shown as the `agent_profile_id` placeholder the
deploy path reads from the API. `--file automation.final.json` applies the
ungated variant once rollout is done.
