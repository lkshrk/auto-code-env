# Architecture: devbox

One reproducible dev image family, many launchers.

Tools are baked into the image under `/opt/devbox`. Dotfiles and
environment are synced at every start, never baked. The same image runs a
Coder workspace, a long-running agent pod, a headless one-shot job, and a
local container on a laptop — all through one entrypoint, `devbox-init`.

Phase 1 is additive: the devbox images, the `devbox` Coder template and the
local launcher ship **next to** the existing hermes-hq image and the
`hermes-worker-*` templates. Nothing is repointed or removed until phase 2.

## Image family

One Containerfile (`image/Containerfile.devbox`), multi-stage.
`docker-bake.hcl` turns it into seven published variants, one GHCR package
each, published as `ghcr.io/lkshrk/devbox/<variant>:<calver>` (+ `:latest`).

| tag             | layers                                                        |
|-----------------|---------------------------------------------------------------|
| `devbox/go`     | base, omni, core, ai, stack(go)                               |
| `devbox/python` | base, omni, core, ai, stack(python)                           |
| `devbox/ts`     | base, omni, core, ai, stack(ts), browser                      |
| `devbox/lua`    | base, omni, core, ai, stack(lua)                              |
| `devbox/full`   | base, omni, core, ai, stack(go python ts lua), browser, infra |
| `devbox/hermes` | full + agent(hermes)                                          |
| `devbox/pilot`  | full + agent(pilot)                                           |

Tags are pure calver, so Renovate and Flux image policies need no custom
regex. Every image carries `org.opencontainers.image.source` pointing at
this repo — that is what makes each GHCR package inherit public visibility,
which is required: private GHCR on the free tier caps at 500 MB.

Adding a language is a new omni group plus one matrix entry in
`docker-bake.hcl`.

## Layers, ordered by change frequency

| layer group | built as                     | content                            |
|-------------|------------------------------|------------------------------------|
| `base`      | stage `base`                 | `debian:trixie-slim`, user `dev` uid/gid 1000, sudo NOPASSWD, apt prereqs, dpkg doc/man exclusions |
| `omni`      | stage `omni`                 | omni binary, dotfiles clone pinned to `DOTFILES_COMMIT` into `/opt/devbox/dotfiles` (build-time config source only) |
| `core`      | stage `core`                 | `omni tools sync core dev dev-tooling shell prereqs test-tooling` |
| `ai`        | stage `ai`                   | bun (the JS runtime for codex and claude) + `omni tools sync ai ai-plugins` |
| `stack`     | stages `stack-go` … `stack-full` | `omni tools sync <language group>`, one `RUN` per group |
| `browser`   | `RUN` in `stack-ts`, `stack-full` | apt libs for headless chromium/firefox (`playwright install-deps`) |
| `infra`     | `RUN` in `stack-full`        | `omni tools sync infra` (k8s/gitops CLIs) |
| `agent`     | stages `stack-hermes`, `stack-pilot` | `omni tools sync agent-hermes` or `agent-pilot` |
| `runtime`   | stage `runtime`              | `devbox-init`, `/etc/profile.d/devbox.sh`, `ENV`, OCI labels, entrypoint |

Only the "built as" column names real `FROM` stages. `browser` and `infra`
are not stages of their own — they are `RUN` layers folded into the stack
stages that need them, so they cost nothing in the variants that do not.

The order is by change frequency, not by dependency alone. The shared
prefix `base -> omni -> core -> ai` is identical for every variant, so it is
built once and every subsequent variant hits cache. What changes most often
(language groups, agent tools) sits furthest from the base, so a dotfiles
tool bump rebuilds one leaf rather than the whole graph.

`full` runs each language group in its own `RUN`, so a change to the `ts`
group does not invalidate the `go`, `python` and `lua` layers below it.
Per-language variants have a different parent than `full` and therefore
rebuild their own stack layer; BuildKit cache mounts keep that cheap and
bake runs the seven targets in parallel.

Every layer is a `COPY image/scripts/NN-name.sh` + `RUN`. No apt lists or
install logic inline in the Containerfile — the rationale lives here, not
in Containerfile comments.

