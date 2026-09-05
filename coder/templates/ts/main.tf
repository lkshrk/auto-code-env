# TypeScript / Node workspace. Shared providers, agent, pod, and modules live
# in common.tf, which the CI copies into this directory at template-push time.

data "coder_workspace_preset" "skeletoni" {
  name = "skeletoni"
  parameters = {
    repos             = "git@github.com:lkshrk/skeletoni.git"
    enable_playwright = "true"
  }
}

data "coder_workspace_preset" "directus_extension_reply_to_mail" {
  name = "directus-extension-reply-to-mail"
  parameters = {
    repos = "git@github.com:lkshrk/directus-extension-reply-to-mail.git"
  }
}

data "coder_workspace_preset" "rybbit_oidc" {
  name = "rybbit-oidc"
  parameters = {
    repos             = "git@github.com:lkshrk/rybbit-oidc.git"
    enable_playwright = "true"
    deployment_url    = "https://analytics.h-cloud.io"
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

data "coder_parameter" "enable_playwright" {
  name         = "enable_playwright"
  display_name = "Playwright"
  description  = "Install shiplight + headless-chrome system libs on start."
  type         = "bool"
  default      = "false"
  mutable      = true
}

locals {
  stacks            = ["ts"]
  enable_dind       = tobool(data.coder_parameter.enable_dind.value)
  enable_playwright = tobool(data.coder_parameter.enable_playwright.value)
  repos             = split(",", data.coder_parameter.repos.value)
}
