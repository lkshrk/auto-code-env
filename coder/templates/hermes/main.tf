# Hermes Agent workspace. Project identity lives at the template boundary;
# shared providers, agent, pod, and modules live in common.tf.

data "coder_workspace_preset" "default" {
  name    = "hermes"
  default = true
}

locals {
  stacks            = ["python"]
  enable_dind       = true
  enable_playwright = false
  repos             = ["https://github.com/NousResearch/hermes-agent.git"]
}

resource "coder_script" "start_gateway" {
  agent_id     = coder_agent.main.id
  display_name = "Start Hermes Gateway"
  run_on_start = true

  script = <<-SCRIPT
    set -eu

    hermes="$HOME/.local/bin/hermes"
    if [ ! -x "$hermes" ]; then
      exit 0
    fi

    if "$hermes" gateway status 2>/dev/null | grep -q 'Gateway is running'; then
      exit 0
    fi

    mkdir -p "$HOME/.hermes"
    nohup "$hermes" gateway run >"$HOME/.hermes/gateway.log" 2>&1 &
  SCRIPT
}