Variant selection is a single build arg. `ARG VARIANT=full` is declared
before the first `FROM`, the leaf stages are named `stack-go`,
`stack-python`, ... `stack-pilot`, and the runtime stage starts
`FROM stack-${VARIANT}`. One Containerfile, seven graphs.

## Install layout: `HOME=/opt/devbox` at build time

Coder mounts a PVC over `/home/dev`, so nothing baked into the image may
live in home — it would be masked the moment a workspace starts.

Dotfiles' script providers hardcode `$HOME` (`~/.local/bin`, `~/.bun`,
`~/.hermes`, `~/.local/share/uv`), so redirecting each provider
individually is fragile and breaks whenever dotfiles adds one. Instead
every tool stage runs with **`HOME=/opt/devbox`**, and the installers write
under `/opt/devbox/{.local,.bun,.hermes,.cargo,go,.nvm,...}` unmodified.
The build-time dotfiles clone lives at `/opt/devbox/dotfiles` and is used
only as the omni config source (`OMNI_CONFIG`).

`50-finalize.sh` then symlinks `node npm npx corepack` from the newest nvm
node into `/opt/devbox/.local/bin` (the same links dotfiles' own
`sync_nvm_local_bin_links` makes), strips caches, and chowns the tree to
`root:root` mode `u=rwX,go=rX`.

At runtime `HOME=/home/dev` and `/opt/devbox` is root-owned and read-only
for `dev`.

### PATH and the shadowing rule

`PATH` is set both as image `ENV` (for non-login shells and `command`-style
pod entries) and in `/etc/profile.d/devbox.sh` (for login shells):

```
$HOME/.local/bin:$HOME/.bun/bin:$HOME/go/bin:$HOME/.cargo/bin:
/opt/devbox/.local/bin:/opt/devbox/.bun/bin:/opt/devbox/go/bin:/opt/devbox/.cargo/bin:
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

Home comes first, deliberately. `omni tools install x`, `bun i -g`,
`uv tool install`, `go install` inside a running box land in `$HOME` exactly
as they do on a laptop, shadow the image copy, survive restarts on a PVC,
and vanish with the container when there is no volume.

The cost is that an image bump does **not** override a shadowing home copy:
a tool installed into home once keeps winning forever. `devbox-init`
therefore scans the four home bin dirs at every start and prints one
warning line per binary that shadows an image copy. It warns; it never
deletes. Removing the home copy is the user's call.

Home-rooted cache environment is set in `/etc/profile.d/devbox.sh` for all
runs, so caches land on the PVC and stay on the same device as the tools
that hardlink into them:

```
TMPDIR=$HOME/.tmp  XDG_CACHE_HOME=$HOME/.cache  XDG_DATA_HOME=$HOME/.local/share
UV_CACHE_DIR, npm_config_store_dir, pnpm_config_store_dir,
BUN_INSTALL_CACHE_DIR, GOPATH, GOCACHE, GOMODCACHE  -> under $HOME
```

## `devbox-init` (runtime entrypoint)

Every launcher goes through this one script. There is no second copy of
bootstrap logic in a Coder startup script, a pod `command`, or the local
wrapper.

```
devbox-init [cmd...]
  1. mkdir -p $HOME/.tmp $HOME/.ssh (0700); ssh-keyscan github.com, codeberg.org
  2. materialise file-shaped secrets: CODEX_AUTH_JSON -> ~/.codex/auth.json (0600)
  3. $HOME/dotfiles: clone if missing, otherwise git fetch
     (never merge or reset — the checkout belongs to the user)
  4. unless DEVBOX_DOTS=0: omni --yes dots sync --use-repo
  5. shadow-warning scan over the four home bin dirs
  6. exec "${@:-sleep infinity}"
```

| env                    | default                                    | effect                            |
|------------------------|--------------------------------------------|-----------------------------------|
| `DEVBOX_DOTFILES_URL`  | `https://github.com/lkshrk/dotfiles.git`   | repo cloned/fetched into `~/dotfiles` |
| `DEVBOX_DOTS`          | `1`                                        | `0` skips the dots sync (agent pods) |
| `DEVBOX_OPT`           | `/opt/devbox`                              | root of the baked tree, for the shadow scan |
| `OMNI_HOSTNAME`        | `devbox` (image `ENV`)                     | selects the omni host group        |
| `DEVBOX_VARIANT`       | set by the build                           | which variant is running           |

