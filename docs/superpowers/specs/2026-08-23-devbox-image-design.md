# devbox: one reproducible dev image, many launchers

Date: 2026-08-23
Status: draft, awaiting review

## Goal

Target state: the Hermes-only control-hub image and the ten per-project
Coder templates in h-cloud are replaced by **one image family** (`ghcr.io/lkshrk/devbox:<variant>`)
built from one Containerfile, published as
`ghcr.io/lkshrk/devbox/<variant>:<calver>` (+ `:latest`), and a small set
of launchers that run it:

- Coder workspaces (human, interactive, create/pause/delete on demand)
- long-running agent pods (Hermes gateway, Pilot)
- headless one-shot runs (`claude -p`, `codex exec`) in k8s Jobs or locally
- personal local containers on a laptop

Tools are baked into the image. Dotfiles/env are synced at every start.

Rollout is additive first: phase 1 ships the images, a new `devbox` Coder
template and the local launcher **next to** everything that exists today;
nothing in h-cloud is removed or repointed. Phase 2 switches consumers and
deletes the old parts after the new ones are proven. See "Rollout".

## Non-goals

- Arbitrary stack combinations. Only the variants listed below are published.
- Hardened "no AI tools" hub image. Hermes and Pilot get claude/codex too.
- Owning Kubernetes manifests, secrets, or RBAC. Those stay in h-cloud.
- Replacing Coder. Coder stays the cluster workspace lifecycle manager.

## Image family

One `image/Containerfile`, multi-stage. `docker-bake.hcl` turns it into
eight published variants:

| tag               | stages                                              |
|-------------------|-----------------------------------------------------|
| `devbox:go`       | base, omni, core, ai, stack(go)                     |
| `devbox:python`   | base, omni, core, ai, stack(python)                 |
| `devbox:ts`       | base, omni, core, ai, stack(ts), browser            |
| `devbox:lua`      | base, omni, core, ai, stack(lua)                    |
| `devbox:full`     | base, omni, core, ai, stack(go python ts lua), browser, infra |
| `devbox:hermes`   | full + agent(hermes)                                |
| `devbox:pilot`    | full + agent(pilot)                                 |

Stages, ordered so the shared prefix `base -> omni -> core -> ai` is built
once and cached for every variant:

| stage     | content                                                        |
|-----------|----------------------------------------------------------------|
| `base`    | `debian:trixie-slim`, user `dev` uid/gid 1000, sudo NOPASSWD, apt prereqs from dotfiles' `scripts/setup-workspace-linux.sh` |
| `omni`    | omni binary (dotfiles `scripts/install-omni-latest.sh`), dotfiles clone at pinned commit into `/opt/devbox/dotfiles` (build-time config source) |
| `core`    | `omni tools sync core dev dev-tooling shell prereqs test-tooling` |
| `ai`      | bun (JS runtime for codex/claude) + `omni tools sync ai ai-plugins` |
| `stack`   | `ARG STACKS` -> `omni tools sync $STACKS`; one RUN per group so `full` caches per language |
| `browser` | apt libs for headless chromium/firefox (`playwright install-deps`), shared by project Playwright, shiplight and camofox |
| `infra`   | `omni tools sync infra` (k8s/gitops CLIs)                      |
| `agent`   | `ARG AGENT` -> `omni tools sync agent-$AGENT` (hermes+camofox, or pilot+shims) |
| `runtime` | `devbox-init`, `/etc/profile.d/devbox.sh`, OCI labels, entrypoint; applied to every variant |

Rules:

- Each stage is `COPY image/scripts/NN-name.sh` + `RUN`. No apt lists or
  install logic inline. Rationale lives in `docs/architecture.md`, not
  in Containerfile comments.
- Tool groups come from dotfiles `omni/.config/omni/settings.json`: a
  `devbox` host (core groups + ai + all stacks + infra) plus groups
  `agent-hermes` (hermes, camofox-browser) and `agent-pilot` (pilot,
  pilot shims). Pilot is added to `tools.json`.
- `docker-bake.hcl` holds the variant matrix, shared args
  (`DOTFILES_REF`, `DOTFILES_COMMIT`), tags and labels. Adding a language
  = new omni group + one matrix entry.
