terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 4.0"
    }
  }
}

variable "docker_host" {
  type        = string
  description = "Docker API endpoint of the workspace host."
  default     = "tcp://172.16.20.195:2376"
}

variable "docker_cert_path" {
  type        = string
  description = "Directory in the coderd pod holding ca.pem, cert.pem and key.pem for the Docker API."
  default     = "/etc/coder/docker-tls"
}

provider "docker" {
  host      = var.docker_host
  cert_path = var.docker_cert_path

  # Without this, provider configure pings the daemon and every template import fails while the desktop sleeps.
  disable_docker_daemon_check = true
}

locals {
  backend_bootstrap = ""

  # Host-side env file from Vaultwarden (coder-worker-overlay); exported line by line so values are never evaluated.
  workspace_env_file   = "/run/coder-worker/workspace.env"
  workspace_entrypoint = <<-EOT
    while IFS= read -r line || [ -n "$line" ]; do
      case $line in ''|'#'*) continue ;; esac
      export "$line"
    done < ${local.workspace_env_file}
    ${coder_agent.main.init_script}
  EOT
}

resource "docker_volume" "home" {
  name = "${local.workspace_k8s_name}-home"

  lifecycle {
    ignore_changes = all
  }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name_at_creation"
    value = data.coder_workspace.me.name
  }
}

resource "docker_volume" "dind_certs" {
  count = local.enable_dind ? 1 : 0
  name  = "${local.workspace_k8s_name}-certs"

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

resource "docker_volume" "dind_storage" {
  count = local.enable_dind ? 1 : 0
  name  = "${local.workspace_k8s_name}-dind"

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

resource "docker_network" "workspace" {
  count = local.enable_dind ? 1 : 0
  name  = local.workspace_k8s_name

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
}

resource "docker_container" "dind" {
  count      = local.enable_dind ? data.coder_workspace.me.start_count : 0
  name       = "${local.workspace_k8s_name}-dind"
  image      = "docker:27-dind"
  privileged = true

  # dind puts the container hostname in its server cert SANs; the network alias must match.
  hostname = "docker"

  env = ["DOCKER_TLS_CERTDIR=/certs"]

  networks_advanced {
    name    = docker_network.workspace[0].name
    aliases = ["docker"]
  }

  volumes {
    container_path = "/certs"
    volume_name    = docker_volume.dind_certs[0].name
  }
  volumes {
    container_path = "/var/lib/docker"
    volume_name    = docker_volume.dind_storage[0].name
  }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}

resource "docker_container" "workspace" {
  count    = data.coder_workspace.me.start_count
  name     = local.workspace_k8s_name
  image    = "codercom/enterprise-base:ubuntu"
  hostname = data.coder_workspace.me.name

  entrypoint = ["sh", "-c", local.workspace_entrypoint]

  env = concat(
    ["CODER_AGENT_TOKEN=${coder_agent.main.token}"],
    local.enable_dind ? [
      "DOCKER_HOST=tcp://docker:2376",
      "DOCKER_TLS_VERIFY=1",
      "DOCKER_CERT_PATH=/certs/client",
    ] : [],
  )

  cpus   = data.coder_parameter.cpu.value
  memory = tonumber(data.coder_parameter.memory.value) * 1024

  dynamic "networks_advanced" {
    for_each = local.enable_dind ? [1] : []
    content {
      name = docker_network.workspace[0].name
    }
  }

  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home.name
  }
  volumes {
    container_path = "/etc/ssl/lan/lan-ca.pem"
    host_path      = "/etc/ssl/lan/lan-ca.pem"
    read_only      = true
  }
  volumes {
    container_path = local.workspace_env_file
    host_path      = "/etc/coder-worker/workspace.env"
    read_only      = true
  }
  dynamic "volumes" {
    for_each = local.enable_dind ? [1] : []
    content {
      container_path = "/certs"
      volume_name    = docker_volume.dind_certs[0].name
      read_only      = true
    }
  }

  labels {
    label = "coder.owner"
    value = data.coder_workspace_owner.me.name
  }
  labels {
    label = "coder.owner_id"
    value = data.coder_workspace_owner.me.id
  }
  labels {
    label = "coder.workspace_id"
    value = data.coder_workspace.me.id
  }
  labels {
    label = "coder.workspace_name"
    value = data.coder_workspace.me.name
  }
}
