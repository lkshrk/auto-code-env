terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "2.18.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.2.1"
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

data "coder_parameter" "dind_disk" {
  name         = "dind_disk"
  display_name = "Docker Disk (GiB)"
  description  = "Size of the DinD sidecar's /var/lib/docker. A separate Ceph volume that is created on start and deleted on stop, so Docker hitting it full fails a build instead of filling the node."
  type         = "number"
  default      = "40"
  mutable      = true
  validation {
    min = 10
    max = 200
  }
}

data "coder_parameter" "location" {
  name         = "location"
  display_name = "Location"
  description  = "cluster: Ceph-backed home, runs on the desktop VM k8s-12 whenever it is up and on any other node otherwise. desktop: pinned to k8s-12 with a node-local NVMe home, unavailable while the desktop is off."
  default      = "cluster"
  mutable      = false
  option {
    name  = "Cluster"
    value = "cluster"
  }
  option {
    name  = "Desktop (towerr)"
    value = "desktop"
  }
}

data "coder_workspace_preset" "desktop" {
  name = "desktop"
  parameters = {
    location = "desktop"
  }
}

locals {
  # docker volume prune is separate: "until" is not accepted together with --volumes.
  dind_entrypoint    = <<-SCRIPT
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'JSON'
    {"builder":{"gc":{"enabled":true,"defaultKeepStorage":"10GB"}},"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}
    JSON
    (
      while sleep 21600; do
        docker -H unix:///var/run/docker.sock system prune -f --filter until=48h
        docker -H unix:///var/run/docker.sock volume prune -f
      done
    ) &
    exec dockerd-entrypoint.sh
  SCRIPT
  desktop            = data.coder_parameter.location.value == "desktop"
  home_storage_class = local.desktop ? "openebs-hostpath" : "ceph-block"
  node_selector      = local.desktop ? { dedicated = "towerr" } : {}
  backend_bootstrap  = <<-SCRIPT
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
    storage_class_name = local.home_storage_class
    resources {
      requests = {
        storage = "${max(30, tonumber(data.coder_parameter.disk_size.value))}Gi"
      }
    }
  }
}

# Lives only while the workspace runs: stop destroys it with the pod.
resource "kubernetes_persistent_volume_claim_v1" "dind" {
  count = local.enable_dind ? data.coder_workspace.me.start_count : 0

  metadata {
    name      = "${local.workspace_k8s_name}-dind"
    namespace = "coder"
  }
  wait_until_bound = false
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "ceph-block"
    resources {
      requests = {
        storage = "${data.coder_parameter.dind_disk.value}Gi"
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
      local.enable_dind ? { "coder.h-cloud.io/docker-dind" = "true" } : {},
    )
  }

  spec {
    service_account_name            = local.workspace_service_account_name
    automount_service_account_token = false
    node_selector                   = local.node_selector

    toleration {
      key      = "dedicated"
      operator = "Equal"
      value    = "towerr"
      effect   = "NoSchedule"
    }

    dynamic "affinity" {
      for_each = local.desktop ? [] : [1]
      content {
        node_affinity {
          preferred_during_scheduling_ignored_during_execution {
            weight = 100
            preference {
              match_expressions {
                key      = "dedicated"
                operator = "In"
                values   = ["towerr"]
              }
            }
          }
        }
      }
    }

    security_context {
      fs_group = 1000
    }

    container {
      name              = "dev"
      image             = var.workspace_image
      image_pull_policy = "IfNotPresent"
      command           = ["sh", "-c", local.agent_init_script]

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
      # Only github-identity (gh shim, git credential helper) is meant to read these two.
      env {
        name = "GH_TOKEN"
        value_from {
          secret_key_ref {
            name     = "coder-workspace-secrets"
            key      = "GH_TOKEN"
            optional = true
          }
        }
      }
      env {
        name = "GH_TOKEN_PERSONAL"
        value_from {
          secret_key_ref {
            name     = "coder-workspace-secrets"
            key      = "GH_TOKEN_PERSONAL"
            optional = true
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
        command           = ["sh", "-c", local.dind_entrypoint]

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
        persistent_volume_claim {
          claim_name = kubernetes_persistent_volume_claim_v1.dind[0].metadata[0].name
        }
      }
    }
  }
}
