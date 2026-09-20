# Coder Templates

Terraform sources for the Coder workspace templates served by
`https://coder.h-cloud.io`. Coder has no pull-based template source: a template
only changes when it is pushed. This repository is that source of truth and
`.github/workflows/coder-templates.yaml` is the only thing that pushes.

```text
coder/templates/
  common.tf              shared parameters, agent, modules, bootstrap
  backends/<name>.tf     providers, storage, and workspace resources
  shared/                scripts copied next to every template
  tests/                 static tests for shared/
  dev/main.tf            composable parameters and presets
  dev/backend            backend marker (kubernetes)
```

The dev family is defined once in `templates/dev` and packaged using
`targets.json` as the single `dev` target on the Kubernetes backend.
Tool stacks, repositories, agent clients, and presets are composable selections,
not separate language or project templates. Obsolete template sources are no
longer selectable or publishable from this repository. Existing published
legacy templates and their workspaces are unchanged by this source cleanup.

## Backends

`common.tf` is backend-neutral. It holds the shared parameters, the agent, the
Coder modules, the bootstrap, and the `coder` provider configuration.
Everything that actually creates a workspace lives in `backends/<name>.tf`:
the backend's provider, its storage, the workspace itself, and the
docker-in-docker sidecar. Terraform accepts only one `required_providers`
block per module, so that block lives in the backend file and declares `coder`
alongside the backend's own provider. Only `kubernetes` exists today; the split
stays so a second backend is a file, not a refactor.

The target catalog explicitly selects the backend. The packager accepts only the
`dev` definition and only the `kubernetes` backend (`dev/backend` marker or
`--backend`). CI copies exactly one backend file into each package.

The seam between the two halves is `local.backend_bootstrap`: the backend
file defines it and `common.tf` interpolates it into the agent startup script
at a fixed position. The Kubernetes backend writes the in-cluster kubeconfig
there. Backend files may read the shared locals from `common.tf`; `common.tf`
must never reference a backend resource.

## Desktop node (towerr)

There is no second backend for the Windows desktop any more. towerr runs the
Talos worker `k8s-12` in a Hyper-V VM (h-cloud `talos/nodes/k8s-12.yaml.j2`),
tainted `dedicated=desktop:NoSchedule`. The `dev` template's `location`
parameter (`cluster` default, preset `desktop`) adds the matching node selector
and toleration and switches the home PVC to `openebs-hostpath`, so the home
lives on the VM's data disk and follows the node. While the desktop is off the
node is NotReady, the pod is evicted, and `coder start` waits; nothing needs
`--orphan`. Cluster Secrets, the service-account token and the kubeconfig are
identical to any other workspace.

## Claude Code language servers

When `claude` is among the agent clients, startup writes
`~/.claude/skills/coder-lsp/.claude-plugin/plugin.json`, a skills-directory
plugin Claude Code loads at user scope. Its `lspServers` list whichever
language servers the selected stacks put on `PATH`, so Claude gets
diagnostics after every edit and go-to-definition, references and hover
through its `LSP` tool without a marketplace plugin. Servers that are not
installed are left out, and the plugin disappears when none is. The same
list lives in dotfiles `apm/ai-plugins/apm.yml` for hosts that run apm.

| Stack | Server | Files |
|---|---|---|
| `go` | `gopls` | `.go` |
| `python` | `pyright-langserver` | `.py`, `.pyi` |
| `ts` | `typescript-language-server` | `.ts`, `.tsx`, `.js`, `.jsx`, `.mts`, `.cts`, `.mjs`, `.cjs` |
| `lua` | `lua-language-server` | `.lua` |
| `rust` | `rust-analyzer` (rustup component) | `.rs` |
| `k8s`, `gitops`, `argo`, `talos`, `cilium`, `cnpg` | `yaml-language-server` | `.yaml`, `.yml` |
| `iac` | `terraform-ls` | `.tf`, `.tfvars` |
| `quality` | `bash-language-server` (with `shellcheck`) | `.sh`, `.bash` |

