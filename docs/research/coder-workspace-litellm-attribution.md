# Attributing LLM usage to a Coder workspace/task

Goal: given LiteLLM spend/usage data, find out which Coder workspace,
repository and task it came from — for cost/usage visibility only, not
billing enforcement.

## The mechanism already exists; nothing to build

**1. Every LLM call already carries the conversation ID as a LiteLLM session.**

The OpenHands SDK (`openhands.sdk.conversation.impl.local_conversation`)
builds an `LLMCallContext` per conversation where `session_id` is *always*
the conversation's own ID (`get_llm_call_context`). That gets turned into a
request header in `openhands.sdk.llm.options.common`:

```python
if ctx.session_id:
    out["extra_headers"] = {**existing, "x-litellm-session-id": ctx.session_id}
```

This happens unconditionally, on every completion call, for every profile —
no configuration or opt-in needed.

**2. LiteLLM already records that session on the proxy side.**

h-cloud's `litellm-proxy` HelmRelease (`kubernetes/apps/ai/litellm-proxy/app/helmrelease.yaml`)
runs `ghcr.io/berriai/litellm-database:v1.101.0` (Postgres-backed) with:

```yaml
general_settings:
  store_model_in_db: true
  store_prompts_in_spend_logs: true
```

LiteLLM natively groups spend logs by the `x-litellm-session-id` header into
its `LiteLLM_SpendLogs.session_id` column and its own "Sessions" view/API
(`GET /spend/logs`, filterable by session id). This is a built-in LiteLLM
feature, not something h-cloud added.

**3. `binding.json` (see `openhands/skills/coder-workspaces/SKILL.md`) gives
`conversation_id → workspace/repo/task`.**

## How to attribute spend to a workspace

Attribution is a **join at query time**, not a pipeline to build:

```
LiteLLM_SpendLogs.session_id  ==  binding.json[*].conversation_id
```

In practice:

1. Pick a conversation ID (from a workspace's `binding.json`, or from
   OpenHands conversation metadata).
2. Query LiteLLM for that session's spend/usage, e.g.:
   `GET {PROXY_BASE_URL}/spend/logs?request_id=<conversation_id>` or, if
   querying Postgres directly, `SELECT * FROM "LiteLLM_SpendLogs" WHERE
   session_id = '<conversation_id>'`. Confirm the exact query param name
   against the deployed LiteLLM version's `/spend/logs` docs before relying
   on it, since LiteLLM has renamed spend-log filters across releases.
3. Cross-reference the workspace/repo/task fields already recorded in that
   `binding.json` entry.

## What is NOT done here (deliberately out of scope)

- No new credential issuer, proxy header, or SDK/agent-server code change.
- No live end-to-end smoke test was run against the production LiteLLM
  proxy from this task — the above is based on reading the SDK and h-cloud
  proxy config, not on an observed spend-log row. If you want that
  verified live, someone with the LiteLLM master key/API access needs to
  run steps 1–2 above.
- No billing/chargeback logic. This is usage/cost *visibility* only.
