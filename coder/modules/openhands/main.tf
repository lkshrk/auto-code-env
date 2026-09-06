locals {
  default_environment_names = [
    "GIT_SSH_COMMAND", "SSH_AUTH_SOCK", "SSH_AGENT_PID",
    "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_AUTHOR_DATE",
    "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "GIT_COMMITTER_DATE",
    "DOCKER_HOST", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "KUBECONFIG",
    "XDG_CACHE_HOME", "TMPDIR", "TMP", "TEMP",
    "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "SSL_CERT_DIR",
    "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO",
    "CODER_URL", "CODER_ACCESS_URL", "CODER_ENVIRONMENT_MODE", "CODER_OMNI_STACKS",
    "EDITOR", "VISUAL", "SHELL", "GITHUB_SERVER_URL", "CI_SERVER_URL",
    "NVM_DIR", "PNPM_HOME", "BUN_INSTALL", "CARGO_HOME", "RUSTUP_HOME",
    "GOPATH", "GOBIN", "GOMODCACHE", "GOCACHE", "PYENV_ROOT",
    "UV_CACHE_DIR", "PIP_CACHE_DIR", "NPM_CONFIG_CACHE",
  ]

  startup_script = var.enabled ? templatefile("${path.module}/startup.sh.tftpl", {
    runtime_base64 = base64encode(file("${path.module}/runtime.py"))
    config_base64 = base64encode(jsonencode({
      version           = var.server_version
      python_version    = var.python_version
      port              = var.port
      working_directory = var.working_directory
      runtime_revision  = filesha256("${path.module}/runtime.py")
      environment_names = sort(distinct(concat(local.default_environment_names, tolist(var.environment_names))))
    }))
  }) : ""
}
