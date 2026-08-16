# Shared providers, agent, pod, and modules for hermes-worker templates.
# Per-arch main.tf (hermes-worker-js, hermes-worker-py) defines only:
#   local.stacks   list(string)  Omni tool groups (fixed, not user-facing)
#
# Provisioned and driven by Hermes itself via `coder ssh <workspace> -- ...`
# for the hybrid orchestration model: Hermes runs only in the control hub
# (hermes-hq image, StatefulSet), never inside these workspaces. These
# templates exist to give Hermes isolated, disposable Coder workspaces to
# dispatch Claude Code / Codex tasks into against a target project repo -
# not for direct human/interactive use.
#
# Kept deliberately separate from lkshrk/h-cloud's human-developer Coder
# templates (routivo, civora, sveltekit, python, ts, ...): different
# audience (Hermes only), different push pipeline (this repo's own CI),
# and a different default posture (no coding-agent Coder modules baked in
# via Terraform - Claude Code / Codex are installed through the Omni
# `coder` host profile from lkshrk/dotfiles, same as every other workspace).

terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

provider "coder" {}

provider "kubernetes" {
  config_path = null
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# ---------------------------------------------------------------------------
# Shared parameters
# ---------------------------------------------------------------------------

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU (cores)"
  default      = "4"
  mutable      = true
  option {
    name  = "2 cores"
    value = "2"
  }
  option {
    name  = "4 cores"
    value = "4"
  }
  option {
    name  = "6 cores"
    value = "6"
  }
  option {
    name  = "8 cores"
    value = "8"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory (GiB)"
  default      = "8"
  mutable      = true
  option {
    name  = "4 GiB"
    value = "4"
  }
  option {
    name  = "8 GiB"
    value = "8"
  }
  option {
    name  = "16 GiB"
    value = "16"
  }
  option {
    name  = "24 GiB"
    value = "24"
  }
}

data "coder_parameter" "disk_size" {
  name         = "disk_size"
  display_name = "Home Disk (GiB)"
  description  = "Home disks use a 30 GiB minimum; legacy 10/20 GiB values are expanded automatically."
  default      = "30"
  mutable      = false
  option {
    name  = "10 GiB"
    value = "10"
  }
  option {
    name  = "20 GiB"
    value = "20"
  }
  option {
    name  = "30 GiB"
    value = "30"
  }
  option {
    name  = "50 GiB"
    value = "50"
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
  description  = "Run a dind sidecar and point DOCKER_HOST at it. Off by default - opt in only when the dispatched task actually needs Docker."
  type         = "bool"
  default      = "false"
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

data "coder_parameter" "deployment_url" {
  name         = "deployment_url"
  display_name = "Deployment URL"
  description  = "Public or LAN URL of this repo's cluster deployment. Used for live E2E and agent checks."
  default      = ""
  mutable      = true
}

# ---------------------------------------------------------------------------
# Derived locals
#
# Each template's main.tf MUST define:
#   local.stacks   list(string)  Omni tool groups to install (fixed per arch)
# ---------------------------------------------------------------------------

locals {
  workspace_owner_slug_base = lower(replace(data.coder_workspace_owner.me.name, "/[^a-zA-Z0-9-]/", "-"))
  workspace_name_slug_base  = lower(replace(data.coder_workspace.me.name, "/[^a-zA-Z0-9-]/", "-"))
  workspace_owner_slug      = trim(substr(trim(local.workspace_owner_slug_base, "-"), 0, 18), "-")
  workspace_name_slug       = trim(substr(trim(local.workspace_name_slug_base, "-"), 0, 18), "-")
  workspace_owner_label     = local.workspace_owner_slug != "" ? local.workspace_owner_slug : "user"
  workspace_name_label      = local.workspace_name_slug != "" ? local.workspace_name_slug : "workspace"
  workspace_hash            = substr(sha1("${data.coder_workspace_owner.me.name}/${data.coder_workspace.me.name}"), 0, 8)
  workspace_k8s_name        = "coder-${data.coder_workspace.me.template_name}-${local.workspace_owner_label}-${local.workspace_name_label}-${local.workspace_hash}"
  workspace_home_pvc_name   = "${local.workspace_k8s_name}-home"

  enable_dind       = tobool(data.coder_parameter.enable_dind.value)
  enable_playwright = tobool(data.coder_parameter.enable_playwright.value)
  deployment_url    = trimspace(data.coder_parameter.deployment_url.value)
  deployment_env = local.deployment_url != "" ? {
    DEPLOYMENT_URL           = local.deployment_url
    PLAYWRIGHT_LIVE_BASE_URL = local.deployment_url
  } : {}

  repos_set = data.coder_workspace.me.start_count > 0 ? toset([
    for r in split(",", data.coder_parameter.repos.value) : trimspace(r) if trimspace(r) != ""
  ]) : toset([])

  tmpdir = "/home/coder/.tmp"

  tmpdir_bootstrap = <<-SCRIPT
    set -e

    mkdir -p "${local.tmpdir}"
    chmod 700 "${local.tmpdir}"
  SCRIPT

  git_ssh_bootstrap = <<-SCRIPT
    set -e

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keyscan -t ed25519,rsa github.com codeberg.org 2>/dev/null >> "$HOME/.ssh/known_hosts"
    sort -u "$HOME/.ssh/known_hosts" -o "$HOME/.ssh/known_hosts"
    if ! grep -q '^Host github.com codeberg.org' "$HOME/.ssh/config" 2>/dev/null; then
      printf 'Host github.com codeberg.org\n  StrictHostKeyChecking accept-new\n' >> "$HOME/.ssh/config"
      chmod 600 "$HOME/.ssh/config"
    fi
  SCRIPT

  coder_dotfiles_bootstrap = <<-SCRIPT
    set -e

    ${local.tmpdir_bootstrap}

    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -qq
      apt_packages="build-essential ca-certificates curl git jq node-gyp nodejs npm openssh-client stow tmux unzip"
      case ",$CODER_OMNI_STACKS," in
        *,go,*) apt_packages="$apt_packages golang-go" ;;
      esac
      sudo apt-get install -y --no-install-recommends $apt_packages >/dev/null
    fi

    ${local.git_ssh_bootstrap}

    export CODER_DOTFILES_URL="https://github.com/lkshrk/dotfiles"
    export CODER_DOTFILES_SOURCE_DIR="$HOME/dotfiles"

    if [[ -d "$CODER_DOTFILES_SOURCE_DIR/.git" ]]; then
      git -C "$CODER_DOTFILES_SOURCE_DIR" remote set-url origin "$CODER_DOTFILES_URL"
      git -C "$CODER_DOTFILES_SOURCE_DIR" fetch --quiet origin
    else
      git clone --quiet "$CODER_DOTFILES_URL" "$CODER_DOTFILES_SOURCE_DIR"
    fi

    bash "$CODER_DOTFILES_SOURCE_DIR/setup-coder.sh"

    if [ "$CODER_ENABLE_PLAYWRIGHT" = "1" ]; then
      export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
      if command -v bun >/dev/null 2>&1; then
        bunx playwright install-deps chromium
      else
        npx -y playwright install-deps chromium
      fi
    fi
  SCRIPT
}

# ---------------------------------------------------------------------------
# Agent + Coder modules
#
# Deliberately NO claude-code / codex Coder modules here: those come from
# the Omni `coder` host profile (via setup-coder.sh above), same as every
# other h-cloud Coder template. This template's only job is to stand the
# workspace up; Hermes dispatches into it over `coder ssh` afterward.
# ---------------------------------------------------------------------------

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"
  startup_script = local.coder_dotfiles_bootstrap

  env = merge({
    GIT_AUTHOR_NAME     = data.coder_workspace_owner.me.full_name
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = data.coder_workspace_owner.me.full_name
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
    CODER_OMNI_HOST     = "coder"
    OMNI_HOSTNAME       = "coder"
    CODER_OMNI_STACKS   = join(",", local.stacks)
    CODER_REPO_DIRS = join(",", [
      for r in local.repos_set : trimsuffix(basename(r), ".git")
    ])
    CODER_ENABLE_PLAYWRIGHT = local.enable_playwright ? "1" : "0"
    GOCACHE                 = "/tmp/go-build"
    GOLANGCI_LINT_CACHE     = "/tmp/golangci-lint"

    TMPDIR                = local.tmpdir
    XDG_CACHE_HOME        = "/home/coder/.cache"
    XDG_DATA_HOME         = "/home/coder/.local/share"
    UV_CACHE_DIR          = "/home/coder/.cache/uv"
    npm_config_store_dir  = "/home/coder/.local/share/pnpm/store"
    pnpm_config_store_dir = "/home/coder/.local/share/pnpm/store"
  }, local.deployment_env)

  metadata {
    display_name = "CPU Usage"
    key          = "cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "Memory Usage"
    key          = "mem_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "Disk Usage"
    key          = "disk_usage"
    script       = "coder stat disk --path /home/coder"
    interval     = 60
    timeout      = 1
  }
}

module "git-clone" {
  for_each = local.repos_set
  source   = "registry.coder.com/coder/git-clone/coder"
  version  = "2.0.2"
  agent_id = coder_agent.main.id
  url      = each.value

  pre_clone_script = "${local.tmpdir_bootstrap}\n${local.git_ssh_bootstrap}"
}

# ---------------------------------------------------------------------------
# Storage + workspace pod
# ---------------------------------------------------------------------------

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = local.workspace_home_pvc_name
    namespace = "coder"
  }
  wait_until_bound = false
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "ceph-block"
    resources {
      requests = {
        storage = "${max(30, tonumber(data.coder_parameter.disk_size.value))}Gi"
      }
    }
  }
}

