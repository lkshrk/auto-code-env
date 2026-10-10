variable "enabled" {
  type     = bool
  default  = false
  nullable = false
}

variable "opencode_version" {
  type = string
  # renovate: datasource=npm depName=@opencode/cli-linux-x64
  default  = "2.0.26"
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
    deep   = "claude-opus"
  }
  nullable = false

  validation {
    condition     = alltrue([for alias in ["fast", "coding", "deep"] : contains(keys(var.models), alias)])
    error_message = "models must map fast, coding and deep; the shared agents use all three."
  }
}

variable "default_model" {
  type     = string
  default  = "fast"
  nullable = false
}

variable "config_repo" {
  description = "Public git repository whose config_path holds the agent config: AGENTS.md, skills.json, skills/ and opencode/."
  type        = string
  default     = "https://github.com/lkshrk/coding-harness.git"
  nullable    = false
}

variable "config_ref" {
  type     = string
  default  = "main"
  nullable = false
}

variable "config_path" {
  type     = string
  default  = "agent"
  nullable = false
}

variable "rtk_version" {
  type = string
  # renovate: datasource=github-releases depName=rtk-ai/rtk
  default  = "0.50.0"
  nullable = false
}

variable "context_mode_version" {
  type = string
  # renovate: datasource=npm depName=context-mode
  default  = "1.0.169"
  nullable = false
}

variable "context_mode_source" {
  description = "Git repo#commit to build context-mode from instead of the npm release; empty uses context_mode_version from npm. Pinned to the OpenCode v2 port (mksglu/context-mode#1171) until it is released."
  type        = string
  default     = "https://github.com/Scratchydisk/context-mode.git#5bf8ab5e18d83491226b066da8824785de1b9574"
  nullable    = false
}

variable "codegraphcontext_version" {
  type = string
  # renovate: datasource=pypi depName=codegraphcontext
  default  = "0.6.13"
  nullable = false
}
