#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$SCRIPT_DIR/../shared/wow-setup.sh"
LUARC="$SCRIPT_DIR/../shared/wow-luarc.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$HOME"

# Stand-ins for the two upstream repositories, with the annotation shapes that matter.
API_SRC="$TEST_ROOT/src/wow-api"
mkdir -p "$API_SRC/Annotations/Core/Lua" "$API_SRC/Annotations/FrameXML"
cat > "$API_SRC/Annotations/Core/Lua/timer.lua" <<'LUA'
---@meta _
C_Timer = {}

---@param seconds number
function C_Timer.After(seconds, callback) end

function GetTime() end
LUA
cat > "$API_SRC/Annotations/FrameXML/fonts.lua" <<'LUA'
GameFontNormal = CreateFont("GameFontNormal")
local hidden = 1
return hidden
LUA
git -C "$API_SRC" init -q -b master && git -C "$API_SRC" add -A && git -C "$API_SRC" commit -q -m one

UI_SRC="$TEST_ROOT/src/wow-ui-source"
mkdir -p "$UI_SRC/Interface/AddOns/Blizzard_UIParent"
printf 'UIParent = CreateFrame("Frame", "UIParent")\n' > "$UI_SRC/Interface/AddOns/Blizzard_UIParent/UIParent.lua"
git -C "$UI_SRC" init -q -b live && git -C "$UI_SRC" add -A && git -C "$UI_SRC" commit -q -m one

export WOW_API_REPO="file://$API_SRC" WOW_UI_SOURCE_REPO="file://$UI_SRC"

bash "$SETUP"

WOW_HOME="$HOME/.local/share/wow"
RC="$XDG_CONFIG_HOME/luacheck/.luacheckrc"
[[ -f "$WOW_HOME/wow-api/Annotations/Core/Lua/timer.lua" ]]
[[ -f "$WOW_HOME/wow-ui-source/Interface/AddOns/Blizzard_UIParent/UIParent.lua" ]]
[[ -f "$RC" ]]
grep -q '^std = "none"$' "$RC"
grep -q '^  "C_Timer",$' "$RC"
grep -q '^  "GetTime",$' "$RC"
grep -q '^  "GameFontNormal",$' "$RC"
# Method definitions, locals and keywords never become globals.
for leaked in After hidden local return; do
  if grep -q "\"$leaked\"" "$RC"; then
    printf 'FAIL: %s leaked into read_globals\n' "$leaked" >&2
    exit 1
  fi
done
# The generated config parses as Lua when luacheck is around.
if command -v luacheck >/dev/null 2>&1; then
  printf 'local x = C_Timer\nGetTime(x, GameFontNormal)\n' > "$TEST_ROOT/ok.lua"
  (cd "$TEST_ROOT" && luacheck --default-config "$RC" ok.lua >/dev/null)
fi

# A second run fast-forwards to new upstream commits.
printf 'function NewThing() end\n' >> "$API_SRC/Annotations/Core/Lua/timer.lua"
git -C "$API_SRC" commit -q -am two
bash "$SETUP"
grep -q '^  "NewThing",$' "$RC"

# wow-luarc writes once, keeps an existing file, and --force overwrites it.
REPO="$HOME/my-addon"
mkdir -p "$REPO"
bash "$LUARC" "$REPO"
[[ -f "$REPO/.luarc.json" ]]
grep -q '"runtime.version": "Lua 5.1"' "$REPO/.luarc.json"
grep -q "\"workspace.library\": \[\"$WOW_HOME/wow-api/Annotations\"\]" "$REPO/.luarc.json"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$REPO/.luarc.json"
printf '{}\n' > "$REPO/.luarc.json"
bash "$LUARC" "$REPO"
[[ "$(<"$REPO/.luarc.json")" == "{}" ]]
bash "$LUARC" --force "$REPO"
grep -q '"runtime.version": "Lua 5.1"' "$REPO/.luarc.json"
(cd "$REPO" && rm .luarc.json && bash "$LUARC" && [[ -f .luarc.json ]])

if WOW_HOME="$TEST_ROOT/nowhere" bash "$LUARC" "$REPO" > /dev/null 2>&1; then
  printf 'FAIL: wow-luarc ran without annotations\n' >&2
  exit 1
fi

printf 'PASS: annotations and FrameXML checked out, luacheck defaults generated, .luarc.json written\n'
