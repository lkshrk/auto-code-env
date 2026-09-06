# auto-code-env

Reproducible OpenHands worker runtime for WSL, Docker, and Kubernetes.

## Layout

- [`coder/`](coder/) holds everything that targets Coder:
  - `templates/` holds the Terraform sources for the workspace templates.
    `.github/workflows/coder-templates.yaml` validates them and pushes changed
    templates to `https://coder.h-cloud.io` on `main`. See
    [`coder/README.md`](coder/README.md) for the CI flow, local validation, and
    the cluster contract the templates depend on.
  - `worker/` turns a stock Ubuntu WSL2 distribution on the Windows desktop into
    a Docker host for Coder workspaces, exposed only as a mutual-TLS Docker API
    on TCP/2376. `install/` holds the Windows installer, `runtime/` the in-distro
    tool that installs and operates the distribution, `tools/` the trust-material
    generator, and `hosts/` the committed non-secret host profiles. There is no
    image build; the distribution is stock Ubuntu plus one checksummed file. See
    [`coder/worker/README.md`](coder/worker/README.md) for the runtime contract,
    installation, firewall, secrets, and verification details.
- [`shared/windows/`](shared/windows/) holds the two PowerShell scripts both
  workers use, `firewall.ps1` and `keepalive.ps1`, with their suites. Each
  worker's release publishes its own copy, so a host only ever runs the version
  its release was built with.
- [`openhands/`](openhands/) holds everything that targets an Agent Canvas
  deployment:
  - `chart/` is the Helm chart release pipeline. `chart/upstream` is the
    submodule pinning the upstream OpenHands deployment source, and
    `chart/release.sh` publishes the packaged chart.
  - `skills/` holds OpenHands skills installed into the Agent Canvas, for
    example `skills/agent-sandbox-deploy` for deploying into the h-cloud
    `agent-sandbox` namespace.
  - `automations/` holds automation definitions, one directory per backend.
  - `worker/` builds and validates the multi-architecture
    `ghcr.io/lkshrk/openhands-worker` OCI image and the architecture-specific WSL
    artifacts. `image/` holds the build: `rootfs/`, `rootfs-oci/` and
    `rootfs-wsl/` mirror the target filesystem and are copied verbatim into the
    image, the OCI image and the WSL image respectively. `install/` holds the
    host-side PowerShell scripts published as release assets. See
    [`openhands/worker/README.md`](openhands/worker/README.md) for architecture,
    installation, security, release and verification details.
