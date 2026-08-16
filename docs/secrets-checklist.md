# hermes-hq: Secrets & Environment Checklist

Source of truth: cross-checked against this session's actual live
`~/.hermes/.env` and `~/.hermes/config.yaml` (real running Hermes
instance), plus integrations discussed this session that aren't wired up
yet in this particular sandbox but will be needed once hermes-hq is live.

Delivery mechanism: SOPS-encrypted Kubernetes Secret in `lkshrk/h-cloud`,
injected as plain env vars into the hermes-hq pod - the same pattern
every other app in the cluster uses (openviking, phoenix, litellm-proxy,
vaultwarden itself). Considered and rejected: rbw (pinentry has no
non-interactive unlock path suitable for an unattended pod) and Bitwarden
Secrets Manager via the official `bw` CLI (Vaultwarden does not implement
Secrets Manager - see
https://github.com/dani-garcia/vaultwarden/discussions/3368, open since
2023, unresolved). rbw remains correct for interactive dev hosts
(topaz/coder) - just not this pod.

## Real secrets (must come from an encrypted Kubernetes Secret)

| Env var | Purpose | Source |
|---|---|---|
| `HERMES_CUSTOM_API_AI_H_CLOUD_LAN_API_KEY` | LiteLLM proxy auth - primary + fallback chat model routing | in-cluster LiteLLM proxy |
| `OPENROUTER_API_KEY` | Image generation (`image_gen.provider: openrouter`, `google/gemini-3-pro-image`) - the only current OpenRouter dependency, chat models route through LiteLLM instead | OpenRouter account |
| `SIGNAL_ACCOUNT` | Messaging gateway - registered phone number, sensitive | Signal registration |
| `SIGNAL_ALLOWED_USERS` | Messaging gateway - allowlist | - |
| `SIGNAL_GROUP_ALLOWED_USERS` | Messaging gateway - group allowlist | - |
| `SIGNAL_HOME_CHANNEL` | Messaging gateway - home channel ID | - |
| `SIGNAL_HOME_CHANNEL_NAME` | Messaging gateway - home channel display name | - |
| `GITHUB_TOKEN` (not yet provisioned) | git push/PR ops as a dedicated identity (agent-npa pattern), scoped to `repo`+`workflow` on dotfiles/hermes-hq/h-cloud | dedicated GitHub account, not lkshrk's own |
| `CODER_SESSION_TOKEN` (not yet provisioned) | Create/manage/SSH into hermes-worker-js/py/go Coder workspaces | dedicated `hermes-agent` Coder user |
| `OPENVIKING_API_KEY` (not yet an env var - currently file-based) | Memory backend auth | Already exists at `~/.openviking/ovcli.conf.hermes` in this session (`aGVybWVz...`) - hermes-hq needs its own, or this file mounted/recreated |

## Non-secret config (plain env vars, fine to bake into the Containerfile or HelmRelease `env:` block directly - not a Secret)

| Env var | Value in this session | Notes |
|---|---|---|
| `CAMOFOX_URL` | in-cluster service URL | browser tool backend |
| `SEARXNG_URL` | `http://searxng.ai.svc.cluster.local:8080` | web search backend |
| `SIGNAL_HTTP_URL` | in-cluster `signal-rest-api` service URL | not secret, just an internal endpoint |
| `BROWSERBASE_ADVANCED_STEALTH` | feature flag | only relevant if Browserbase is actually used (currently camofox is the configured `browser.cloud_provider`, so likely unused/removable) |
| `BROWSERBASE_PROXIES` | feature flag | same caveat as above |
| `BROWSER_INACTIVITY_TIMEOUT` | timeout config | |
| `BROWSER_SESSION_TIMEOUT` | timeout config | |
| `TERMINAL_LIFETIME_SECONDS` | timeout config | |
| `TERMINAL_TIMEOUT` | timeout config | |
| `TERMINAL_MODAL_IMAGE` | terminal backend image ref | only relevant if `terminal.backend` uses Modal - current config.yaml has `terminal.backend: local`, so this is likely a leftover/unused in this session and doesn't need to carry over |
| `IMAGE_TOOLS_DEBUG` / `MOA_TOOLS_DEBUG` / `VISION_TOOLS_DEBUG` / `WEB_TOOLS_DEBUG` | debug flags | leave unset (default) unless actively debugging |

## Config (non-.env) that must also be replicated in hermes-hq's `config.yaml`

Not secrets, but required non-default settings for the same runtime behavior as this session - see `~/.hermes/config.yaml` for the full file:

- `providers.litellm` / `providers.litellm-anthropic` blocks (both point at `http://litellm-proxy.ai.svc.cluster.local:4000`, differ by transport)
- `model.default: gpt-5.6-terra`, `model.provider: custom:litellm`
- `fallback.model: claude-sonnet-5`, `fallback.provider: custom:litellm-anthropic`
- `image_gen.provider: openrouter`, `image_gen.model: google/gemini-3-pro-image`
- `memory.provider: openviking`, `memory.openviking.use_ovcli_config: true` (needs its own `ovcli.conf.hermes` file, not just an env var - see OPENVIKING_API_KEY row above)
- `web.backend: searxng`
- `browser.cloud_provider: camofox`
- `platform_toolsets` block (per-platform tool restrictions - copy as-is unless deliberately changing hermes-hq's capability surface)

## Known gaps / not yet resolved this session

- `GITHUB_TOKEN`, `CODER_SESSION_TOKEN`, and a hermes-hq-specific OpenViking credential are referenced above as needed but **none have been provisioned yet** - they require, respectively: a dedicated GitHub identity + collaborator access (blocked - `agent-npa` currently lacks collaborator status on `lkshrk/dotfiles`), a dedicated Coder user + token (not yet created), and either reusing or minting a separate OpenViking actor/API key for the hermes-hq instance specifically (using this session's own key for a second running instance may not be appropriate - worth deciding explicitly rather than defaulting to it).
- This checklist has NOT been cross-referenced against hermes-workspace's own `.env.example` requirements (`HERMES_API_TOKEN`, `HERMES_PASSWORD`, etc.) - those apply to the separate hermes-workspace UI deployment, not this pod, and are out of scope here since you're handling that HelmRelease yourself.
- No dotfiles module has been created yet to keep this checklist and the real Omni `hermes` host profile in sync over time - currently this is a standalone doc, not enforced anywhere.
