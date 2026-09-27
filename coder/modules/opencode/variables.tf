variable "enabled" {
  type     = bool
  default  = false
  nullable = false
}

variable "opencode_version" {
  type = string
  # renovate: datasource=npm depName=@opencode/cli-linux-x64
  default  = "2.0.18"
  nullable = false

  validation {
    condition     = can(regex("^2\\.[0-9]+\\.[0-9]+$", var.opencode_version))
    error_message = "opencode_version must be an exact OpenCode v2 release."
  }
}

variable "gateway_url" {
  type     = string
  default  = "http://litellm-proxy.ai.svc.cluster.local:4000/v1"
  nullable = false
}

variable "mcp_url" {
  description = "LiteLLM MCP gateway; tools per key are set in LiteLLM."
  type        = string
  default     = "http://litellm-proxy.ai.svc.cluster.local:4000/mcp/"
  nullable    = false
}

variable "models" {
  description = "Worker model aliases (gw/<alias>) mapped to LiteLLM model names."
  type        = map(string)
  default = {
    fast   = "basic/glm-5.3-flash"
    coding = "claude-sonnet"
  }
  nullable = false
}

variable "default_model" {
  type     = string
  default  = "fast"
  nullable = false
}

variable "config_repo" {
  description = "Public git repository whose config_path holds shared agents, commands, skills and AGENTS.md."
  type        = string
  default     = "https://github.com/lkshrk/auto-code-env.git"
  nullable    = false
}

variable "config_ref" {
  type     = string
  default  = "main"
  nullable = false
}

variable "config_path" {
  type     = string
  default  = "opencode/config"
  nullable = false
}
