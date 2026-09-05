# Production SvelteKit website workspace. The dedicated template name selects
# namespace-scoped Kubernetes access to pub in common.tf.

data "coder_workspace_preset" "pfalz_herz" {
  name = "pfalz-herz"
  parameters = {
    repos             = "git@github.com:webdev-harke/pfalz-herz.git"
    enable_playwright = "true"
    deployment_url    = "https://pfalz-herz.pub.h-cloud.io"
  }
}

data "coder_workspace_preset" "pizzeria_riva" {
  name = "pizzeria-riva"
  parameters = {
    repos             = "git@github.com:webdev-harke/pizzeria-riva.git"
    enable_playwright = "true"
    deployment_url    = "https://pizzeria-riva.pub.h-cloud.io"
  }
}

data "coder_workspace_preset" "isc" {
  name = "isc"
  parameters = {
    repos             = "git@github.com:webdev-harke/ISC.git"
    enable_playwright = "true"
    deployment_url    = "https://isc.pub.h-cloud.io"
  }
}

data "coder_workspace_preset" "quintessenz" {
  name = "quintessenz"
  parameters = {
    repos             = "git@github.com:webdev-harke/quintessenz-horst.git"
    enable_playwright = "true"
    deployment_url    = "https://quintessenz-horst.de"
  }
}

data "coder_workspace_preset" "portfolio" {
  name = "portfolio"
  parameters = {
    repos             = "git@github.com:webdev-harke/portfolio.git"
    enable_playwright = "true"
    deployment_url    = "https://portfolio.harke.me"
  }
}

data "coder_parameter" "repos" {
  name         = "repos"
  display_name = "Repositories"
  description  = "Comma-separated git URLs to clone on first start."
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
  default      = "true"
  mutable      = true
}

locals {
  stacks            = ["ts"]
  enable_dind       = tobool(data.coder_parameter.enable_dind.value)
  enable_playwright = tobool(data.coder_parameter.enable_playwright.value)
  repos             = split(",", data.coder_parameter.repos.value)
}
