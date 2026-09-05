# Lua workspace. Shared providers, agent, pod, and modules live in common.tf,
# which the CI copies into this directory at template-push time.

data "coder_workspace_preset" "signal_cli_seerr_plugin" {
  name = "signal-cli-seerr-plugin"
  parameters = {
    repos = "git@github.com:lkshrk/signal-cli-seerr-plugin.git"
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
  default      = "false"
  mutable      = false
}

locals {
  stacks            = ["lua"]
  enable_dind       = tobool(data.coder_parameter.enable_dind.value)
  enable_playwright = false
  repos             = split(",", data.coder_parameter.repos.value)
}
