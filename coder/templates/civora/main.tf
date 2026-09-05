# Civora project workspace. The dedicated template name selects its
# namespace-scoped Kubernetes identity in common.tf.

data "coder_workspace_preset" "default" {
  name    = "civora"
  default = true
  parameters = {
    cpu            = "6"
    disk_size      = "50"
    deployment_url = "https://neustadt.civora.news"
  }
}

locals {
  stacks            = ["python", "ts", "infra"]
  enable_dind       = true
  enable_playwright = true
  repos             = ["git@github.com:loc-news/civora-monorepo.git"]
}
