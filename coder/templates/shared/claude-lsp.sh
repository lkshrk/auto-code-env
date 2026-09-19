#!/usr/bin/env bash

set -euo pipefail

: "${CLAUDE_LSP_PLUGIN_DIR:=$HOME/.claude/skills/coder-lsp}"

# Claude Code loads ~/.claude/skills/*/.claude-plugin/plugin.json as user-scope
# plugins; lspServers there give it diagnostics and navigation for the stacks
# this workspace installed. Only servers present on PATH are written.
main() {
  local out="$CLAUDE_LSP_PLUGIN_DIR/.claude-plugin/plugin.json"
  local json
  json=$(python3 - "$@" <<'PY'
import json, shutil, sys
servers = {
    "gopls": {"command": "gopls", "extensionToLanguage": {".go": "go"}},
    "pyright": {"command": "pyright-langserver", "args": ["--stdio"],
                "extensionToLanguage": {".py": "python", ".pyi": "python"}},
    "typescript-language-server": {"command": "typescript-language-server", "args": ["--stdio"],
                                   "extensionToLanguage": {".ts": "typescript", ".tsx": "typescriptreact",
                                                           ".mts": "typescript", ".cts": "typescript",
                                                           ".js": "javascript", ".jsx": "javascriptreact",
                                                           ".mjs": "javascript", ".cjs": "javascript"}},
    "lua-language-server": {"command": "lua-language-server", "extensionToLanguage": {".lua": "lua"}},
}
found = {name: spec for name, spec in servers.items() if shutil.which(spec["command"])}
if found:
    print(json.dumps({"name": "coder-lsp", "description": "Language servers installed by the workspace stacks",
                      "lspServers": found}, indent=2))
PY
  )
  if [ -z "$json" ]; then
    rm -rf "$CLAUDE_LSP_PLUGIN_DIR"
    printf 'claude-lsp: no language server on PATH, plugin removed\n' >&2
    return 0
  fi
  mkdir -p "${out%/*}"
  printf '%s\n' "$json" > "$out.tmp"
  mv "$out.tmp" "$out"
  printf 'claude-lsp: %s -> %s\n' "$(python3 -c 'import json,sys; print(", ".join(json.load(open(sys.argv[1]))["lspServers"]))' "$out")" "$out" >&2
}

main "$@"
