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
  <template>/main.tf     per-template parameters and presets
  <template>/backend     backend marker, absent means kubernetes
```

Templates: `civora`, `desktop`, `gitops`, `go`, `hermes`, `lua`, `monorepo`,
`python`, `routivo`, `sveltekit`, `ts`. The directory name is the Coder
template name.

## Backends

`common.tf` is backend-neutral. It holds the shared parameters, the agent, the
Coder modules, the bootstrap, and the `coder` provider configuration.
Everything that actually creates a workspace lives in `backends/<name>.tf`:
the backend's provider, its storage, the workspace itself, and the
docker-in-docker sidecar. Terraform accepts only one `required_providers`
block per module, so that block lives in each backend file and declares `coder`
alongside the backend's own provider.

A template picks its backend with a one-line `backend` file next to its
`main.tf`. No marker means `kubernetes`. CI copies exactly one backend file
into the build directory, so a template never sees the other backend's
providers.

The seam between the two halves is `local.backend_bootstrap`: every backend
file defines it and `common.tf` interpolates it into the agent startup script
at a fixed position. The Kubernetes backend writes the in-cluster kubeconfig
there; the Docker backend defines it empty. Backend files may read the shared
locals from `common.tf`; `common.tf` must never reference a backend resource.

## Desktop backend

The `desktop` template runs workspaces as Docker containers in a WSL2
distribution on the Windows desktop instead of as pods in the cluster. The
provisioner reaches that host's Docker API over mutual TLS.

- `docker_host` (template variable, default `tcp://172.16.20.195:2376`) is the
  daemon endpoint.
- `docker_cert_path` (default `/etc/coder/docker-tls`) is the directory in the
  coderd pod holding `ca.pem`, `cert.pem`, and `key.pem`. h-cloud mounts the
  `coder-docker-tls` Secret there read-only.
- The provider sets `disable_docker_daemon_check = true`, so template import
  and `coder templates push` never contact the desktop. Only workspace start,
  stop, and delete do.
- With the desktop asleep or the distro stopped those three operations fail
  with a provider connection error and leave no partial state. Clear the
  workspace record with `coder delete --orphan <workspace>`; its containers and
  volumes stay on the desktop until it comes back. Template pushes keep working
  throughout.
- The home volume carries `ignore_changes = all` and outlives a workspace
  delete, matching the upstream registry template. Reclaim it on the desktop.
- `/etc/ssl/lan/lan-ca.pem` is bind-mounted read-only from the distro for
  `OMNI_OTEL_CA_PATH`, and the workspace images must already be pulled there.
- With docker-in-docker enabled the workspace joins a private network with a
  `docker:27-dind` sibling reachable as `docker`, TLS on
  (`DOCKER_TLS_CERTDIR=/certs`); the workspace reads the generated client
  certificate from the shared `/certs` volume.

Desktop workspaces cannot mount cluster Secrets, so the host supplies them:
`coder-worker-overlay secrets --env-id` writes `/etc/coder-worker/workspace.env`
from a Vaultwarden item, the container bind-mounts it read-only at
`/run/coder-worker/workspace.env`, and the entrypoint exports each `NAME=value`
line before the agent starts. Populate it with the same names the Kubernetes
backend sets (`LITELLM_API`, `GH_TOKEN`, `GITHUB_TOKEN`,
`GITHUB_PERSONAL_ACCESS_TOKEN`). Values never pass through Coder or Terraform
state; rotation is a SOPS edit for the cluster and a vault edit for the
desktop, two places on purpose. Desktop workspaces still get no
`<template>-workspace-env` (project-scoped, intentional) and no
service-account token or kubeconfig. Per-user Claude and Codex credentials
are Coder user secrets and work unchanged.

A project that should be startable on both backends needs a preset on its
Kubernetes stack template and a second one on `desktop`. They are separate
templates and nothing keeps the two preset lists in sync.

## CI

`coder-templates.yaml` runs on pull requests, on pushes to `main`, and on
`workflow_dispatch`.

- It resolves the changed template directories from the diff. A change to
  `common.tf`, `shared/`, `tests/`, or `backends/` selects every template; a
  `workflow_dispatch` run does the same.
- For each selected template it builds a temporary directory holding
  `common.tf`, `shared/`, the template's `backend` marker, the
  `backends/<backend>.tf` that marker names, and the template's `*.tf`, then
  runs
  `terraform fmt -check -diff`, `terraform init -backend=false`, and
  `terraform validate`. Terraform is installed at a pinned version with its
  SHA256 verified against HashiCorp's checksum file.
- On `main` only, it installs the Coder CLI at the version the server reports
  from `/api/v2/buildinfo` and runs `coder templates push <name>` for each
  selected template, authenticating with the `CODER_SESSION_TOKEN` repository
  secret.

Deleting a template directory does not delete the template in Coder. Remove it
in Coder as a separate operator step.

## Local validation

Reproduce what CI does:

```bash
bash coder/templates/tests/prepare-dotfiles.sh

for dir in coder/templates/*/; do
  name=$(basename "$dir")
  case "$name" in backends|shared|tests) continue ;; esac
  tmpdir=$(mktemp -d)
  cp coder/templates/common.tf "$tmpdir/common.tf"
  cp -R coder/templates/shared "$tmpdir/shared"
  backend=kubernetes
  if [ -f "$dir/backend" ]; then
    cp "$dir/backend" "$tmpdir/backend"
    backend=$(tr -d '[:space:]' < "$dir/backend")
  fi
  cp "coder/templates/backends/$backend.tf" "$tmpdir/"
  cp "$dir"/*.tf "$tmpdir/"
  terraform -chdir="$tmpdir" fmt -check -diff
  terraform -chdir="$tmpdir" init -backend=false -input=false
  terraform -chdir="$tmpdir" validate
  rm -rf "$tmpdir"
done
```

## Cluster contract

The `kubernetes` backend provisions into the h-cloud cluster, which must keep
providing:

- Namespace `coder`. Every workspace pod and home PVC is created there,
  whatever the template.
- Service accounts `coder-workspace` (base profile),
  `coder-workspace-civora`, `coder-workspace-routivo`, and
  `coder-workspace-pub`, with their RBAC and the workspace NetworkPolicy.
  `common.tf` derives the name from `local.workspace_access_profile`:
  `civora` → `civora`, `routivo` → `routivo`, `sveltekit` → `pub`, everything
  else → `base`. The generated kubeconfig targets the namespace of the same
  name (`coder` for the base profile).
- Secret `coder-workspace-secrets` in namespace `coder`, keys `LITELLM_API`
  and `GH_TOKEN`. Both are read `optional = true`, so a missing key degrades
  rather than blocks a workspace start.
- Secret `<template>-workspace-env` in namespace `coder`, consumed as an
  optional `env_from` source. Only some templates have one.
- ConfigMap `lan-root-ca` (trust-manager Bundle target) with key `lan-root-ca.crt`, mounted at
  `/etc/ssl/lan/lan-ca.pem` for `OMNI_OTEL_CA_PATH`.
- StorageClass `ceph-block` for the per-workspace home PVC.

Per-user Claude and Codex credentials are Coder user secrets, not cluster
secrets. Each user creates them once with `coder secret create`.
