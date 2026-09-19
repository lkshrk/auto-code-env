#!/usr/bin/env bash
# Coder-workspace stack/tool installer, owned by auto-code-env: installs
# packages via Omni for the selected CODER_OMNI_STACKS/CODER_AGENT_CLIENTS.
#
# Deliberately does not touch personal dotfile content or client config
# syncing (zsh/nvim/tmux/claude/codex "dots") -- that remains dotfiles'
# job, invoked separately, after this script, against the *same* cloned
# dotfiles checkout this script also reads (for the Omni tool provider
# catalog only: how to install each package, not personal preference).
#
# The $HOME/.local/state/coder-components/links receipt directory name
# is kept as-is (not renamed to match this script) so ownership receipts
# written by the previous dotfiles-owned installer on already-provisioned
# workspaces stay valid across the migration.

set -euo pipefail

SHARED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SHARED_DIR/install-omni.sh"

c_red=$'\033[31m'
c_yel=$'\033[33m'
c_grn=$'\033[32m'
c_dim=$'\033[2m'
c_off=$'\033[0m'

say()  { printf '%b\n' "$*"; }
step() { say "${c_dim}==>${c_off} $*"; }
ok()   { say "${c_grn}OK${c_off} $*"; }
warn() { say "${c_yel}!${c_off} $*"; }
die()  { say "${c_red}x${c_off} $*" >&2; exit 1; }

install_stacks_omni_compatible() {
  local config="$1" binary="${2:-omni}" version
  command -v "$binary" >/dev/null 2>&1 || return 1
  if [[ -n "${OMNI_VERSION:-}" ]]; then
    version="$("$binary" --version)" || return 1
    [[ "$version" =~ ^omni\ version\ v?([0-9]+\.[0-9]+\.[0-9]+)(\ |$) ]] || return 1
    [[ "${BASH_REMATCH[1]}" == "${OMNI_VERSION#v}" ]] || return 1
  fi
  "$binary" --config "$config" settings show --format json >/dev/null 2>&1
}

install_stacks_link_local_bin() {
  local source="$1" target="$HOME/.local/bin/$2" state="$HOME/.local/state/coder-components/links" previous
  [[ "$2" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || die "invalid executable name: $2"
  [[ ! -L "$state" && ! -L "${state%/*}" ]] || die "refusing symlinked link receipt directory: $state"
  mkdir -p "$HOME/.local/bin" "$state"
  [[ ! -L "$state/$2" ]] || die "refusing symlinked link receipt: $state/$2"
  if [[ -L "$target" && "$(readlink "$target")" == "$source" ]]; then
    printf '%s\n' "$source" > "$state/$2"
    return 0
  fi
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -L "$target" && -f "$state/$2" ]] || die "refusing to replace existing executable path: $target (wanted $source)"
    previous="$(cat "$state/$2")"
    [[ "$(readlink "$target")" == "$previous" ]] || die "refusing to replace modified executable path: $target"
    ln -sfnT "$source" "$target"
  else
    ln -sT "$source" "$target"
  fi
  printf '%s\n' "$source" > "$state/$2"
}

