# Generic full-stack monorepo workspace with the python + ts + infra stacks.
# Privileged project namespaces use dedicated templates so mutable repository
# parameters never select Kubernetes authorization.

data "coder_parameter" "repos" {
  name         = "repos"
  display_name = "Repositories"
  description  = "Comma-separated git URLs to clone on first start."
  default      = ""
  mutable      = true
}

locals {
  stacks            = ["python", "ts", "infra"]
  enable_dind       = true
  enable_playwright = true
  repos             = split(",", data.coder_parameter.repos.value)
}
