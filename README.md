# auto-code-env

Reproducible OpenHands worker runtime for WSL, Docker, and Kubernetes.

## Layout

- [`worker/`](worker/) builds and validates the multi-architecture
  `ghcr.io/lkshrk/openhands-worker` OCI image and the architecture-specific WSL
  artifacts. `rootfs/`, `rootfs-oci/`, and `rootfs-wsl/` mirror the target
  filesystem and are copied verbatim into every image, the OCI image, and the
  WSL image respectively. `windows/` holds the host-side PowerShell scripts
  published as release assets. See
  [`worker/README.md`](worker/README.md) for architecture, installation,
  security, release, and verification details.
- [`openhands/`](openhands/) holds everything that targets an Agent Canvas
  deployment:
  - `chart/` is the Helm chart release pipeline. `chart/upstream` is the
    submodule pinning the upstream OpenHands deployment source, and
    `chart/release.sh` publishes the packaged chart.
  - `skills/` holds OpenHands skills installed into the Agent Canvas, for
    example `skills/agent-sandbox-deploy` for deploying into the h-cloud
    `agent-sandbox` namespace.
  - `automations/` holds automation definitions, one directory per backend.
  - `scripts/` holds operational one-off tooling.

Documentation beyond these READMEs is not kept in this repository.

## Automations and git-sync

Each backend syncs exactly one path: the `orc` backend syncs
`openhands/automations/orc`, and the `towerr` backend syncs
`openhands/automations/towerr`. A backend never reads outside its own
directory. Anything shared between backends lives in
`openhands/automations/common` and is symlinked into each per-backend directory
that needs it.
