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
