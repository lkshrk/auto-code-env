variable "enabled" {
  type     = bool
  default  = false
  nullable = false
}

variable "server_version" {
  type     = string
  default  = "1.44.0"
  nullable = false

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.server_version))
    error_message = "server_version must be an exact stable PyPI version."
  }
}

variable "python_version" {
  type     = string
  default  = "3.12"
  nullable = false

  validation {
    condition     = can(regex("^3\\.(1[2-9]|[2-9][0-9])(\\.[0-9]+)?$", var.python_version))
    error_message = "python_version must select Python 3.12 or newer."
  }
}

variable "port" {
  type     = number
  default  = 18001
  nullable = false

  validation {
    condition     = var.port >= 1024 && var.port <= 65535 && floor(var.port) == var.port
    error_message = "port must be an integer between 1024 and 65535."
  }
}

variable "working_directory" {
  type     = string
  default  = ""
  nullable = false

  validation {
    condition     = var.working_directory == "" || startswith(var.working_directory, "/")
    error_message = "working_directory must be absolute, or empty to use $HOME/workspace."
  }
}

variable "environment_names" {
  type     = set(string)
  default  = []
  nullable = false

  validation {
    condition = alltrue([
      for name in var.environment_names :
      can(regex("^[A-Z][A-Z0-9_]*$", name)) &&
      !can(regex("^(OH_|OPENHANDS_|PYTHON|LD_|DYLD_|BASH_FUNC_)", name)) &&
      (!startswith(name, "CODER_") || contains(["CODER_URL", "CODER_ACCESS_URL", "CODER_ENVIRONMENT_MODE", "CODER_OMNI_STACKS"], name)) &&
      !contains(["HOME", "PATH", "SESSION_API_KEY", "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "PROMPT_COMMAND", "CDPATH", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS"], name)
    ])
    error_message = "environment_names must contain uppercase variable names, not reserved runtime, Coder control, or interpreter/shell injection variables."
  }
}
