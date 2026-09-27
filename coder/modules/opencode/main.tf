terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
  }
}

locals {
  startup_script = var.enabled ? templatefile("${path.module}/startup.sh.tftpl", {
    runtime_base64 = base64gzip(file("${path.module}/runtime.py"))
    spawner_base64 = base64gzip(file("${path.module}/spawner.py"))
    config_base64 = base64encode(jsonencode({
      version          = var.opencode_version
      port             = var.port
      spawner_revision = filesha256("${path.module}/spawner.py")
    }))
  }) : ""
}

# Owner-only: the spawner starts processes with caller-supplied provider credentials.
resource "coder_app" "spawner" {
  count        = var.enabled ? 1 : 0
  agent_id     = var.agent_id
  slug         = "opencode"
  display_name = "OpenCode workspaces"
  icon         = "/icon/code.svg"
  url          = "http://127.0.0.1:${var.port}"
  subdomain    = true
  share        = "owner"
  hidden       = true

  healthcheck {
    url       = "http://127.0.0.1:${var.port}/healthz"
    interval  = 10
    threshold = 6
  }
}
