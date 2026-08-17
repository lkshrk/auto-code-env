# Python Hermes worker workspace. Shared providers, agent, pod, and modules
# live in common.tf, which the CI copies into this directory at
# template-push time.

locals {
  stacks = ["python", "dev", "dev-tooling", "infra"]
}
