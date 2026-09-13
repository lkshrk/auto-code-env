# LLM profiles

A backup of the LLM profiles a running Agent Canvas backend serves at
`/api/profiles`. They are not settings profiles: `../profiles` describes a whole
backend and is applied by `apply-profile.py`, while each file here is one entry
in the model picker, named by its file name.

The backend stores them at `~/.openhands/profiles/<name>.json` and names the
active one in `~/.openhands/settings.json`. Nothing here is a secret —
`api_key` is stripped and `provider_connection_id` only points at a connection
the backend already holds.

## Restoring one

```sh
curl -s -X POST "$BACKEND/api/profiles/<name>" \
  -H "X-Session-API-Key: $OH_SESSION_API_KEYS_0" \
  -H 'Content-Type: application/json' \
  -d "$(jq '{llm: .}' <name>.json)"
```

Read the current set back with `GET /api/profiles`, and one profile's full
config with `GET /api/profiles/<name>` (the body is under `.config`).

## What the profiles point at

Every profile targets the LiteLLM gateway. `claude-*` and `gpt-*` name one
model; the `*-auto` profiles name a router that picks per request:

| profile | routes to |
| --- | --- |
| `frontier-auto` | failover ladder, best model first, degrading on failure |
| `anthropic-auto` | complexity router across the Claude tiers |
| `openai-auto` | complexity router across the GPT-5.6 and GPT-6 tiers |
| `smart-auto` | complexity router across both vendors, cheapest adequate tier |

`reasoning_effort` is `high` on every profile, and the backend forces that
default even when a create request sends null. A caller-sent `reasoning_effort`
overrides what the gateway's deployment sets, so a router tier that differs from
its neighbour only by reasoning effort collapses into it for traffic from here.

`input_cost_per_token` and `output_cost_per_token` are display values for this
backend; the gateway prices every request itself from LiteLLM's cost map. On a
router they are set to its most expensive tier, so the estimate shown here is an
upper bound rather than what the request actually costs.
