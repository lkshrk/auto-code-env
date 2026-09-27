variable "enabled" {
  type     = bool
  default  = false
  nullable = false
}

variable "agent_id" {
  type     = string
  nullable = false
}

variable "opencode_version" {
  type = string
  # renovate: datasource=npm depName=opencode-ai
  default  = "1.18.32"
  nullable = false

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.opencode_version))
    error_message = "opencode_version must be an exact stable release."
  }
}

variable "port" {
  type     = number
  default  = 18002
  nullable = false

  validation {
    condition     = var.port >= 1024 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be an integer between 1024 and 65535."
  }
}