Step 3 fetches but never merges: a workspace that has local dotfiles
commits keeps them, and a failed fetch is a warning, not a failed start.
`~/dotfiles` existing as a non-git path is a hard error — it means something
else owns that name.

## Launchers

### Coder

One template, `coder/devbox/`, replacing h-cloud's per-stack templates in
phase 2. Per-project content is `coder_workspace_preset` blocks (repos,
deployment URL, dind, playwright, access profile, sizing), not separate
templates.

The access profile (`base`, `civora`, `routivo`, `pub`) picks the service
account (`coder-workspace` / `coder-workspace-<access>`) and the namespace.
It is a preset value, not derived from the template name, and it is
immutable after creation.

The startup script does only Coder-specific work — write a kubeconfig from
the mounted service-account token, then:

```sh
export DEVBOX_DOTFILES_URL="<dotfiles_url parameter>"
devbox-init true
bash "$HOME/dotfiles/setup-coder.sh"
```

No apt, no `omni tools sync`, no playwright install at start. Repos are
cloned by Coder's git-clone module.

The image is `ghcr.io/lkshrk/devbox/<variant>:<image_version>`, with
`image_version` pinned once in `coder/devbox/main.tf`. It currently reads
`latest` as an interim value — no devbox calver has been published yet.
The first published calver gets pinned there at phase-1 acceptance, before
any workspace is created; from then on Renovate bumps it
(`datasource=github-tags`, this repo cuts tags rather than Releases).

Delivery: Coder has no pull/GitOps mode, so templates are pushed.
`.github/workflows/coder-templates.yaml` runs, on `main`:

```sh
coder templates push devbox --directory coder/devbox \
  --name <short sha>-<run number>-<run attempt> \
  --message "<commit subject>" --yes
```

`--activate` (the default) makes it the active version. Every workspace on
an older version shows Coder's "Update available" banner and is marked
outdated in `coder list`; users update on their own schedule and
`require_active_version` stays off. So an image bump is a template change,
and the chain is: release -> Renovate PR here -> merge -> push -> banner.
The `variant` parameter options stay stable so an update never forces a
re-prompt. PRs run `terraform fmt -check` and `validate` only.

The template name `devbox` collides with nothing in h-cloud, so both sets
coexist in the same Coder deployment through phase 1.

The `coderd` Terraform provider was considered and rejected: it needs
remote state and buys nothing over the CLI.

### Agent pods (h-cloud, phase 2)

Hermes hub and Pilot become Deployments/StatefulSets in h-cloud with
`image: ghcr.io/lkshrk/devbox/hermes:<calver>` or `devbox/pilot:<calver>`,
an explicit `command` (`hermes gateway run`, `pilot start ...`),
`DEVBOX_DOTS=0`, and secrets by env from SOPS as today. Pilot shims (the
`gh` wrapper, notify/retry helpers) ship in the image. Image bumps ride the
existing `repository_dispatch` to h-cloud's `update-image.yml`.

### Headless / local

`scripts/devbox` wraps docker or podman (`DEVBOX_RUNTIME`, default
`docker`):

```
devbox up NAME [--image VARIANT] [-v HOST:CTR]... [-w DIR]
devbox sh NAME
devbox run [--image VARIANT] [-v HOST:CTR]... [-w DIR] -- CMD...
devbox stop NAME | rm NAME | ls
```

`up` runs detached as `devbox-NAME` with a named volume `devbox-NAME-home`
mounted at `/home/dev`, so tools installed into home survive restarts.
`sh` is `exec -it devbox-NAME zsh -l`. `run` is `--rm -it`. `rm` prompts
before deleting the container and its home volume.

Every command that starts a container passes `--env-file` and, when an
ssh-agent is available, mounts the agent socket (`/run/host-services/ssh-auth.sock`
on Docker Desktop, `$SSH_AUTH_SOCK` elsewhere) rather than any key.

k8s one-shot, no manifest file needed:

