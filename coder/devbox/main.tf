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

locals {
  image_version = "latest" # renovate: datasource=github-tags depName=lkshrk/auto-code-env
}

data "coder_parameter" "variant" {
  name         = "variant"
  display_name = "Image variant"
  default      = "full"
  mutable      = true
  option {
    name  = "full (all languages)"
    value = "full"
  }
  option {
    name  = "go"
    value = "go"
  }
  option {
    name  = "python"
    value = "python"
  }
  option {
    name  = "ts"
    value = "ts"
  }
  option {
    name  = "lua"
    value = "lua"
  }
}

data "coder_parameter" "access" {
  name         = "access"
  display_name = "Cluster access profile"
  default      = "base"
  mutable      = false
  option {
    name  = "base (coder namespace)"
    value = "base"
  }
  option {
    name  = "civora"
    value = "civora"
  }
  option {
    name  = "routivo"
    value = "routivo"
  }
  option {
    name  = "pub"
    value = "pub"
  }
}

data "coder_parameter" "repos" {
  name         = "repos"
  display_name = "Repositories"
  description  = "Comma-separated git URLs to clone on first start."
  default      = ""
  mutable      = true
}

data "coder_parameter" "deployment_url" {
  name         = "deployment_url"
  display_name = "Deployment URL"
  default      = ""
  mutable      = true
}

data "coder_parameter" "enable_dind" {
  name         = "enable_dind"
  display_name = "Docker-in-Docker"
  type         = "bool"
  default      = "false"
  mutable      = false
}

data "coder_parameter" "enable_playwright" {
  name         = "enable_playwright"
  display_name = "Playwright (shiplight)"
  type         = "bool"
  default      = "false"
  mutable      = true
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU (cores)"
  default      = "4"
  mutable      = true
  option {
    name  = "2"
    value = "2"
  }
  option {
    name  = "4"
    value = "4"
  }
  option {
    name  = "6"
    value = "6"
  }
  option {
    name  = "8"
    value = "8"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory (GiB)"
  default      = "8"
  mutable      = true
  option {
    name  = "4"
    value = "4"
  }
  option {
    name  = "8"
    value = "8"
  }
  option {
    name  = "16"
    value = "16"
  }
  option {
    name  = "32"
    value = "32"
  }
}

data "coder_parameter" "disk_size" {
  name         = "disk_size"
  display_name = "Home disk (GiB)"
  default      = "30"
  mutable      = false
  option {
    name  = "30"
    value = "30"
  }
  option {
    name  = "50"
    value = "50"
  }
}

data "coder_parameter" "dotfiles_url" {
  name         = "dotfiles_url"
  display_name = "Dotfiles repo"
  default      = "https://github.com/lkshrk/dotfiles.git"
  mutable      = true
}

locals {
  owner_slug = trim(substr(trim(lower(replace(data.coder_workspace_owner.me.name, "/[^a-zA-Z0-9-]/", "-")), "-"), 0, 18), "-")
  ws_slug    = trim(substr(trim(lower(replace(data.coder_workspace.me.name, "/[^a-zA-Z0-9-]/", "-")), "-"), 0, 18), "-")
  ws_hash    = substr(sha1("${data.coder_workspace_owner.me.name}/${data.coder_workspace.me.name}"), 0, 8)
  k8s_name   = "coder-${local.owner_slug != "" ? local.owner_slug : "user"}-${local.ws_slug != "" ? local.ws_slug : "workspace"}-${local.ws_hash}"
  pvc_name   = "${local.k8s_name}-home"

  access      = data.coder_parameter.access.value
  sa_name     = local.access == "base" ? "coder-workspace" : "coder-workspace-${local.access}"
  kube_ns     = local.access == "base" ? "coder" : local.access
  enable_dind = tobool(data.coder_parameter.enable_dind.value)
  image       = "ghcr.io/lkshrk/devbox/${data.coder_parameter.variant.value}:${local.image_version}"

  repos_set = data.coder_workspace.me.start_count > 0 ? toset([for r in split(",", data.coder_parameter.repos.value) : trimspace(r) if trimspace(r) != ""]) : toset([])
  repo_dirs = join(",", [for r in local.repos_set : trimsuffix(basename(r), ".git")])

  deployment     = trimspace(data.coder_parameter.deployment_url.value)
  deployment_env = local.deployment != "" ? { DEPLOYMENT_URL = local.deployment, PLAYWRIGHT_LIVE_BASE_URL = local.deployment } : {}

  startup = <<-SCRIPT
    set -eu
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
          namespace: ${local.kube_ns}
          user: ${local.sa_name}
    current-context: h-cloud
    users:
      - name: ${local.sa_name}
        user:
          tokenFile: /var/run/secrets/coder-workspace/token
    KUBECONFIG
    umask 022
    export DEVBOX_DOTFILES_URL="${data.coder_parameter.dotfiles_url.value}"
    devbox-init true
    bash "$HOME/dotfiles/setup-coder.sh"
  SCRIPT
}

resource "coder_agent" "main" {
  os             = "linux"
  arch           = "amd64"
  startup_script = local.startup

  env = merge({
    GIT_AUTHOR_NAME         = data.coder_workspace_owner.me.full_name
    GIT_AUTHOR_EMAIL        = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME      = data.coder_workspace_owner.me.full_name
    GIT_COMMITTER_EMAIL     = data.coder_workspace_owner.me.email
    CODER_REPO_DIRS         = local.repo_dirs
    CODER_ENABLE_PLAYWRIGHT = tobool(data.coder_parameter.enable_playwright.value) ? "1" : "0"
    KUBECONFIG              = "/home/dev/.kube/h-cloud"
    OMNI_OTEL_CA_PATH       = "/etc/ssl/lan/lan-ca.pem"
  }, local.deployment_env)

  metadata {
    display_name = "CPU"
    key          = "cpu"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "RAM"
    key          = "mem"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "Disk"
    key          = "disk"
    script       = "coder stat disk --path /home/dev"
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
  for_each         = local.repos_set
  source           = "registry.coder.com/coder/git-clone/coder"
  version          = "2.0.3"
  agent_id         = coder_agent.main.id
  url              = each.value
  pre_clone_script = "mkdir -p $HOME/.ssh; chmod 700 $HOME/.ssh; ssh-keyscan -t ed25519,rsa github.com codeberg.org 2>/dev/null >> $HOME/.ssh/known_hosts; sort -u $HOME/.ssh/known_hosts -o $HOME/.ssh/known_hosts"
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = local.pvc_name
    namespace = "coder"
  }
  wait_until_bound = false
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "ceph-block"
    resources {
      requests = {
        storage = "${data.coder_parameter.disk_size.value}Gi"
      }
    }
  }
}

