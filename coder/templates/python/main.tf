# Python workspace. Shared providers, agent, pod, and modules live in
# common.tf, which the CI copies into this directory at template-push time.

data "coder_workspace_preset" "sonarr_season_reminder" {
  name = "sonarr-season-reminder"
  parameters = {
    repos = "git@github.com:lkshrk/sonarr-season-reminder.git"
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

locals {
  stacks            = ["python"]
  enable_dind       = tobool(data.coder_parameter.enable_dind.value)
  enable_playwright = false
  repos             = split(",", data.coder_parameter.repos.value)
}