```sh
kubectl run devbox-oneshot --rm -it --restart=Never \
  --image=ghcr.io/lkshrk/devbox/full:latest \
  --overrides='{"spec":{"containers":[{"name":"devbox-oneshot","image":"ghcr.io/lkshrk/devbox/full:latest","stdin":true,"tty":true,"args":["claude","-p","..."],"envFrom":[{"secretRef":{"name":"coder-workspace-secrets"}}]}]}}'
```

The `--overrides` block is not optional decoration: `kubectl run` has no
`--env-from` flag, so without it the pod starts with no credentials at all.
`--overrides` is a JSON *merge* patch, which replaces the whole `containers`
list, so name, image, `stdin` and `tty` have to be repeated inside it.

`--restart=Never` is likewise load-bearing: `kubectl run` still defaults to
`Always`, which would restart the one-shot forever once the command exits.

`args` is the command, not a trailing `-- ...`: the image `ENTRYPOINT` is
already `devbox-init`, so `args` become its argv and it runs `claude -p "..."`
after the bootstrap. Passing the command after `--` as well would name
`devbox-init` twice.

## Secrets

The contract is identical for every launcher: **the image contains no
secrets and reads them only from the environment at start.**

The build needs no secrets for its sources — all public. It accepts one
optional build secret, `GITHUB_TOKEN`, purely to raise the GitHub API rate
limit (see quirks below); it is a BuildKit `--mount=type=secret`, never a
build arg or `ENV`, so it never lands in a layer.

Env consumed by tools directly:

| env                                                                   | consumer                       |
|-----------------------------------------------------------------------|--------------------------------|
| `GH_TOKEN` (+ `GITHUB_TOKEN`, `GITHUB_PERSONAL_ACCESS_TOKEN` aliases)  | gh, generic tools, github-mcp  |
| `CLAUDE_CODE_OAUTH_TOKEN`                                              | claude                         |
| `CODEX_AUTH_JSON`                                                      | codex (file-shaped, see below) |
| `LITELLM_API`                                                          | in-cluster LLM proxy           |

`devbox-init` materialises file-shaped secrets from env and nothing else:
`CODEX_AUTH_JSON` becomes `~/.codex/auth.json` at 0600. It never prints env.
Tool-side credential caches (`~/.claude`, `~/.config/gh`) live in home and
therefore persist per workspace or volume, never in the image.

Per launcher:

| launcher       | mechanism                                                                                      |
|----------------|------------------------------------------------------------------------------------------------|
| Coder          | `envFrom` secret `coder-workspace-secrets` (optional) plus `<access>-workspace-env` (optional), both in h-cloud SOPS; git over SSH via Coder's per-user key and `GIT_SSH_COMMAND`; kube access via the mounted service-account token |
| Agent pods     | SOPS Secret -> env, as the hub does today. Hermes keeps its existing key list (`docs/secrets-checklist.md`); pilot gets its GitHub App key and Signal config the same way |
| Local          | `--env-file ~/.config/devbox/env` (0600, enforced by the wrapper; template `scripts/devbox.env.example`) and the host ssh-agent socket instead of keys. Never `-e` on the command line — that lands in shell history |
| k8s one-shot   | `envFrom` the same `coder-workspace-secrets`                                                     |

Public-image guard: the `devbox` omni host excludes the `priv` group;
`validate.yaml` runs gitleaks over the repo and greps each built variant for
token patterns under `/opt/devbox` and `/etc`.

## Image size

Target: language variants under 2 GB, `full` under 3 GB. Levers, in the
order they are worth applying:

1. **BuildKit cache mounts** on every tool stage (`/opt/devbox/.cache`,
   uid/gid 1000) so download caches never land in a layer.
2. **dpkg `path-exclude`** for `/usr/share/{doc,man,info,locale}`, written
   in `10-base.sh` before the first `apt-get install` so it applies to
   everything.
3. **No `build-essential`.** Measured on the predecessor image: dropping it
   and its friends took `/usr` from 435 MB to 200 MB. Consequence: no C
   toolchain, so cargo-provider tools cannot build from source — see quirks.
4. **Heavy, narrowly used groups** (`browser`, `infra`, `agent`) enter only
   the variants that need them, per the matrix above.