- Per-language variants rebuild their own `stack` layer (different parent
  than `full`); cache mounts keep that cheap and bake runs them in parallel.

### Install layout: `/opt/devbox`

Coder mounts a PVC over `/home/dev`, so nothing baked may live in home.

Dotfiles' script providers hardcode `$HOME` (`~/.local/bin`, `~/.bun`,
`~/.hermes`, `~/.local/share/uv`), so redirecting per provider is
fragile. Instead every tool stage runs with **`HOME=/opt/devbox`**; the
installers then write under `/opt/devbox/{.local,.bun,.hermes,.cargo,go,
.nvm,...}` unmodified. Build-time dotfiles clone lives at
`/opt/devbox/dotfiles` (omni config source only).

At runtime `HOME=/home/dev`. `/opt/devbox` is root-owned, read-only for
`dev`. `PATH` (via `/etc/profile.d/devbox.sh`, also set as image `ENV`):

```
~/.local/bin:~/.bun/bin:~/go/bin:~/.cargo/bin:
/opt/devbox/.local/bin:/opt/devbox/.bun/bin:/opt/devbox/go/bin:/opt/devbox/.cargo/bin:
/usr/local/bin:/usr/bin:/bin
```

Node comes from nvm; the build symlinks `node npm npx corepack` into
`/opt/devbox/.local/bin` (same as dotfiles' `sync_nvm_local_bin_links`).

Consequences:

- `omni tools install x`, `bun i -g`, `uv tool install`, `go install`
  inside a running box land in `$HOME` as today, shadow the image copy,
  survive restarts on a PVC, vanish without one.
- An image bump does not override a shadowing home copy. `devbox-init`
  prints one warning line per shadowed binary whose home version is older.

Home-rooted cache env (from the old pilot image, same-device hardlink
reason) is set in the image for all runs:

```
TMPDIR=$HOME/.tmp  XDG_CACHE_HOME=$HOME/.cache  XDG_DATA_HOME=$HOME/.local/share
UV_CACHE_DIR, pnpm_config_store_dir, npm_config_store_dir,
BUN_INSTALL_CACHE_DIR, GOPATH, GOCACHE, GOMODCACHE  -> under $HOME
```

### `devbox-init` (runtime entrypoint)

```
devbox-init [cmd...]
  1. mkdir -p $HOME/.tmp $HOME/.ssh; known_hosts for github/codeberg
  2. if $HOME/dotfiles missing: git clone $DEVBOX_DOTFILES_URL
     else: git fetch (never merge/reset - checkout belongs to user)
  3. unless DEVBOX_DOTS=0: omni dots sync --use-repo
  4. shadow-warning scan
  5. exec "${@:-sleep infinity}"
```

Env: `DEVBOX_DOTFILES_URL` (default `https://github.com/lkshrk/dotfiles.git`),
`DEVBOX_DOTS` (default `1`), `OMNI_HOSTNAME=devbox`.

Coder startup script, k8s pod `command`, and local `docker run` all go
through this one script. No second copy of bootstrap logic.

## Launchers

### Coder

One template `coder/devbox/` (eventually replacing h-cloud's ten). Per-project content
becomes `coder_workspace_preset` blocks (repos, deployment_url, dind,
playwright, access profile). The access profile (`base`, `civora`,
`routivo`, `pub`) selects the service account and namespace as today; it
is a preset value, not derived from template name.

Startup script = Coder-only steps (kubeconfig from mounted SA token, repo
clone via git-clone module) then `devbox-init`. No apt, no `omni tools
sync`, no playwright install. Each preset picks a variant
(`go|python|ts|lua|full`) -> `ghcr.io/lkshrk/devbox/<variant>:<calver>`;
the calver is pinned once in `main.tf`,
bumped by Renovate in this repo.

Delivery to the cluster: Coder has no pull/GitOps mode; templates are
pushed. `coder-templates.yaml` in this repo runs `coder templates push
devbox --directory coder/devbox --name <short sha> --message "<commit
subject>" --yes` on main (PRs only `terraform fmt -check` + `validate`).
`--activate` (default) makes it the active version; every workspace on an
older version shows Coder's "Update available" banner and `coder list`
marks it outdated. Users update on their own; `require_active_version`
stays off. An image tag bump is a template change (`main.tf`), so the
chain is: release -> Renovate PR here -> merge -> push -> banner. The
`variant` parameter options stay stable so updates never force a
re-prompt. The `coderd` Terraform provider was considered and rejected:
needs remote state, no benefit over the CLI.

The template name `devbox` does not collide with any h-cloud template,
so both sets coexist in the same Coder deployment during phase 1.

### Agent pods (h-cloud, phase 2)

Hermes hub and Pilot: Deployments/StatefulSets in h-cloud with
`image: ghcr.io/lkshrk/devbox/hermes:<calver>` / `devbox/pilot:<calver>`, `command` set
(`hermes gateway run`, `pilot start ...`), `DEVBOX_DOTS=0`, secrets via
env from SOPS as today. Pilot shims (`gh` wrapper, notify/retry helpers)
ship in the image under `/opt/devbox/pilot/bin`. Image bump via the
existing `repository_dispatch` → h-cloud `update-image.yml`.

### Headless / local

`scripts/devbox` wrapper:

```
devbox up NAME [-v host:container ...]   docker run -d, named volume NAME-home at /home/dev
devbox sh NAME                           docker exec -it ... zsh
devbox run [-v ...] -- CMD               one-shot, --rm
devbox stop|rm NAME
```

Works with docker or podman. k8s one-shot = plain Job manifest example in
`docs/`.

## Secrets

Contract, identical for every launcher: **the image contains no secrets
and reads them only from the environment at start.** Build needs none
(all sources public), so no `--secret` mounts, no registry login at build.

Common env, consumed by tools directly:

| env                                          | consumer                       |
|----------------------------------------------|--------------------------------|
| `GH_TOKEN` (+ `GITHUB_TOKEN`, `GITHUB_PERSONAL_ACCESS_TOKEN` aliases) | gh, generic tools, github-mcp |
| `CLAUDE_CODE_OAUTH_TOKEN`                    | claude                         |
| `CODEX_AUTH_JSON`                            | codex (file-shaped, see below) |
| `LITELLM_API`                                | in-cluster LLM proxy           |

`devbox-init` materialises file-shaped secrets from env and nothing else:
`CODEX_AUTH_JSON` -> `~/.codex/auth.json` (0600). It never prints env.
Tool-side credential caches (`~/.claude`, `~/.config/gh`) live in home
and therefore persist per workspace/volume, never in the image.

Per launcher:

- **Coder**: unchanged mechanism. `coder-workspace-secrets` via `envFrom`,
  per-preset extras via `<preset>-workspace-env` (optional, was
  `<template>-workspace-env`; presets replace templates as the key), git
  SSH through Coder's per-user key and `GIT_SSH_COMMAND`, kube access via
  the mounted service-account token. All of that stays in h-cloud SOPS.
- **Agent pods**: SOPS Secret -> env, as the hub does today. Hermes keeps
  its existing key list (`docs/secrets-checklist.md`); pilot gets its
  GitHub App key and Signal config the same way.
- **Local**: `scripts/devbox` passes `--env-file ~/.config/devbox/env`
  (0600, gitignored, template in `scripts/devbox.env.example`) and mounts
  the host ssh-agent socket instead of keys. Optional `rbw`-backed
  `devbox env` helper fills that file from Bitwarden. Never `-e` on the
  command line (shell history).
- **k8s one-shot Jobs**: `envFrom` the same `coder-workspace-secrets`.

Public image guard: the `devbox` omni host excludes `priv`; `validate.yaml`
runs gitleaks on the repo and a `grep` for token patterns over `/opt/devbox`
and `/etc` in each built variant; `image/.env.example` stays the only
env file in the repo.

## Release / CI

- `validate.yaml` (PR): `docker buildx bake` all variants (no push) + per-variant smoke test:
  `claude --version`, `codex --version`, `go version`, `bun --version`,
  `uv --version`, `hermes --version`, `pilot version`, `devbox-init true`
  with `DEVBOX_DOTS=1` against a throwaway home, shadow-scan exit 0;
  `terraform validate` on the Coder template.
- `release.yaml` (main): calendar tag, bake `--push`, dispatch to h-cloud.
- Image labels: `org.opencontainers.image.source` (links each GHCR package
  to this repo so it inherits public visibility - required: private GHCR
  on the free tier caps at 500 MB), `org.opencontainers.image.revision`,
  `dotfiles.commit`.
- One GHCR package per variant (`devbox/go`, `devbox/full`, ...): tags are
  pure calver, so Renovate/Flux image policies need no custom regex.

## Rollout

### Phase 1 - add (this repo only, plus one dotfiles change)

1. dotfiles: `devbox` omni host, `agent-hermes` / `agent-pilot` groups,
   `pilot` tool. Additive; existing `coder`/`hermes` hosts untouched.
2. `image/Containerfile` + `image/scripts/` + `docker-bake.hcl`, all seven
   variants. `validate.yaml` builds and smoke-tests them on PRs;
   `release.yaml` publishes `ghcr.io/lkshrk/devbox/<variant>:<calver>`.
   The existing hermes-hq image build keeps running unchanged until phase 2.
3. `coder/devbox/` template with presets; `coder-templates.yaml` pushes it
   as a **new** template next to h-cloud's. Existing workspaces unaffected.
4. `scripts/devbox` local launcher.
5. README describes both (old = current, new = devbox preview).

Done when: each variant builds and passes smoke; a `devbox` workspace per
variant starts in Coder with dots synced and repos cloned; `devbox up`
works locally on macOS; hermes and pilot binaries run `--version` inside
`devbox/hermes` and `devbox/pilot` containers.

### Phase 2 - switch and delete (after phase 1 proven in daily use)

1. h-cloud: hermes-hq and pilot workloads -> `devbox/hermes`,
   `devbox/pilot` with `command` + `DEVBOX_DOTS=0`. Verify pods healthy.
2. Recreate personal workspaces on `devbox` (home PVCs are per workspace;
   old ones stay until deleted by hand).
3. h-cloud: delete `kubernetes/apps/coder/coder/templates/` and its
   `coder-templates.yaml`; delete the old templates in Coder.
4. This repo: delete `coder/templates/hermes-worker-*`, `common.tf`, the
   hermes-hq image path in `release.yaml`, the TBD docs; rename product to
   `auto-code-env` everywhere; `docs/architecture.md` becomes the single
   design page.

Each phase-2 step is its own PR and independently revertible.

## Dependencies outside this repo

- **dotfiles**: add `devbox` host entry, groups `agent-hermes` and
  `agent-pilot`, `pilot` tool, per-tool `bin_dir` where needed.
- **h-cloud**: delete Coder templates dir; point hermes-hq and pilot
  workloads at `devbox` image with `command`; Renovate for the tag.

## Image size

Measured after the first build (`dive`, `docker history`), then cut in
this order:

1. BuildKit cache mounts on every tool stage (`uv`, `bun`, `npm`, `go-build`,
   apt) so download caches never land in a layer.
2. dpkg `path-exclude` for `/usr/share/{doc,man,info,locale}`.
3. No `build-essential` (already proven: 435 -> 200 MB in `/usr`).
4. Heavy, narrowly used groups (`browser`, `infra`, `agent`) only enter
   the variants that need them (see matrix).
5. Push with `compression=zstd,force-compression=true`.
6. The `devbox` omni host never includes `desk`, `gaming`, `mac`, `priv`,
   `utils`, `omni`. `core` (incl. neovim, tmux) is in.

Not done: `--squash` (kills layer caching), Alpine base. Target: language
variants under 2 GB, `full` under 3 GB.

## Risks

- A tool resolving its install dir via `$HOME` at runtime instead of an
  absolute path (suspect: hermes launcher vs `HERMES_HOME`). Mitigation:
  smoke test runs every variant's binaries with `HOME=/tmp/x`.
- Image size (~4 GB). Accepted; node image cache amortises it.
- Home-shadowing stale tools after image bump. Mitigation: warning in
  `devbox-init`.
- `/home/coder` → `/home/dev` path change breaks any absolute path in
  dotfiles or h-cloud manifests. Grep both before cutover.
