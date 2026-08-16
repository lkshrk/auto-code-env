# hermes-hq

A central control hub for agent based software development.

`hermes-hq` owns the Hermes control-hub image, documentation, operational
policy, and Coder template definitions for a persistent central Hermes
control hub with Coder-provisioned isolated project workspaces running in
Kubernetes.

## Scope

- **This repo** — how Hermes and the personal platform should operate:
  image build, non-secret configuration, skills, Coder template
  definitions, Kubernetes base manifests, and docs.
- **`lkshrk/dotfiles`** — persistent-home bootstrap and dotfile
  provisioning (`setup.sh`, `setup-hermes.sh`, `setup-coder.sh`,
  `setup-workspace.sh`). The control-hub image invokes this repo's
  bootstrap scripts rather than duplicating them here.
- **`lkshrk/h-cloud`** — what is actually deployed in the cluster
  (GitOps source of truth, reconciled by Flux). References a
  released/pinned hub image from this repo.
- **Project repositories** — how each individual project is built;
  own their own `AGENTS.md`, toolchain, and test/build instructions.

Secrets never live in this repository or in `h-cloud`. Only secret
references (external-secret / SOPS pointers) are stored here.

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
│   └── decisions/               # ADRs
├── image/
│   ├── Containerfile
│   └── scripts/
├── kubernetes/
│   ├── base/
│   └── overlays/
│       └── production/
├── coder/
│   ├── templates/
│   └── README.md
├── scripts/
│   ├── verify.sh
│   ├── backup.sh
│   ├── restore-check.sh
│   └── healthcheck.sh
├── tests/
│   └── smoke/
└── .github/workflows/
    ├── validate.yaml
    └── build-image.yaml
```

## Status

Scaffolding in progress. See `docs/decisions/` for architecture decision
records as the design solidifies.
