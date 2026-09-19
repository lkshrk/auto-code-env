# linear-triage automation

Triages newly created Linear issues in the Routivo and Civora teams: one comment, labels
from the team's existing vocabulary, and a priority when none is set.

| File | Purpose |
|---|---|
| `prompt.md` | The triage policy the agent executes. Read on every run. |
| `automation.json` | Request body for the API. Event trigger, filtered to the two teams. |

## Delivery path

Linear posts to a custom webhook registered on the automation service with
`source: linear`, `signature_header: Linear-Signature` and `event_key_expr: type`. Linear
generates the signing secret; OpenHands stores it and verifies every delivery itself. An
unsigned or wrongly signed body is rejected with 401 before any automation matches.

Linear is external and the agent server has no public ingress, so h-cloud publishes that
one exact path on `envoy-external` (`kubernetes/apps/ai/openhands/app/httproute-webhooks.yaml`).
The match is exact rather than a prefix, so the `github` source stays reachable only from
the in-cluster bridge.

## Trigger

`event_key_expr: type` makes Linear's `type` field the event key, so `on: ["Issue"]`
matches issue deliveries. The `filter` narrows further, and is evaluated against the
payload root: `action == 'create'` plus the two team ids. Verified against a probe
webhook: `create` in Routivo matched, `update` in Routivo did not, `create` in another
team did not. Everything else in the workspace costs one HTTP 200 and starts nothing.

The payload reaches the agent as an `## Event Payload` section prepended to the prompt,
shaped `{"payload": <raw Linear body>, "source_override": ..., "event_key": ...}`. Custom
sources get no `AUTOMATION_EVENT_PAYLOAD` environment variable; the builtin GitHub source
is what sets that.

## Applying

```bash
OPENHANDS_SESSION_API_KEY=... python3 openhands/automations/common/apply.py openhands/automations/orc/linear-triage
```

`agent_profile: triage` is resolved to that profile's id at deploy. An automation
without a profile runs with the settings-level MCP set and dies on `MCPTimeoutError`
after 30 seconds.

The `triage` agent profile exists to scope the tools, not the model. It keeps
`anthropic-auto`, so the router still reaches Opus when it judges the issue complex, and
carries only `litellm-tools` (the Linear tools) with sub-agents and the switch-LLM tool
off, none of which a classification task uses. The first run on `default` cost $10.56
over eight calls and 1,049,800 prompt tokens, most of it tool schemas and history rather
than the issue itself.

`apply-profile.py` propagates `agent.system_message_suffix` into every stored openhands
profile but does not create profiles, so `triage` was created through
`POST /api/agent-profiles/triage` and lives only on the backend.