resource "kubernetes_pod_v1" "workspace" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = local.workspace_k8s_name
    namespace = "coder"
    labels = merge(
      {
        "app.kubernetes.io/name"       = "coder-workspace"
        "app.kubernetes.io/instance"   = local.workspace_k8s_name
        "app.kubernetes.io/managed-by" = "coder"
        "h-cloud.io/hermes-worker"     = "true"
      },
      local.enable_dind ? { "coder.h-cloud.io/docker-dind" = "true" } : {},
    )
  }

  spec {
    service_account_name            = "coder-workspace"
    automount_service_account_token = false

    security_context {
      fs_group = 1000
    }

    container {
      name              = "dev"
      image             = "codercom/enterprise-base:ubuntu"
      image_pull_policy = "IfNotPresent"
      command           = ["sh", "-c", coder_agent.main.init_script]

      security_context {
        run_as_user = 1000
      }

      env_from {
        secret_ref {
          name     = "coder-workspace-hermes-worker-env"
          optional = true
        }
      }

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }
      dynamic "env" {
        for_each = ["GH_TOKEN", "GITHUB_TOKEN", "GITHUB_PERSONAL_ACCESS_TOKEN"]
        content {
          name = env.value
          value_from {
            secret_key_ref {
              name     = "coder-workspace-secrets"
              key      = "GH_TOKEN"
              optional = true
            }
          }
        }
      }

      dynamic "env" {
        for_each = local.enable_dind ? [1] : []
        content {
          name  = "DOCKER_HOST"
          value = "tcp://localhost:2375"
        }
      }
      dynamic "env" {
        for_each = local.enable_dind ? [1] : []
        content {
          name  = "DOCKER_TLS_CERTDIR"
          value = ""
        }
      }

      resources {
        requests = {
          cpu    = "500m"
          memory = "${floor(tonumber(data.coder_parameter.memory.value) / 2)}Gi"
        }
        limits = {
          cpu    = data.coder_parameter.cpu.value
          memory = "${data.coder_parameter.memory.value}Gi"
        }
      }

      volume_mount {
        mount_path = "/home/coder"
        name       = "home"
      }
      volume_mount {
        mount_path = "/etc/ssl/lan"
        name       = "lan-ca"
        read_only  = true
      }
    }

    dynamic "container" {
      for_each = local.enable_dind ? [1] : []
      content {
        name              = "dind"
        image             = "docker:27-dind"
        image_pull_policy = "IfNotPresent"

        security_context {
          privileged  = true
          run_as_user = 0
        }

        env {
          name  = "DOCKER_TLS_CERTDIR"
          value = ""
        }

        resources {
          requests = {
            cpu    = "250m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "2"
            memory = "2Gi"
          }
        }

        volume_mount {
          mount_path = "/var/lib/docker"
          name       = "dind-storage"
        }
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
      }
    }

    volume {
      name = "lan-ca"
      config_map {
        name = "lan-root-ca"
        items {
          key  = "lan-root-ca.crt"
          path = "lan-ca.pem"
        }
      }
    }

    dynamic "volume" {
      for_each = local.enable_dind ? [1] : []
      content {
        name = "dind-storage"
        empty_dir {}
      }
    }
  }
}
