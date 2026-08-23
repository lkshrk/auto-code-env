# devbox: one reproducible dev image, many launchers

Date: 2026-08-23
Status: draft, awaiting review

## Goal

Replace the Hermes-only control-hub image and the ten per-project Coder
templates in h-cloud with **one image** (`ghcr.io/lkshrk/devbox`) that
carries the full dev toolchain, and a small set of launchers that run it:

- Coder workspaces (human, interactive, create/pause/delete on demand)
- long-running agent pods (Hermes gateway, Pilot)
- headless one-shot runs (`claude -p`, `codex exec`) in k8s Jobs or locally
- personal local containers on a laptop

Tools are baked into the image. Dotfiles/env are synced at every start.

## Non-goals

- Stack-split images (`devbox:go`, `devbox:ts`). Layering allows it later;
  not published now.
- Hardened "no AI tools" hub image. Hermes and Pilot run on the same image
  as everything else.
- Owning Kubernetes manifests, secrets, or RBAC. Those stay in h-cloud.
- Replacing Coder. Coder stays the cluster workspace lifecycle manager.

## Image

`image/Containerfile`, multi-stage, one concern per stage, ordered by
change frequency so cache invalidation stays local:

| stage     | content                                                        |
|-----------|----------------------------------------------------------------|
| `base`    | `debian:trixie-slim`, user `dev` uid/gid 1000, sudo NOPASSWD, apt prereqs from dotfiles' `scripts/setup-workspace-linux.sh` |
| `omni`    | omni binary (dotfiles `scripts/install-omni-latest.sh`), dotfiles clone at pinned commit into `/opt/devbox/dotfiles` (build-time config source) |
| `core`    | `omni tools sync core dev dev-tooling shell prereqs test-tooling` |
| `go`      | `omni tools sync go`                                           |
| `python`  | `omni tools sync python`                                       |
| `ts`      | `omni tools sync ts`                                           |
| `lua`     | `omni tools sync lua`                                          |
| `browser` | apt libs for headless chromium/firefox (`playwright install-deps`), shared by project Playwright, shiplight and camofox |
| `ai`      | `omni tools sync ai ai-plugins`                                |
| `infra`   | `omni tools sync infra` (k8s/gitops CLIs)                      |
| `agents`  | `omni tools sync agents` (hermes, camofox, pilot, pilot shims) |
| `runtime` | `devbox-init`, `/etc/profile.d/devbox.sh`, OCI labels, entrypoint |

Rules:

- Each stage is `COPY image/scripts/NN-name.sh` + `RUN`. No apt lists or
  install logic inline. Rationale lives in `docs/architecture.md`, not
  in Containerfile comments.
- Tool groups come from a new `devbox` host in dotfiles
  `omni/.config/omni/settings.json`. A new `agents` group holds hermes
  and pilot (pilot is added to `tools.json`).
- `docker-bake.hcl` defines the `devbox` target, shared args
  (`DOTFILES_REF`, `DOTFILES_COMMIT`), tags and labels. CI runs
  `docker buildx bake`.

### Install layout: `/opt/devbox`

Coder mounts a PVC over `/home/dev`, so nothing baked may live in home.

During build only, provider env vars redirect installs:

```
BUN_INSTALL=/opt/devbox/bun
UV_TOOL_DIR=/opt/devbox/uv/tools   UV_TOOL_BIN_DIR=/opt/devbox/bin
PNPM_HOME=/opt/devbox/pnpm          npm_config_prefix=/opt/devbox/npm
CARGO_HOME=/opt/devbox/cargo        GOBIN=/opt/devbox/bin
omni settings.fallback_bin_dir=/opt/devbox/bin
```

Tools that ignore these and hardcode `~/.local/bin` get a per-tool
`bin_dir` in `tools.json`. The first build verifies the list.

