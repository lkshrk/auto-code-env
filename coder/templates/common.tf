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
  omni_host                 = data.coder_workspace.me.template_name == "hermes" ? "hermes" : "coder"
  deployment_url            = trimspace(data.coder_parameter.deployment_url.value)
  deployment_env = local.deployment_url != "" ? {
    DEPLOYMENT_URL           = local.deployment_url
    PLAYWRIGHT_LIVE_BASE_URL = local.deployment_url
  } : {}

  # Clean repo set, only while the workspace is running.
  repos_set = data.coder_workspace.me.start_count > 0 ? toset([
    for r in local.repos : trimspace(r) if trimspace(r) != ""
  ]) : toset([])

  workspace_access_profile = (
    data.coder_workspace.me.template_name == "civora" ? "civora" :
    data.coder_workspace.me.template_name == "routivo" ? "routivo" :
    data.coder_workspace.me.template_name == "sveltekit" ? "pub" :
    "base"
  )
  workspace_service_account_name = local.workspace_access_profile == "base" ? "coder-workspace" : "coder-workspace-${local.workspace_access_profile}"
  workspace_kube_namespace       = local.workspace_access_profile == "base" ? "coder" : local.workspace_access_profile

  # Folder names the git-clone module produces under $HOME (basename minus
  # .git); setup-coder.sh activates each repo's lefthook hooks from this list.
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
    set -e

    ${local.tmpdir_bootstrap}

    umask 077
    mkdir -p "$HOME/.kube"
    cat > "$HOME/.kube/h-cloud" <<'KUBECONFIG'
    apiVersion: v1
    kind: Config
    clusters:
      - name: h-cloud
        cluster:
          certificate-authority: /var/run/secrets/coder-workspace/ca.crt
          server: https://kubernetes.default.svc
    contexts:
      - name: h-cloud
        context:
          cluster: h-cloud
          namespace: ${local.workspace_kube_namespace}
          user: ${local.workspace_service_account_name}
    current-context: h-cloud
    users:
      - name: ${local.workspace_service_account_name}
        user:
          tokenFile: /var/run/secrets/coder-workspace/token
    KUBECONFIG

    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -qq
      apt_packages="build-essential ca-certificates curl git jq node-gyp nodejs npm openssh-client stow tmux unzip"
      case ",$CODER_OMNI_STACKS," in
        *,go,*) apt_packages="$apt_packages golang-go" ;;
      esac
      sudo apt-get install -y --no-install-recommends $apt_packages >/dev/null
    fi

    ${local.git_ssh_bootstrap}

    export CODER_DOTFILES_URL="${data.coder_parameter.dotfiles_url.value}"
    export CODER_DOTFILES_SOURCE_DIR="$HOME/dotfiles"

    ${file("${path.module}/shared/prepare-dotfiles.sh")}

    # Omni owns Codex; remove the raw binary left by the retired Coder module.
    [ -L "$HOME/.local/bin/codex" ] || rm -f "$HOME/.local/bin/codex"

    bash "$CODER_DOTFILES_SOURCE_DIR/setup-coder.sh"

    # No browser preinstall: shiplight and each project's @playwright/test
    # fetch their own pinned revision on demand into ~/.cache/ms-playwright on
    # the home PVC. Only the headless-chrome system libs are missing from the
    # base image — install-deps covers those, version-stable. bun-first (omni
    # ts stack provides it; its shims are not on this script's PATH).
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
# ---------------------------------------------------------------------------

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"
  startup_script = local.coder_dotfiles_bootstrap

  env = merge({
    GIT_AUTHOR_NAME         = data.coder_workspace_owner.me.full_name
    GIT_AUTHOR_EMAIL        = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME      = data.coder_workspace_owner.me.full_name
    GIT_COMMITTER_EMAIL     = data.coder_workspace_owner.me.email
    CODER_OMNI_HOST         = local.omni_host
    OMNI_HOSTNAME           = local.omni_host
    CODER_OMNI_STACKS       = join(",", local.stacks)
    CODER_REPO_DIRS         = local.repo_clone_dirs
    CODER_ENABLE_PLAYWRIGHT = local.enable_playwright ? "1" : "0"
    ECC_GATEGUARD           = "off"
    GOCACHE                 = "/tmp/go-build"
    GOLANGCI_LINT_CACHE     = "/tmp/golangci-lint"
    OMNI_OTEL_CA_PATH       = "/etc/ssl/lan/lan-ca.pem"

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
      },
      data.coder_workspace.me.template_name == "hermes" ? {
        "h-cloud.io/coder-connect-protected" = "true"
        "h-cloud.io/signal-client"           = "hermes"
      } : {},
      local.enable_dind ? { "coder.h-cloud.io/docker-dind" = "true" } : {},
    )
  }

  spec {
    service_account_name            = local.workspace_service_account_name
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
          name     = local.workspace_env_secret_name
          optional = true
        }
      }

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }
      env {
        name  = "KUBECONFIG"
        value = "/home/coder/.kube/h-cloud"
      }
      env {
        name = "LITELLM_API"
        value_from {
          secret_key_ref {
            name     = "coder-workspace-secrets"
            key      = "LITELLM_API"
            optional = true
          }
        }
      }
      # One GitHub PAT, three env names: gh CLI reads GH_TOKEN, generic tools
      # read GITHUB_TOKEN, github-mcp-server reads GITHUB_PERSONAL_ACCESS_TOKEN.
      # Git clones stay on Coder's per-user SSH key; this is for API access.
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
      volume_mount {
        mount_path = "/var/run/secrets/coder-workspace"
        name       = "kube-api-access"
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

    volume {
      name = "kube-api-access"
      projected {
        default_mode = "0444"
        sources {
          service_account_token {
            path               = "token"
            expiration_seconds = 3600
          }
        }
        sources {
          config_map {
            name = "kube-root-ca.crt"
            items {
              key  = "ca.crt"
              path = "ca.crt"
            }
          }
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