5. **`50-finalize.sh` cleanup**: `.cache`, `.npm`, bun install cache, go mod
   download cache, `.tmp`, `*.pyc`.
6. **zstd push** (`compression=zstd,force-compression=true` in
   `docker-bake.hcl`).
7. **Group exclusion**: the `devbox` omni host never includes `desk`,
   `gaming`, `mac`, `priv`, `utils`, `omni`. `core` — including neovim and
   tmux — is in.

Rejected: `--squash` (kills layer caching) and an Alpine base (musl breaks
too many prebuilt toolchains).

## Known tool quirks

These are the behaviours that cost real debugging time and would otherwise
be rediscovered. Sizes and smoke-derived findings are marked where they are
still unverified; this section is amended once a full matrix build lands.

**omni `tools sync` takes one group, not many.** The CLI signature is
`omni tools sync [group]`, singular. Passing several groups silently syncs
the first and skips the rest — no error. `30-tools.sh` therefore loops.

**Unauthenticated GitHub API exhausts mid-build.** 60 requests/hour, and
many omni `script` providers do a release lookup each, so a cold build hits
`HTTP 403 ... X-RateLimit-Remaining=0` partway through. Builds accept an
optional `GITHUB_TOKEN` through a buildx secret. The guard tests the mount
for *non-empty* (`-s`, not `-r`): buildx mounts an empty file when the env
var is unset, and exporting an empty `GITHUB_TOKEN` makes omni send an empty
bearer token and get 401s — worse than sending none. Unset, the build still
works; it just re-exposes the 60/hour ceiling.

**omni needs a writable config directory.** It writes a backup and
`.omni-config.lock` *into* the config dir, so `/opt/devbox/dotfiles` must be
writable by `dev` during the build. It is — the clone is user-owned — but a
hardened read-only config tree fails with
`open ...omni-config.lock: read-only file system`.

**omni config schema v24.** omni v0.9.37+ rejects v22 configs outright
(`config field "$.agents" was removed in v24`). Under v24 the `agents`
block is gone and packages, skills, MCP servers, plugins and marketplaces
move out of omni groups into APM (`~/.apm/apm.yml`). The devbox image does
not provision APM, so those are **not** installed in phase 1 — accepted
deliberately; the tools themselves are unaffected.

**A malformed apt repo definition poisons the whole stage.** A
`sources_format` in deb822 syntax written to a `.list` file breaks *every*
subsequent apt operation in that stage, with an error naming an unrelated
tool:

```
E: Type 'Types:' is not known on line 1 in source list /etc/apt/sources.list.d/omni-docker.list
```

`.list` requires the one-line format. This bit `docker` in dotfiles
(fixed there); when an apt-provider tool fails for no visible reason, check
`/etc/apt/sources.list.d/` first.

**`pnpm` is in omni's global ignore list** and is provisioned at image level
via corepack instead. Do not expect `omni tools sync ts` to supply it.

**`lua` tools need explicit Linux providers.** Every tool in the group
originally resolved to `brew` only, which is disabled on the devbox host, so
all five were skipped with `provider unavailable: brew`. Linux providers are
now declared in dotfiles.

**No C toolchain, so no cargo-built tools.** `deepwiki-rs` and
`herdr-tether` fail with `error: linker 'cc' not found`. Adding
`gcc libc6-dev make` fixes them and costs roughly 235 MB of `/usr` in
*every* variant; the decision went the other way and both tools are dropped
from the devbox path. Revisit only if either becomes essential.

**`rbw` is not in trixie's apt repos** and installs from the upstream signed
`.deb` rather than being built from source.

**Build on native amd64.** Images target `linux/amd64`. Under qemu on an
arm64 host the cargo compiles run for minutes and then OOM-kill on a typical
Docker Desktop VM, and a full seven-variant bake far exceeds a ten-minute
budget. CI builds these on a native runner.

**Tools that only work with `HOME=/opt/devbox`:** still unknown. Detecting
them requires the smoke test's foreign-`HOME` checks against a built image
(`hermes` and `pilot` are the suspects — a launcher resolving its install
dir from `$HOME` instead of `HERMES_HOME`).