resource "kubernetes_pod_v1" "workspace" {
  count = data.coder_workspace.me.start_count
  metadata {
    name      = local.k8s_name
    namespace = "coder"
    labels = merge(
      {
        "app.kubernetes.io/name"       = "coder-workspace"
        "app.kubernetes.io/instance"   = local.k8s_name
        "app.kubernetes.io/managed-by" = "coder"
      },
      local.enable_dind ? { "coder.h-cloud.io/docker-dind" = "true" } : {},
    )
  }
  spec {
    service_account_name            = local.sa_name
    automount_service_account_token = false
    security_context {
      fs_group = 1000
    }

    container {
      name              = "dev"
      image             = local.image
      image_pull_policy = "IfNotPresent"
      command           = ["sh", "-c", coder_agent.main.init_script]
      security_context {
        run_as_user = 1000
      }

      env_from {
        secret_ref {
          name     = "coder-workspace-secrets"
          optional = true
        }
      }
      env_from {
        secret_ref {
          name     = "${local.access}-workspace-env"
          optional = true
        }
      }
      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }
      env {
        name  = "DEVBOX_DOTS"
        value = "1"
      }

      dynamic "env" {
        for_each = ["GITHUB_TOKEN", "GITHUB_PERSONAL_ACCESS_TOKEN"]
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
        for_each = local.enable_dind ? { DOCKER_HOST = "tcp://localhost:2375", DOCKER_TLS_CERTDIR = "" } : {}
        content {
          name  = env.key
          value = env.value
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
        mount_path = "/home/dev"
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