Claude matches files by extension only, so a bare `Dockerfile` has no server
even with the `containers` stack.

## WoW addon workspaces

The `wow` preset selects the `lua` tool group and turns on `wow_dev`, which
adds what the generic Lua tools lack, knowledge of the game:

- `~/.local/share/wow/wow-api/Annotations`: Ketho's lua-language-server
  annotations of the WoW API and FrameXML (the same files the VS Code
  extension ships). `wow-luarc [dir]` writes a `.luarc.json` into an addon
  checkout that loads them, sets Lua 5.1 and disables the standard libraries
  the game does not have. It keeps an existing file unless `--force`.
- `~/.config/luacheck/.luacheckrc`: generated from those annotations, every
  API name as a read-only global with `std = "none"`. luacheck uses it only
  when the repo has no `.luacheckrc` of its own.
- `~/.local/share/wow/wow-ui-source`: Gethe's mirror of Blizzard's UI code,
  branch `live`, for grepping how the real FrameXML does something. Both
  checkouts are shallow and fast-forwarded by `wow-setup` on every start.
- `~/.local/bin/wow-sync` with a pinned `rclone` and `inotify-tools`. There is
  no mount: the game directory is an rclone remote named `wow:` that the
  workspace pushes to. A kernel CIFS mount on a desktop that reboots leaves a
  pod stuck in `Terminating`; a failed push just prints an error.

Development stays on the home volume. `wow-sync` finds every addon in the
cloned repositories by its `.toc`, stages a copy locally, rewrites it into the
dev variant, and runs `rclone sync` into `<wow_addons_path>/<Name>-<suffix>`.
rclone writes each file once, retries, and verifies size and modification time,
so the stage-then-verify dance a hand-written copy needs is built in.
`wow-sync --watch` repeats that on every change; `--dry-run` shows the plan.
WoW reads addon files only at load, so `/reload` in game after a sync.

`wow_dev_suffix` (default `Dev`) is what makes this safe to run beside the
released addon: `Alpha` is installed as `Alpha-Dev` with `Alpha-Dev.toc`, its
Title marked `[DEV]`, and every `SavedVariables` name suffixed in the `.toc` and
in the Lua sources (`AlphaDB` becomes `AlphaDBDev`; `Libs/` is left alone). The
two copies toggle independently in the addon list and never share settings,
which live under `WTF/`, not `Interface/AddOns`. An empty suffix syncs under the
real name and overwrites the release.

The transport is SFTP to a small `rclone serve sftp` on the desktop, set up
from h-cloud with `just talos wow-sync-server -AuthorizedKey '"<pubkey>"'`
(`talos/hyperv/Enable-WowSync.ps1`). It runs as a scheduled task under SYSTEM,
serves only `Interface/AddOns`, and authenticates against its own
`authorized_keys`, so no Windows account exists for it and `..` cannot leave
the directory. The template sets the non-secret remote config
(`RCLONE_CONFIG_WOW_TYPE=sftp`, host, port 2022, `shell_type=none`, the pinned
host key from `wow_host_key`). The only secret is the private key, which a Coder
user secret writes into the workspace:

```bash
ssh-keygen -t ed25519 -N '' -C wow-sync -f ~/.ssh/wow-sync
coder secret create wow-sync-key --file ~/.ssh/wow-sync < ~/.ssh/wow-sync
```

`wow_host_key` pins the server's host key (`host_keys` in rclone terms); the
server script prints it. Emptying it turns validation off. rclone has no
hashes over SFTP, so `--checksum` must not be added. Sync with the game closed
or `/reload` afterwards; the client holds files open while loading.

## CI

`coder-templates.yaml` runs on pull requests, on pushes to `main`, and on
`workflow_dispatch`.

- Pull requests package affected catalog targets. Main pushes and manual runs
  validate every catalog target. No legacy selection or publication option exists.