install_stacks_link_node_commands() {
  local node_bin="$1" binary
  [[ "$node_bin" == /* && -x "$node_bin/node" ]] || die "required Node executable missing: $node_bin/node"
  for binary in node npm npx corepack; do
    [[ -x "$node_bin/$binary" ]] && install_stacks_link_local_bin "$node_bin/$binary" "$binary"
  done
  return 0
}

# The raw config file this script writes only has group/host *names* --
# the "tools" dict itself is merged in by Omni internally via $include,
# so it isn't visible to plain jq. Active-group membership is, though,
# which is enough to answer "is tool X part of what we're installing".
install_stacks_active_has_tool() {
  jq -e --arg tool "$2" '.hosts["coder-components"] as $active | any(.groups[]; (.name as $n | $active | index($n)) and (.tools // [] | index($tool)))' "$1" >/dev/null
}

install_stacks_path() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if install_stacks_active_has_tool "$1" nvm && [[ -s "$NVM_DIR/nvm.sh" ]]; then
    source "$NVM_DIR/nvm.sh" --no-use
    nvm use --silent default >/dev/null
    install_stacks_link_node_commands "$NVM_BIN"
  fi
  export PATH="${NVM_BIN:+$NVM_BIN:}$HOME/.local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.krew/bin:$HOME/.local/share/pnpm:$HOME/.local/share/pnpm/bin:$PATH"
}

install_stacks_link_npm_commands() {
  local required prefix binary stable_path
  required="$(python3 "$SHARED_DIR/stack-install.py" --dotfiles "$CODER_DOTFILES_SOURCE_DIR" --required-commands --required-provider npm)"
  [[ -n "$required" ]] || return 0
  prefix="$(npm prefix -g)" || die "cannot resolve npm global prefix"
  [[ "$prefix" == /* ]] || die "npm global prefix must be absolute: $prefix"
  stable_path="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.krew/bin:$HOME/.local/share/pnpm:/bin"
  while IFS= read -r binary; do
    [[ -x "$prefix/bin/$binary" ]] || die "required npm executable missing: $prefix/bin/$binary"
    install_stacks_link_local_bin "$prefix/bin/$binary" "$binary"
    env -u NVM_BIN PATH="$stable_path" "$binary" --version >/dev/null || die "required npm executable failed on stable PATH: $binary"
  done <<< "$required"
}

install_stacks_link_lsp_commands() {
  local config="$1" prefix
  if install_stacks_active_has_tool "$config" pyright; then
    prefix="$(npm prefix -g)" || die "cannot resolve Pyright language server prefix"
    [[ "$prefix" == /* && -x "$prefix/bin/pyright-langserver" ]] || die "required Pyright language server missing"
    install_stacks_link_local_bin "$prefix/bin/pyright-langserver" pyright-langserver
    node --check "$prefix/bin/pyright-langserver" || die "invalid Pyright language server entrypoint"
  fi
}

install_stacks_refresh_apt() {
  local required package
  required="$(python3 "$SHARED_DIR/stack-install.py" --dotfiles "$CODER_DOTFILES_SOURCE_DIR" --required-apt-packages)"
  while IFS= read -r package; do
    [[ -n "$package" ]] || continue
    if [[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)" != 'install ok installed' ]]; then
      command -v apt-get >/dev/null || die "required component packages need Debian/Ubuntu apt"
      if [[ "$(id -u)" == 0 ]]; then
        apt-get update -qq
      elif command -v sudo >/dev/null; then
        sudo -n apt-get update -qq
      else
        die "missing required apt packages need root or passwordless sudo"
      fi
      return
    fi
  done <<< "$required"
}

install_stacks_check() {
  local config="$1" binary required tree_sitter_version
  required="$(python3 "$SHARED_DIR/stack-install.py" --dotfiles "$CODER_DOTFILES_SOURCE_DIR" --required-commands)"
  while IFS= read -r binary; do
    command -v "$binary" >/dev/null 2>&1 || die "required component binary missing: $binary"
  done <<< "$required"
  [[ -r "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]] || die "required Oh My Zsh configuration missing"
  tree_sitter_version="$(tree-sitter --version)"
  python3 -c 'import re,sys; match=re.search(r"(\d+)\.(\d+)\.(\d+)",sys.argv[1]); sys.exit(0 if match and tuple(map(int,match.groups())) >= (0,26,1) else 1)' "$tree_sitter_version" || die "tree-sitter >=0.26.1 required"
  nvim --headless -u NONE -i NONE '+lua if vim.fn.filereadable(vim.env.VIMRUNTIME .. "/doc/help.txt") ~= 1 then vim.cmd("cquit") end' +qa || die "required Neovim runtime is incomplete"
  if install_stacks_active_has_tool "$config" "python@3.14"; then
    uv python find 3.14 >/dev/null || die "required managed Python 3.14 missing"
  fi
}

install_stacks_main() (
  : "${CODER_DOTFILES_SOURCE_DIR:?CODER_DOTFILES_SOURCE_DIR is required}"
  local argument="${1:-}" config group binary
  [[ $# -le 1 && ( -z "$argument" || "$argument" == --print-config ) ]] || die "usage: ./install-stacks.sh [--print-config]"
  command -v python3 >/dev/null || die "stack install requires system python3"
  omni_release_base >/dev/null
  if [[ "$argument" == --print-config ]]; then
    python3 "$SHARED_DIR/stack-install.py" --dotfiles "$CODER_DOTFILES_SOURCE_DIR"
    return
  fi
  [[ "$(uname -s)" == Linux ]] || die "stack install is Linux-only"
  for binary in curl tar git jq; do
    command -v "$binary" >/dev/null || die "stack install requires $binary"
  done
  config="$(mktemp)"
  trap 'rm -f "$config"' EXIT
  python3 "$SHARED_DIR/stack-install.py" --dotfiles "$CODER_DOTFILES_SOURCE_DIR" > "$config"
  export PATH="$HOME/.local/bin:$PATH"
  export OMNI_HOSTNAME=coder-components
  export CODER_ENVIRONMENT_MODE=composable
  if [[ -n "${OMNI_OTEL_CA_PATH:-}" && -r "$OMNI_OTEL_CA_PATH" ]]; then
    export NODE_EXTRA_CA_CERTS="${NODE_EXTRA_CA_CERTS:-$OMNI_OTEL_CA_PATH}"
  fi
  if install_stacks_omni_compatible "$config"; then
    ok "reusing compatible $(omni --version)"
  else
    install_omni_release
  fi
  omni --config "$config" settings show --format json >/dev/null
  install_stacks_refresh_apt
  while IFS= read -r group; do
    step "required component tools: $group"
    omni --config "$config" --yes tools sync "$group"
    install_stacks_path "$config"
  done < <(jq -r '.hosts["coder-components"][]' "$config")
  if command -v batcat >/dev/null; then
    install_stacks_link_local_bin "$(command -v batcat)" bat
  fi
  if command -v fdfind >/dev/null; then
    install_stacks_link_local_bin "$(command -v fdfind)" fd
  fi
  install_stacks_link_npm_commands
  install_stacks_link_lsp_commands "$config"
  install_stacks_check "$config"
  ok "required stacks ready; backend=${CODER_BACKEND:-kubernetes}, DinD=${CODER_ENABLE_DIND:-0} (daemon owned by parent)"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  install_stacks_main "$@"
fi
