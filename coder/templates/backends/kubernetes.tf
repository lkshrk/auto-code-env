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

provider "kubernetes" {
  config_path = null
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

locals {
  backend_bootstrap = <<-SCRIPT
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
  SCRIPT
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
