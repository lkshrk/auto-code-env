provider "coder" {}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# ---------------------------------------------------------------------------
# Shared parameters (identical across every template)
# ---------------------------------------------------------------------------

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU (cores)"
  default      = "2"
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
  default      = "4"
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
    name  = "12 GiB"
    value = "12"
  }
  option {
    name  = "16 GiB"
    value = "16"
  }
  option {
    name  = "24 GiB"
    value = "24"
  }
  option {
    name  = "32 GiB"
    value = "32"
  }
}

data "coder_parameter" "dotfiles_url" {
  name         = "dotfiles_url"
  display_name = "Dotfiles Repo"
  default      = "https://github.com/lkshrk/dotfiles"
  mutable      = true
}

data "coder_parameter" "deployment_url" {
  name         = "deployment_url"
  display_name = "Deployment URL"
  description  = "Public or LAN URL of this repo's cluster deployment. Used for live E2E and agent checks."
  default      = ""
  mutable      = true
}

variable "workspace_image" {
  type    = string
  default = "codercom/enterprise-base:ubuntu"
}

variable "mcp_url" {
  type    = string
  default = ""
}

variable "omni_version" {
  type    = string
  default = "0.11.1"

  validation {
    condition     = can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+$", var.omni_version))
    error_message = "omni_version must be an exact stable release."
  }
}

variable "environment_mode_default" {
  type    = string
  default = "composable"

  validation {
    condition     = var.environment_mode_default == "composable"
    error_message = "environment_mode_default must be composable."
  }
}

data "coder_parameter" "environment_mode" {
  name         = "environment_mode"
  display_name = "Environment setup"
  default      = var.environment_mode_default
  mutable      = true
  option {
    name  = "Personal core and selected components"
    value = "composable"
  }
}

data "coder_parameter" "agent_clients" {
  name         = "agent_clients"
  display_name = "Optional agent clients"
  description  = "JSON list: claude, codex. Empty installs neither. Applies to composable setup."
  type         = "list(string)"
  default      = "[]"
  mutable      = true
}

data "coder_parameter" "agent_plugins" {
  name         = "agent_plugins"
  display_name = "Agent plugin tools"
  description  = "Auxiliary executables for selected clients. Does not install skills, hooks, marketplaces, or MCP registrations."
  type         = "bool"
  default      = "false"
  mutable      = true
}

data "coder_parameter" "enable_openhands" {
  name         = "enable_openhands"
  display_name = "OpenHands Agent Server"
  description  = "Private authenticated remote runtime; requires composable setup."
  type         = "bool"
  default      = "false"
  mutable      = true
}

# ---------------------------------------------------------------------------
# Derived locals
#
# Each template's main.tf MUST define these locals:
#   local.repos              list(string)  git URLs to clone (may be empty)
#   local.stacks             list(string)  extra omni groups to hard-sync (may be empty)
#   local.enable_dind        bool          run the docker-in-docker sidecar
#   local.enable_playwright  bool          install playwright chromium + OS deps
# ---------------------------------------------------------------------------

