# Routivo project workspace. Project identity and credential scope live at the
# template boundary; shared providers, agent, pod, and modules live in common.tf.

data "coder_workspace_preset" "default" {
  name    = "routivo"
  default = true
  parameters = {
    cpu            = "6"
    memory         = "32"
    deployment_url = "https://routivo.h-cloud.io"
  }
}

locals {
  stacks            = ["python", "ts", "infra"]
  enable_dind       = true
  enable_playwright = true
  repos             = ["git@github.com:routivo/routivo-monorepo.git"]
}