- Packages are built once and validated with pinned OpenTofu before publication.
- Pushes to `main` validate only. Publication requires `workflow_dispatch` on
  `main` with `publish: true`.
- CI exercises the version-1 dotfiles resolver/core-layout contract and companion
  component tests without installing tools or syncing the runner's dotfiles. Manual
  publication requires `dotfiles_revision` to be a full tested commit SHA matching
  the companion default branch; logs identify both repository revisions.
- Composable startup negotiates the same contract against the preserved checkout,
  including custom dotfiles URLs, before component installation. A contract failure
  requires an explicit operator update, never a reset or automatic branch switch.
  Contract compatibility is not disposable installation acceptance.
- Operators must verify fresh bootstrap and explicitly update preserved dotfiles
  checkouts before opting into publication. CI cannot verify existing workspace
  volumes, and does not reset user checkouts.
- Publication installs the Coder CLI matching `/api/v2/buildinfo` and pushes
  validated packages using the `CODER_SESSION_TOKEN` repository secret.

Deleting a template source directory does not delete the published template or
change any workspace in Coder. Any lifecycle action requires separate operator
authorization; source cleanup must not affect workspaces using older packages.

## Local validation

Reproduce what CI does:

```bash
bash coder/templates/tests/packaging.sh
bash coder/templates/tests/selection.sh
bash coder/templates/tests/prepare-dotfiles.sh
bash coder/templates/tests/wow-sync.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s coder/templates/tests -p 'test_*.py'

packages=$(mktemp -d)
bash coder/scripts/select-templates.sh "$PWD" targets > "$packages/targets"
while IFS=$'\t' read -r name dir backend; do
  bash coder/scripts/package-template.sh "$dir" "$packages/$name" --backend "$backend"
  bash coder/scripts/validate-templates.sh "$packages/$name"
done < "$packages/targets"
rm -rf "$packages"
```

Use OpenTofu for validation. The canonical packager includes local modules and
composable defaults; do not assemble packages with a separate copy recipe.
Set `CODER_TEST_DOTFILES` to the exact companion checkout for pair tests. Record
both SHAs and any uncommitted patches; a SHA alone does not identify a dirty tree.
`prepare-dotfiles.sh` preserves existing checkout contents while fetching and
updating origin: changing the URL does not switch the existing branch/revision.

Managed executable links created by the component bootstrap carry per-link
receipts. Upgrades (including dangling old targets) only replace links matching
those receipts. Pre-receipt or user-modified links require explicit operator
resolution; a path under `.nvm` alone is not proof of bootstrap ownership.


## Cluster contract

The `kubernetes` backend provisions into the h-cloud cluster, which must keep
providing:

- Namespace `coder`. Every workspace pod and home PVC is created there,
  whatever the template.
- Service account `coder-workspace` with base-profile RBAC and the workspace
  NetworkPolicy. The generated kubeconfig targets namespace `coder`. Repository
  and tool-stack selections do not grant project-scoped Kubernetes access.
- Secret `coder-workspace-secrets` in namespace `coder`, keys `LITELLM_API`
  and `GH_TOKEN`. Both are read `optional = true`, so a missing key degrades
  rather than blocks a workspace start.
- Secret `dev-kubernetes-workspace-env` in namespace `coder`, consumed as an
  optional `env_from` source.
- ConfigMap `lan-root-ca` (trust-manager Bundle target) with key `lan-root-ca.crt`, mounted at
  `/etc/ssl/lan/lan-ca.pem` for `OMNI_OTEL_CA_PATH`.
- StorageClass `ceph-block` for the per-workspace home PVC, and
  `openebs-hostpath` for `location=desktop`.
- Node `k8s-12` labelled `dedicated=desktop` and tainted
  `dedicated=desktop:NoSchedule`; nothing else tolerates that taint.

Per-user Claude and Codex credentials are Coder user secrets, not cluster
secrets. Each user creates them once with `coder secret create`.