locals {
  backend    = fileexists("${path.module}/backend") ? trimspace(file("${path.module}/backend")) : "kubernetes"
  composable = data.coder_parameter.environment_mode.value == "composable"
  selected_stacks = distinct(concat(
    local.stacks,
    local.enable_dind ? ["containers"] : [],
    local.enable_playwright ? ["ts"] : [],
    tobool(data.coder_parameter.enable_openhands.value) ? ["python"] : [],
  ))
  agent_init_script = <<-SCRIPT
    ${file("${path.module}/shared/workspace-ca.sh")}
    export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.krew/bin:$HOME/.local/share/pnpm:$HOME/.local/share/pnpm/bin:$PATH"
    export CODER_START_ID=$(cat /proc/sys/kernel/random/uuid)
    ${coder_agent.main.init_script}
  SCRIPT

  workspace_owner_slug_base = lower(replace(data.coder_workspace_owner.me.name, "/[^a-zA-Z0-9-]/", "-"))
  workspace_name_slug_base  = lower(replace(data.coder_workspace.me.name, "/[^a-zA-Z0-9-]/", "-"))
  workspace_owner_slug      = trim(substr(trim(local.workspace_owner_slug_base, "-"), 0, 18), "-")
  workspace_name_slug       = trim(substr(trim(local.workspace_name_slug_base, "-"), 0, 18), "-")
  workspace_owner_label     = local.workspace_owner_slug != "" ? local.workspace_owner_slug : "user"
  workspace_name_label      = local.workspace_name_slug != "" ? local.workspace_name_slug : "workspace"
  workspace_hash            = substr(sha1("${data.coder_workspace_owner.me.name}/${data.coder_workspace.me.name}"), 0, 8)
  workspace_k8s_name        = "coder-${local.workspace_owner_label}-${local.workspace_name_label}-${local.workspace_hash}"
  workspace_home_pvc_name   = "${local.workspace_k8s_name}-home"
  workspace_env_secret_name = "${data.coder_workspace.me.template_name}-workspace-env"
  omni_host                 = "coder"
  deployment_url            = trimspace(data.coder_parameter.deployment_url.value)
  deployment_env = local.deployment_url != "" ? {
    DEPLOYMENT_URL           = local.deployment_url
    PLAYWRIGHT_LIVE_BASE_URL = local.deployment_url
  } : {}

  # Clean repo set, only while the workspace is running.
  repos_set = data.coder_workspace.me.start_count > 0 ? toset([
    for r in local.repos : trimspace(r) if trimspace(r) != ""
  ]) : toset([])

  workspace_service_account_name = "coder-workspace"
  workspace_kube_namespace       = "coder"

  repo_clone_dirs = join(",", [
    for r in local.repos_set : trimsuffix(basename(r), ".git")
  ])

  # Must stay on the home PVC: pnpm/uv hardlink from their stores into scratch
  # checkouts, and a cross-device TMPDIR silently degrades that to full copies.
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
    #!/usr/bin/env bash
    set -euo pipefail

    ${local.tmpdir_bootstrap}
    rm -f "$HOME/.local/state/coder-environment/readiness.json"

    ${local.backend_bootstrap}

    ${file("${path.module}/shared/workspace-ca.sh")}
    ${file("${path.module}/shared/install-base.sh")}
    coder_install_system_ca

    ${local.git_ssh_bootstrap}

    export CODER_DOTFILES_URL="$CODER_CONFIGURED_DOTFILES_URL"
    export CODER_DOTFILES_SOURCE_DIR="$HOME/dotfiles"

    ${file("${path.module}/shared/prepare-dotfiles.sh")}

    export CODER_DOTFILES_REVISION=$(git -C "$CODER_DOTFILES_SOURCE_DIR" rev-parse HEAD)
    if [ ! -f "$CODER_DOTFILES_SOURCE_DIR/setup-coder-dots.sh" ]; then
      printf '%s\n' "Composable setup requires updated dotfiles. Update the preserved checkout at $CODER_DOTFILES_SOURCE_DIR explicitly." >&2
      exit 1
    fi
    mkdir -p "$HOME/.local/state/coder-environment"
    export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.krew/bin:$HOME/.local/share/pnpm:$HOME/.local/share/pnpm/bin:$PATH"
    printf '%s' '${base64encode(file("${path.module}/shared/dotfiles-contract.py"))}' | base64 --decode > "$HOME/.local/state/coder-environment/dotfiles-contract.py"
    python3 "$HOME/.local/state/coder-environment/dotfiles-contract.py" "$CODER_DOTFILES_SOURCE_DIR"
    printf '%s' '${base64encode(file("${path.module}/shared/components.py"))}' | base64 --decode > "$HOME/.local/state/coder-environment/components.py"
    python3 "$HOME/.local/state/coder-environment/components.py" validate --report "$HOME/.local/state/coder-environment/readiness.json"
    python3 "$HOME/.local/state/coder-environment/components.py" wait-repositories

    # Stack/tool catalog + install: owned by this repository, not dotfiles
    # (see stack-install.py). Runs before dotfiles' own script so `omni` is
    # already on PATH by the time it gets there.
    printf '%s' '${base64encode(file("${path.module}/shared/catalog.json"))}' | base64 --decode > "$HOME/.local/state/coder-environment/catalog.json"
    printf '%s' '${base64encode(file("${path.module}/shared/linux-tools.json"))}' | base64 --decode > "$HOME/.local/state/coder-environment/linux-tools.json"
    printf '%s' '${base64encode(file("${path.module}/shared/coder-neovim.py"))}' | base64 --decode > "$HOME/.local/state/coder-environment/coder-neovim.py"
    printf '%s' '${base64encode(file("${path.module}/shared/stack-install.py"))}' | base64 --decode > "$HOME/.local/state/coder-environment/stack-install.py"
    printf '%s' '${base64encode(file("${path.module}/shared/install-stacks.py"))}' | base64 --decode > "$HOME/.local/state/coder-environment/install-stacks.py"
    python3 "$HOME/.local/state/coder-environment/install-stacks.py"

    # Personal dots only from here: language stacks/tool packages are already
    # installed above.
    bash "$CODER_DOTFILES_SOURCE_DIR/setup-coder-dots.sh"

    # No browser preinstall: shiplight and each project's @playwright/test
    # fetch their own pinned revision on demand into ~/.cache/ms-playwright on
    # the home PVC. Only the headless-chrome system libs are missing from the
    # base image — install-deps covers those, version-stable. bun-first (omni
    # ts stack provides it; its shims are not on this script's PATH).
    if [ "$CODER_ENABLE_PLAYWRIGHT" = "1" ]; then
      if command -v bun >/dev/null 2>&1; then
        bunx playwright@1.63.0 install-deps chromium
      else
        npx -y playwright@1.63.0 install-deps chromium
      fi
    fi

    python3 "$HOME/.local/state/coder-environment/components.py" check
    ${module.openhands.startup_script}
    python3 "$HOME/.local/state/coder-environment/components.py" check --report "$HOME/.local/state/coder-environment/readiness.json"
  SCRIPT
}

