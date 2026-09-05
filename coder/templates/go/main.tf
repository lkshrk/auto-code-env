# Go workspace. Shared providers, agent, pod, and modules live in common.tf,
# which the CI copies into this directory at template-push time.

data "coder_workspace_preset" "easy_web_gpg" {
  name = "easy-web-gpg"
  parameters = {
    repos          = "git@github.com:lkshrk/Easy-Web-GPG.git"
    deployment_url = "https://gpg.h-cloud.lan"
  }
}

data "coder_workspace_preset" "omni" {
  name = "omni"
  parameters = {
    cpu    = "6"
    memory = "8"
    repos  = "git@github.com:lkshrk/omni.git"
    stacks = jsonencode(["go", "omni"])
  }
}

data "coder_parameter" "repos" {
  name         = "repos"
  display_name = "Repositories"
  description  = "Comma-separated git URLs to clone on first start. Leave empty for none."
  default      = ""
  mutable      = true
}

data "coder_parameter" "enable_dind" {
  name         = "enable_dind"
  display_name = "Docker-in-Docker"
  description  = "Run a dind sidecar and point DOCKER_HOST at it."
  type         = "bool"
  default      = "true"
  mutable      = false
}

data "coder_parameter" "stacks" {
  name         = "stacks"
  display_name = "Tool stacks"
  description  = "Omni tool groups to install in this workspace."
  type         = "list(string)"
  default      = jsonencode(["go"])
  mutable      = false
}

locals {
  stacks            = jsondecode(data.coder_parameter.stacks.value)
  enable_dind       = tobool(data.coder_parameter.enable_dind.value)
  enable_playwright = false
  repos             = split(",", data.coder_parameter.repos.value)
}
