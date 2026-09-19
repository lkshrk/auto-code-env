data "coder_parameter" "repos" {
  name         = "repos"
  display_name = "Repositories"
  description  = "Comma-separated Git URLs with distinct repository names. Existing checkouts are preserved."
  default      = ""
  mutable      = true
}

data "coder_parameter" "stacks" {
  name         = "stacks"
  display_name = "Tool stacks"
  description  = "Combine go, python, ts, lua, rust, k8s, gitops, argo, talos, cilium, cnpg, iac, containers, quality, terminal-recording, media. Tool selection never grants credentials."
  type         = "list(string)"
  default      = "[]"
  mutable      = true
}

data "coder_parameter" "enable_dind" {
  name         = "enable_dind"
  display_name = "Docker engine"
  description  = "Run a dedicated privileged Docker-in-Docker service. Not required for Kubernetes client tools."
  type         = "bool"
  default      = "false"
  mutable      = false
}

data "coder_parameter" "enable_playwright" {
  name         = "enable_playwright"
  display_name = "Browser testing"
  description  = "Install Chromium system dependencies; projects retain their own pinned Playwright/browser versions."
  type         = "bool"
  default      = "false"
  mutable      = true
}

data "coder_parameter" "wow_dev" {
  name         = "wow_dev"
  display_name = "WoW addon development"
  description  = "Installs the WoW API annotations for lua-language-server (wow-luarc), a luacheck default with the game's globals, Blizzard's FrameXML checkout, and wow-sync, which pushes addons over SFTP to the desktop. Needs the Coder secret wow-sync-key at ~/.ssh/wow-sync."
  type         = "bool"
  default      = "false"
  mutable      = true
}

data "coder_parameter" "wow_host" {
  name         = "wow_host"
  display_name = "WoW sync host"
  description  = "Desktop running `rclone serve sftp` on port 2022 (h-cloud `just talos wow-sync-server`)."
  default      = "172.16.20.195"
  mutable      = true
}

data "coder_parameter" "wow_host_key" {
  name         = "wow_host_key"
  display_name = "WoW sync host key"
  description  = "Pinned SSH host key of the sync server, as printed by `just talos wow-sync-server`. Empty disables host key validation."
  default      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHDnguPJQk3EhKB6RtdL8+Tu67tVSaoLHOTRWdBzaHtt"
  mutable      = true
}

data "coder_parameter" "wow_addons_path" {
  name         = "wow_addons_path"
  display_name = "WoW AddOns path"
  description  = "Path of the game's Interface/AddOns directory on the sync server. The desktop server serves AddOns itself, so `/`."
  default      = "/"
  mutable      = true
}

data "coder_parameter" "wow_dev_suffix" {
  name         = "wow_dev_suffix"
  display_name = "WoW dev suffix"
  description  = "Installs each addon as <Name>-<suffix> with its SavedVariables renamed, so the dev copy runs beside the released one and never touches its settings. Empty syncs under the real name."
  default      = "Dev"
  mutable      = true
}

data "coder_workspace_preset" "wow" {
  name = "wow"
  parameters = {
    stacks  = jsonencode(["lua"])
    wow_dev = "true"
  }
}

data "coder_workspace_preset" "go_python_k8s" {
  name = "go-python-k8s"
  parameters = {
    stacks = jsonencode(["go", "python", "k8s"])
    cpu    = "4"
    memory = "8"
  }
}

data "coder_workspace_preset" "full_stack" {
  name = "full-stack"
  parameters = {
    stacks            = jsonencode(["go", "python", "ts"])
    enable_dind       = "true"
    enable_playwright = "true"
    cpu               = "4"
    memory            = "8"
  }
}

data "coder_workspace_preset" "infrastructure" {
  name = "infrastructure"
  parameters = {
    stacks = jsonencode(["k8s", "gitops", "iac", "quality"])
  }
}

locals {
  stacks            = jsondecode(data.coder_parameter.stacks.value)
  enable_dind       = tobool(data.coder_parameter.enable_dind.value)
  enable_playwright = tobool(data.coder_parameter.enable_playwright.value)
  repos             = split(",", data.coder_parameter.repos.value)
  wow_dev           = tobool(data.coder_parameter.wow_dev.value)
  wow_host          = trimspace(data.coder_parameter.wow_host.value)
  wow_host_key      = trimspace(data.coder_parameter.wow_host_key.value)
  wow_addons_path   = trimspace(data.coder_parameter.wow_addons_path.value)
  wow_dev_suffix    = trimspace(data.coder_parameter.wow_dev_suffix.value)
}
