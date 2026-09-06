# Workspaces as Docker containers on the Windows desktop; backends/docker.tf is selected by the `backend` marker.

data "coder_workspace_preset" "monorepo" {
  name    = "monorepo"
  default = true
  parameters = {
    stacks            = jsonencode(["python", "ts", "infra"])
    enable_playwright = "true"
  }
}

data "coder_workspace_preset" "wow" {
  name = "wow"
  parameters = {
    stacks      = jsonencode(["lua"])
    enable_dind = "false"
  }
}

data "coder_parameter" "repos" {
  name         = "repos"
  display_name = "Repositories"
  description  = "Comma-separated git URLs to clone on first start. Leave empty for none."
  default      = ""
  mutable      = true
}

data "coder_parameter" "stacks" {
  name         = "stacks"
  display_name = "Tool stacks"
  description  = "Omni tool groups to install in this workspace."
  type         = "list(string)"
  default      = jsonencode(["ts"])
  mutable      = false
}

data "coder_parameter" "enable_dind" {
  name         = "enable_dind"
  display_name = "Docker-in-Docker"
  description  = "Run a dind sidecar and point DOCKER_HOST at it."
  type         = "bool"
  default      = "true"
  mutable      = false
}

data "coder_parameter" "enable_playwright" {
  name         = "enable_playwright"
  display_name = "Playwright"
  description  = "Install shiplight + headless-chrome system libs on start."
  type         = "bool"
  default      = "false"
  mutable      = true
}

data "coder_parameter" "wow_addons_path" {
  name         = "wow_addons_path"
  display_name = "WoW AddOns directory"
  description  = "Host path to the game's Interface/AddOns directory, e.g. /mnt/c/Games/World of Warcraft/_retail_/Interface/AddOns. Empty disables the mount."
  default      = ""
  mutable      = false
}

locals {
  stacks            = jsondecode(data.coder_parameter.stacks.value)
  enable_dind       = tobool(data.coder_parameter.enable_dind.value)
  enable_playwright = tobool(data.coder_parameter.enable_playwright.value)
  repos             = split(",", data.coder_parameter.repos.value)

  wow_addons_host_path = trimspace(data.coder_parameter.wow_addons_path.value)
}
