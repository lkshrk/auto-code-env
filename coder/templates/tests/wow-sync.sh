#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/../shared/wow-sync.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
ADDONS="$TEST_ROOT/wow/Interface/AddOns"
mkdir -p "$HOME" "$ADDONS"

# A repository whose directory name differs from the addon it ships.
REPO_A="$HOME/my-addon-repo"
mkdir -p "$REPO_A/.git" "$REPO_A/Modules"
printf 'toc\n' > "$REPO_A/Alpha.toc"
printf 'code\n' > "$REPO_A/Modules/init.lua"
printf 'stale\n' > "$REPO_A/drop-me.lua"
printf 'secret\n' > "$REPO_A/.git/config"

# A repository nesting a per-flavour addon one level down.
REPO_B="$HOME/bundle"
mkdir -p "$REPO_B/Beta"
printf 'toc\n' > "$REPO_B/Beta/Beta_Mainline.toc"

export WOW_ADDONS_DIR="$ADDONS"
export CODER_REPO_DIRS="my-addon-repo,bundle"

# An unrelated addon already installed must survive every sync.
mkdir -p "$ADDONS/Bystander"
printf 'keep\n' > "$ADDONS/Bystander/Bystander.toc"

bash "$SYNC_SCRIPT"

[[ -f "$ADDONS/Alpha/Alpha.toc" ]]
[[ -f "$ADDONS/Alpha/Modules/init.lua" ]]
[[ ! -e "$ADDONS/Alpha/.git" ]]
[[ ! -e "$ADDONS/my-addon-repo" ]]
[[ -f "$ADDONS/Beta/Beta_Mainline.toc" ]]
[[ "$(<"$ADDONS/Bystander/Bystander.toc")" == keep ]]

rm "$REPO_A/drop-me.lua"
printf 'code v2\n' > "$REPO_A/Modules/init.lua"
bash "$SYNC_SCRIPT"

[[ ! -e "$ADDONS/Alpha/drop-me.lua" ]]
[[ "$(<"$ADDONS/Alpha/Modules/init.lua")" == "code v2" ]]
[[ "$(<"$ADDONS/Bystander/Bystander.toc")" == keep ]]

# A destination that resolves outside the AddOns root must be refused, not
# emptied by --delete.
OUTSIDE="$TEST_ROOT/outside"
mkdir -p "$OUTSIDE"
printf 'precious\n' > "$OUTSIDE/keep.txt"
REPO_C="$HOME/escape"
mkdir -p "$REPO_C"
printf 'toc\n' > "$REPO_C/Escaped.toc"
ln -s "$OUTSIDE" "$ADDONS/Escaped"

if CODER_REPO_DIRS="escape" bash "$SYNC_SCRIPT" > /dev/null 2>&1; then
  printf 'FAIL: sync into a target outside the AddOns root was accepted\n' >&2
  exit 1
fi
[[ "$(<"$OUTSIDE/keep.txt")" == precious ]]
[[ ! -e "$OUTSIDE/Escaped.toc" ]]
rm "$ADDONS/Escaped"

if CODER_REPO_DIRS="my-addon-repo" WOW_ADDONS_DIR='' bash "$SYNC_SCRIPT" > /dev/null 2>&1; then
  printf 'FAIL: empty WOW_ADDONS_DIR was accepted\n' >&2
  exit 1
fi

if CODER_REPO_DIRS="" bash "$SYNC_SCRIPT" > /dev/null 2>&1; then
  printf 'FAIL: sync without any checkout was accepted\n' >&2
  exit 1
fi

printf 'PASS: addons resolved from .toc, deletions propagated, escapes refused\n'
