locals {
  config = {
    "$schema" = "https://opencode.ai/config.json"
    update    = "disable"
    model     = "gw/${var.default_model}"
    providers = {
      gw = {
        package  = "@opencode/ai/providers/openai-compatible"
        settings = { baseURL = var.gateway_url, apiKey = "{env:LITELLM_API}" }
        models   = { for alias, id in var.models : alias => { modelID = id } }
      }
    }
    mcp = {
      servers = {
        gateway = {
          type    = "remote"
          url     = var.mcp_url
          headers = { "x-litellm-api-key" = "{env:LITELLM_API}" }
        }
        context-mode = {
          type    = "local"
          command = ["sh", "-c", "exec \"$HOME/.opencode-v2/tools/bin/context-mode\""]
        }
        codegraph = {
          type    = "local"
          command = ["sh", "-c", "exec \"$HOME/.opencode-v2/tools/bin/cgc\" mcp start"]
        }
      }
    }
    permissions = concat([
      { action = "*", resource = "*", effect = "allow" },
      { action = "external_directory", resource = "*", effect = "allow" },
      ], [
      # Ticket and project changes stay human-only; the oc-workers key blocks these server-side too.
      for verb in ["save", "delete", "create", "share", "unshare", "mark", "restore", "retire", "prepare"] :
      { action = "gateway_linear-${verb}_*", resource = "*", effect = "deny" }
    ])
    experimental = {
      policies = [
        { action = "provider.use", resource = "*", effect = "deny" },
        { action = "provider.use", resource = "gw", effect = "allow" },
      ]
    }
  }

  startup_script = var.enabled ? templatefile("${path.module}/startup.sh.tftpl", {
    version     = var.opencode_version
    config_json = base64encode(jsonencode(local.config))
    install_py  = base64gzip(file("${path.module}/install.py"))
    tools = base64encode(jsonencode({
      rtk              = var.rtk_version
      context_mode     = var.context_mode_version
      codegraphcontext = var.codegraphcontext_version
    }))
    shared = base64encode(jsonencode({
      repo = var.config_repo
      ref  = var.config_ref
      path = var.config_path
    }))
  }) : ""
}
