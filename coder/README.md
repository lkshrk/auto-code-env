# Hermes orchestrator workspace(s)

Terraform sources for Coder workspace templates dedicated to Hermes as the
sole user — not human developer workspaces (those live in `lkshrk/h-cloud`
under `kubernetes/apps/coder/coder/templates/`, and stay there).

## Why a separate repo/pipeline from h-cloud

`h-cloud`'s Coder templates exist for human dev work (routivo, civora,
sveltekit, language-generic templates, etc.) and are pushed by that repo's
own `.github/workflows/coder-templates.yaml` on merge to main. Hermes is the
only consumer of the template(s) here, so keeping the source and push
pipeline in `hermes-hq` avoids mixing an audience-of-one template into the
human-facing template set, while still landing on the same live Coder
deployment (`https://coder.h-cloud.io`).

## Templates

- `common.tf` — shared providers, agent, pod, and modules for every
  hermes-worker template. Per-arch `main.tf` files define only
  `local.stacks` (the Omni tool group to install).
- `hermes-worker-js/` — TypeScript/JS workspace (`stacks = ["ts", "infra"]`).
- `hermes-worker-py/` — Python workspace (`stacks = ["python", "infra"]`).
- `hermes-worker-go/` — Go workspace (`stacks = ["go", "infra"]`).

All three are what Hermes provisions and drives via
`coder ssh <workspace> -- ...` to dispatch Claude Code / Codex tasks
against a target repo (the "hybrid" orchestration model: Hermes itself
runs only in the control hub, never inside these workspaces). Split by
language/arch rather than by project or a single generic template, since
Hermes always knows the target stack up front and a fixed `local.stacks`
per template keeps each workspace minimal - no user-facing stack picker.

## Push mechanism

`.github/workflows/coder-templates.yaml` in this repo validates the
Terraform and pushes changed templates to the same live Coder deployment,
independently of h-cloud's pipeline. See that repo's README for the
counterpart pattern this one is modeled on.
