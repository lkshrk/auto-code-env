# hermes-hq

A central control hub for agent based software development.

`hermes-hq` owns the Hermes control-hub image, documentation, operational
policy, and Coder template definitions for a persistent central Hermes
control hub with Coder-provisioned isolated project workspaces running in
Kubernetes.

## Scope

- **This repo** — how Hermes and the personal platform should operate:
  image build, non-secret configuration, skills, Coder template
  definitions, and docs. Publishes the versioned control-hub image to
  GHCR; does **not** own any Kubernetes/Helm manifests.
- **`lkshrk/dotfiles`** — persistent-home bootstrap and dotfile
  provisioning (`setup.sh`, `setup-hermes.sh`, `setup-coder.sh`,
  `setup-workspace.sh`). The control-hub image invokes this repo's
  bootstrap scripts rather than duplicating them here.
- **`lkshrk/h-cloud`** — what is actually deployed in the cluster
  (GitOps source of truth, reconciled by Flux): the HelmRelease/
  Kustomization, SOPS secrets, and every other manifest for the
  hermes-hq StatefulSet. References a released/pinned hub image tag
  published by this repo's `release`/`build-image` workflows. Owned
  and maintained directly in h-cloud, not here.
- **Project repositories** — how each individual project is built;
  own their own `AGENTS.md`, toolchain, and test/build instructions.

Secrets never live in this repository. Only secret references (SOPS
pointers, credential names) are documented here (`docs/secrets-checklist.md`).

## Layout

```text
hermes-hq/
├── README.md
├── docs/
│   ├── architecture.md
│   ├── threat-model.md
│   ├── operations-runbook.md
│   ├── backup-and-restore.md
│   ├── workspace-dispatch.md
│   ├── secrets-checklist.md
│   └── decisions/               # ADRs
├── image/
│   ├── Containerfile
│   ├── .env.example              # reference for the h-cloud SOPS secret's keys
│   └── scripts/
├── coder/
│   ├── templates/                # hermes-worker-{js,py,go} + common.tf
│   └── README.md
├── scripts/
│   └── verify.sh
└── .github/workflows/
    ├── validate.yaml             # PR/push: Containerfile + coder template checks
    ├── coder-templates.yaml      # push Coder templates to the live deployment
    └── release.yaml              # tag, build+push GHCR image, trigger h-cloud deploy
```

## Release flow

1. Merge to `main` (via PR).
2. `release.yaml` (single workflow — a tag created with the default
   `GITHUB_TOKEN` cannot itself trigger another workflow via
   `push: tags:`, GitHub's anti-recursion safeguard, so tagging and
   building are chained jobs here rather than separate files):
   1. Cuts a calendar-versioned tag (`YYYY.M.PATCH`, same scheme as
      h-cloud's own `tag.yaml`).
   2. Builds `image/Containerfile` and pushes
      `ghcr.io/lkshrk/hermes-hq:<tag>` (+ `:latest`) to GHCR.
   3. Fires a `repository_dispatch` `image-update` event at
      `lkshrk/h-cloud` with
      `{app: hermes-hq, image: ghcr.io/lkshrk/hermes-hq, tag: <tag>}`
      — skipped with a warning (not a failed run) if the
      `H_CLOUD_DISPATCH_TOKEN` secret isn't set yet.
3. h-cloud's own `update-image.yml` (already in production, same
   mechanism other apps use) finds every manifest pinning that image,
   bumps the tag, commits, and pushes. Flux reconciles the new tag from
   there — no manual deploy step.

## Status

Image, Coder templates, and CI (validate/release/build/deploy-trigger)
are in place. `H_CLOUD_DISPATCH_TOKEN` (a PAT/GitHub App token with
`contents:write` on `lkshrk/h-cloud`) does not exist yet, so step 3
above is currently a no-op warning — tags build and publish real
images regardless. h-cloud-side HelmRelease/Kustomization/SOPS wiring
is tracked and owned in `lkshrk/h-cloud` directly.

