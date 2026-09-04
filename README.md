# auto-code-env

Reproducible OpenHands worker runtime for WSL, Docker, and Kubernetes.

- [`runtimes/wsl/`](runtimes/wsl/) builds and validates the multi-architecture
  `ghcr.io/lkshrk/openhands-worker` OCI image and architecture-specific WSL
  artifacts.
- [`deploy/openhands/upstream`](deploy/openhands/upstream) pins the upstream
  OpenHands deployment source used by the chart release pipeline.

See [`runtimes/wsl/README.md`](runtimes/wsl/README.md) for architecture,
installation, security, release, and verification details.

## Skills

`skills/` holds OpenHands skills installed into the Agent Canvas from this repository, for example `skills/agent-sandbox-deploy` for deploying into the h-cloud `agent-sandbox` namespace.

## Automations

`automations/` holds OpenHands automation definitions applied to the Agent Canvas, for example [`automations/pr-review`](automations/pr-review) for central pull request review.
