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
  stacks = distinct(concat(
    jsondecode(data.coder_parameter.stacks.value),
    tobool(data.coder_parameter.enable_dind.value) ? ["containers"] : [],
    tobool(data.coder_parameter.enable_playwright.value) ? ["ts"] : [],
  ))
  enable_dind       = tobool(data.coder_parameter.enable_dind.value)
  enable_playwright = tobool(data.coder_parameter.enable_playwright.value)
  repos             = split(",", data.coder_parameter.repos.value)
}
