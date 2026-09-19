#!/usr/bin/env bash

set -euo pipefail

: "${WOW_HOME:=$HOME/.local/share/wow}"

usage() {
  cat <<'USAGE'
Usage: wow-luarc [--force] [dir]

Writes a .luarc.json into an addon checkout (default: the current directory)
that points lua-language-server at the WoW API annotations: Lua 5.1, the
standard Lua libraries disabled in favour of the game's own, the annotations
as workspace library. An existing file is kept unless --force is given.
USAGE
}

main() {
  local force=0 dir=.
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      -h | --help) usage; return 0 ;;
      -*) usage >&2; return 2 ;;
      *) dir=$1 ;;
    esac
    shift
  done

  local annotations="$WOW_HOME/wow-api/Annotations" out="$dir/.luarc.json"
  [ -d "$annotations" ] || { printf 'wow-luarc: %s missing; run wow-setup first\n' "$annotations" >&2; return 1; }
  [ -d "$dir" ] || { printf 'wow-luarc: no such directory: %s\n' "$dir" >&2; return 1; }
  if [ -e "$out" ] && [ "$force" -eq 0 ]; then
    printf 'wow-luarc: %s exists, keeping it (--force overwrites)\n' "$out" >&2
    return 0
  fi

  cat > "$out" <<JSON
{
  "\$schema": "https://raw.githubusercontent.com/LuaLS/vscode-lua/master/setting/schema.json",
  "runtime.version": "Lua 5.1",
  "runtime.builtin": {
    "basic": "disable",
    "debug": "disable",
    "io": "disable",
    "math": "disable",
    "os": "disable",
    "package": "disable",
    "string": "disable",
    "table": "disable",
    "utf8": "disable"
  },
  "workspace.library": ["$annotations"],
  "workspace.checkThirdParty": false
}
JSON
  printf 'wow-luarc: wrote %s\n' "$out" >&2
}

main "$@"
