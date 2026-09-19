# auto-code-env

Reproducible OpenHands and Coder runtime for Kubernetes.

## Layout

- [`coder/`](coder/) holds everything that targets Coder:
  - `templates/` holds the Terraform sources for the workspace templates.
    `targets.json` packages the composable dev family as the `dev` template on
    the Kubernetes backend; its `desktop` preset pins a workspace to the
    desktop node k8s-12 (h-cloud `talos/nodes/k8s-12.yaml.j2`).
    `.github/workflows/coder-templates.yaml` validates packages; publication to
    `https://coder.h-cloud.io` requires an explicit manual run on `main`. See
    [`coder/README.md`](coder/README.md) for the CI flow, local validation, and
    the cluster contract the templates depend on.
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
    Coder workspace (`coder/`, with `enable_openhands` on the `dev` template,
    optionally on the desktop node) covers that need without a second,
    always-on instance.
