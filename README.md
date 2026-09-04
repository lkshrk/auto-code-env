# auto-code-env

Reproducible OpenHands worker runtime for WSL, Docker, and Kubernetes.

- [`runtimes/wsl/`](runtimes/wsl/) builds and validates the multi-architecture
  `ghcr.io/lkshrk/openhands-worker` OCI image and architecture-specific WSL
  artifacts.
- [`deploy/openhands/upstream`](deploy/openhands/upstream) pins the upstream
  OpenHands deployment source used by the chart release pipeline.

See [`runtimes/wsl/README.md`](runtimes/wsl/README.md) for architecture,
installation, security, release, and verification details.
