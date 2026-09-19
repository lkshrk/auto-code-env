# auto-code-env

Reproducible OpenHands worker runtime for WSL, Docker, and Kubernetes.

## Layout

- [`coder/`](coder/) holds everything that targets Coder:
  - `templates/` holds the Terraform sources for the workspace templates.
    `targets.json` packages the composable dev family for Docker and Kubernetes.
    `.github/workflows/coder-templates.yaml` validates packages; publication to
    `https://coder.h-cloud.io` requires an explicit manual run on `main`. See
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
- [`shared/windows/`](shared/windows/) holds the two PowerShell scripts the
  Coder worker uses, `firewall.ps1` and `keepalive.ps1`, with their suites.
  Its release publishes its own copy, so a host only ever runs the version
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
  - `profiles/` holds the profile-apply mechanism: `apply-profile.py` merges
    per-host profile JSON onto a running Agent Canvas backend's settings and
    secrets. It has no image or installer of its own — a `Job` (in the
    cluster config, outside this repo) downloads it and the profile JSON as
    checksummed assets from a pinned `openhands-worker-v*` release; publishing
    that release is `.github/workflows/worker-release.yaml`'s only job. See
    [`openhands/profiles/README.md`](openhands/profiles/README.md) for the
    profile schema, backup/restore, and test details. There is intentionally
    no standalone desktop Agent Canvas worker in this repo: an ephemeral
    Coder-provisioned Docker workspace (`coder/`, with `enable_openhands` on
    the `dev` template) covers that need without a second, always-on instance.