module "openhands" {
  source            = "./modules/openhands"
  enabled           = tobool(data.coder_parameter.enable_openhands.value)
  working_directory = length(local.repos_set) == 1 ? "/home/coder/${local.repo_clone_dirs}" : ""
}

# ---------------------------------------------------------------------------
# Agent + Coder modules
# ---------------------------------------------------------------------------

resource "coder_agent" "main" {
  os                      = "linux"
  arch                    = "amd64"
  startup_script          = local.coder_dotfiles_bootstrap
  startup_script_behavior = "blocking"

  lifecycle {
    precondition {
      condition     = local.composable
      error_message = "Dev requires composable environment setup."
    }
    precondition {
      condition     = length(distinct([for repo in local.repos_set : trimsuffix(basename(repo), ".git")])) == length(local.repos_set)
      error_message = "Repositories must have distinct checkout directory names."
    }
  }

  env = merge({
    GIT_AUTHOR_NAME               = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL              = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME            = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL           = data.coder_workspace_owner.me.email
    CODER_OMNI_HOST               = local.omni_host
    OMNI_HOSTNAME                 = local.omni_host
    CODER_OMNI_STACKS             = join(",", local.selected_stacks)
    CODER_ENVIRONMENT_MODE        = data.coder_parameter.environment_mode.value
    CODER_BACKEND                 = local.backend
    CODER_CONFIGURED_DOTFILES_URL = data.coder_parameter.dotfiles_url.value
    CODER_AGENT_CLIENTS           = join(",", jsondecode(data.coder_parameter.agent_clients.value))
    CODER_AGENT_PLUGINS           = tobool(data.coder_parameter.agent_plugins.value) ? "1" : "0"
    CODER_ENABLE_OPENHANDS        = tobool(data.coder_parameter.enable_openhands.value) ? "1" : "0"
    CODER_ENABLE_DIND             = local.enable_dind ? "1" : "0"
    CODER_MCP_URL                 = var.mcp_url
    CODER_REPO_KEYS               = join(",", [for repo in local.repos_set : sha256(repo)])
    CODER_REPO_DIRS               = local.repo_clone_dirs
    CODER_ENABLE_PLAYWRIGHT       = local.enable_playwright ? "1" : "0"
    ECC_GATEGUARD                 = "off"
    GOCACHE                       = "/tmp/go-build"
    GOLANGCI_LINT_CACHE           = "/tmp/golangci-lint"
    OMNI_OTEL_CA_PATH             = "/etc/ssl/lan/lan-ca.pem"

    TMPDIR = local.tmpdir
    # Pinned to their current defaults so a future upstream default cannot move
    # a content-addressable store off the home PVC onto the ephemeral overlay.
    XDG_CACHE_HOME = "/home/coder/.cache"
    XDG_DATA_HOME  = "/home/coder/.local/share"
    UV_CACHE_DIR   = "/home/coder/.cache/uv"
    # pnpm 11 reads pnpm_config_*; npm_config_* is the pre-11 spelling. pnpm
    # appends its own store version suffix, so this resolves to .../store/v11.
    npm_config_store_dir  = "/home/coder/.local/share/pnpm/store"
    pnpm_config_store_dir = "/home/coder/.local/share/pnpm/store"
    }, local.deployment_env, {
    OMNI_VERSION = var.omni_version
    SHELL        = "/usr/bin/zsh"
    EDITOR       = "nvim"
    VISUAL       = "nvim"
  })

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

module "git-commit-signing" {
  source   = "registry.coder.com/coder/git-commit-signing/coder"
  version  = "1.0.32"
  agent_id = coder_agent.main.id
}

module "git-clone" {
  for_each = local.repos_set
  source   = "registry.coder.com/coder/git-clone/coder"
  version  = "2.0.3"
  agent_id = coder_agent.main.id
  url      = each.value

  # The git-clone module runs as its own agent script, in parallel with the
  # main dotfiles bootstrap. Seed host keys here too so SSH clones do not race
  # the main startup script and fail with "Host key verification failed".
  pre_clone_script  = "${local.tmpdir_bootstrap}\n${local.git_ssh_bootstrap}"
  post_clone_script = <<-SCRIPT
    set -e
    git rev-parse --is-inside-work-tree >/dev/null
    if [ -n "$CODER_START_ID" ]; then
      mkdir -p "$HOME/.local/state/coder-environment/clones/$CODER_START_ID"
      touch "$HOME/.local/state/coder-environment/clones/$CODER_START_ID/${sha256(each.value)}"
    fi
  SCRIPT
}