At runtime those vars are **unset**. `/opt/devbox` is root-owned,
read-only for `dev`. `PATH` (via `/etc/profile.d/devbox.sh`):

```
~/.local/bin:~/.bun/bin:~/go/bin:~/.cargo/bin:/opt/devbox/bin:/opt/devbox/bun/bin:...:/usr/bin
```

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

One template `coder/devbox/` replaces h-cloud's ten. Per-project content
becomes `coder_workspace_preset` blocks (repos, deployment_url, dind,
playwright, access profile). The access profile (`base`, `civora`,
`routivo`, `pub`) selects the service account and namespace as today; it
is a preset value, not derived from template name.

Startup script = Coder-only steps (kubeconfig from mounted SA token, repo
clone via git-clone module) then `devbox-init`. No apt, no `omni tools
sync`, no playwright install. Image ref pinned by tag in `main.tf`,
bumped by Renovate in this repo.

`coder-templates.yaml` pushes the template from this repo. h-cloud
removes `kubernetes/apps/coder/coder/templates/`. The three
`hermes-worker-*` templates are deleted; Hermes creates `devbox`
workspaces with a preset instead.

### Agent pods (h-cloud)

Hermes hub and Pilot: Deployments/StatefulSets in h-cloud with
`image: ghcr.io/lkshrk/devbox:<tag>`, `command` set
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

## Release / CI

- `validate.yaml` (PR): `docker buildx bake` (no push) + smoke test:
  `claude --version`, `codex --version`, `go version`, `bun --version`,
  `uv --version`, `hermes --version`, `pilot version`, `devbox-init true`
  with `DEVBOX_DOTS=1` against a throwaway home, shadow-scan exit 0;
  `terraform validate` on the Coder template.
- `release.yaml` (main): calendar tag, bake `--push`, dispatch to h-cloud.
- Image labels: `org.opencontainers.image.revision`, `dotfiles.commit`.

## Repo changes

- Rename product to `auto-code-env` / image `devbox` in README, labels,
  workflows. Remove Hermes-hub framing.
- Delete `coder/templates/hermes-worker-*`, `coder/templates/common.tf`.
- Docs collapse to `README.md` + `docs/architecture.md` (layer rationale,
  install layout, shadowing rules, launcher matrix). Delete the TBD docs.

## Dependencies outside this repo

- **dotfiles**: add `devbox` host entry (all groups + `agents`), add
  `agents` group, add `pilot` tool, per-tool `bin_dir` where needed.
- **h-cloud**: delete Coder templates dir; point hermes-hq and pilot
  workloads at `devbox` image with `command`; Renovate for the tag.

## Image size

Measured after the first build (`dive`, `docker history`), then cut in
this order:

1. BuildKit cache mounts on every tool stage (`uv`, `bun`, `npm`, `go-build`,
   apt) so download caches never land in a layer.
2. dpkg `path-exclude` for `/usr/share/{doc,man,info,locale}`.
3. No `build-essential` (already proven: 435 -> 200 MB in `/usr`).
4. Heavy, narrowly used groups (`browser`, `infra`, `agents`) are the last
   tool stages, so a slimmer bake target is one `target=` line if ever
   needed. Not published now.
5. Push with `compression=zstd,force-compression=true`.
6. The `devbox` omni host never includes `desk`, `gaming`, `mac`, `priv`,
   `utils`, `omni`. `core` (incl. neovim, tmux) is in.

Not done: `--squash` (kills layer caching), Alpine base, separate agent
image. Target: under 3 GB.

## Risks

- Script-provider tools hardcoding `~/.local/bin` at build. Mitigation:
  first build lists them, `bin_dir` overrides.
- Image size (~4 GB). Accepted; node image cache amortises it.
- Home-shadowing stale tools after image bump. Mitigation: warning in
  `devbox-init`.
- `/home/coder` → `/home/dev` path change breaks any absolute path in
  dotfiles or h-cloud manifests. Grep both before cutover.
