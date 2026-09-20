#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../shared/claude-lsp.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"
PLUGIN="$HOME/.claude/skills/coder-lsp/.claude-plugin/plugin.json"

# A PATH holding only the servers two stacks would have installed.
BIN="$TEST_ROOT/bin"
mkdir -p "$BIN"
for tool in gopls lua-language-server yaml-language-server terraform-ls; do
  printf '#!/bin/sh\n' > "$BIN/$tool"
  chmod 0755 "$BIN/$tool"
done
ln -s "$(command -v python3)" "$BIN/python3"

PATH="$BIN:/usr/bin:/bin" bash "$SCRIPT"

[[ -f "$PLUGIN" ]]
python3 - "$PLUGIN" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["name"] == "coder-lsp", d
s = d["lspServers"]
assert set(s) == {"gopls", "lua-language-server", "yaml-language-server", "terraform-ls"}, list(s)
assert s["lua-language-server"]["extensionToLanguage"] == {".lua": "lua"}, s["lua-language-server"]
assert s["gopls"]["command"] == "gopls"
assert s["yaml-language-server"]["args"] == ["--stdio"] and s["yaml-language-server"]["extensionToLanguage"][".yml"] == "yaml"
assert s["terraform-ls"]["args"] == ["serve"] and s["terraform-ls"]["extensionToLanguage"][".tfvars"] == "terraform-vars"
for absent in ("pyright", "typescript-language-server", "rust-analyzer", "bash-language-server"):
    assert absent not in s, absent
PY

# Losing a server drops it; losing all of them removes the plugin.
rm "$BIN/gopls" "$BIN/yaml-language-server" "$BIN/terraform-ls"
PATH="$BIN:/usr/bin:/bin" bash "$SCRIPT"
python3 -c 'import json,sys; assert list(json.load(open(sys.argv[1]))["lspServers"]) == ["lua-language-server"]' "$PLUGIN"

rm "$BIN/lua-language-server"
PATH="$BIN:/usr/bin:/bin" bash "$SCRIPT"
[[ ! -e "$HOME/.claude/skills/coder-lsp" ]]

printf 'PASS: Claude Code LSP plugin follows the language servers on PATH\n'
