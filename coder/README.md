# Coder Templates

Terraform sources for the Coder workspace templates served by
`https://coder.h-cloud.io`. Coder has no pull-based template source: a template
only changes when it is pushed. This repository is that source of truth and
`.github/workflows/coder-templates.yaml` is the only thing that pushes.

```text
coder/templates/
  common.tf              shared parameters, agent, modules, bootstrap, pod
  shared/                scripts copied next to every template
  tests/                 static tests for shared/
  <template>/main.tf     per-template parameters and presets
```

Templates: `civora`, `gitops`, `go`, `hermes`, `lua`, `monorepo`, `python`,
`routivo`, `sveltekit`, `ts`. The directory name is the Coder template name.

## CI

`coder-templates.yaml` runs on pull requests, on pushes to `main`, and on
`workflow_dispatch`.

- It resolves the changed template directories from the diff. A change to
  `common.tf`, `shared/`, or `tests/` selects every template; a
  `workflow_dispatch` run does the same.
- For each selected template it builds a temporary directory holding
  `common.tf`, `shared/`, and the template's `*.tf`, then runs
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
  case "$name" in shared|tests) continue ;; esac
  tmpdir=$(mktemp -d)
  cp coder/templates/common.tf "$tmpdir/common.tf"
  cp -R coder/templates/shared "$tmpdir/shared"
  cp "$dir"/*.tf "$tmpdir/"
  terraform -chdir="$tmpdir" fmt -check -diff
  terraform -chdir="$tmpdir" init -backend=false -input=false
  terraform -chdir="$tmpdir" validate
  rm -rf "$tmpdir"
done
```

## Cluster contract

The templates provision into the h-cloud cluster, which must keep providing:

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
