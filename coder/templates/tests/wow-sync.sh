#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/../shared/wow-sync.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
ADDONS="$TEST_ROOT/wow/_retail_/Interface/AddOns"
mkdir -p "$HOME" "$ADDONS"

# The game side is an rclone remote of type local, configured the same way a
# workspace configures its real remote: through RCLONE_CONFIG_WOW_* only.
export RCLONE_CONFIG_WOW_TYPE=local
export WOW_ADDONS_PATH="$ADDONS"

# A repository whose directory name differs from the addon it ships, with the
# SavedVariables shape a real addon uses.
REPO_A="$HOME/my-addon-repo"
mkdir -p "$REPO_A/.git" "$REPO_A/Modules" "$REPO_A/Libs/LibStub"
cat > "$REPO_A/Alpha.toc" <<'TOC'
## Interface: 110200
## Title: Alpha
## SavedVariables: AlphaDB, AlphaErrors
## SavedVariablesPerCharacter: AlphaCharDB
Modules/init.lua
TOC
printf 'AlphaDB = AlphaDB or {}\nlocal x = AlphaDBExtra\nAlphaCharDB = 1\n' > "$REPO_A/Modules/init.lua"
printf 'LibStub = LibStub or {}\n' > "$REPO_A/Libs/LibStub/LibStub.lua"
printf 'stale\n' > "$REPO_A/drop-me.lua"
printf 'secret\n' > "$REPO_A/.git/config"

# A repository nesting a per-flavour addon one level down.
REPO_B="$HOME/bundle"
mkdir -p "$REPO_B/Beta"
printf '## Title: Beta\n' > "$REPO_B/Beta/Beta_Mainline.toc"

export CODER_REPO_DIRS="my-addon-repo,bundle"

# An unrelated addon already installed must survive every sync, and so must
# the released copy of an addon that is being developed.
mkdir -p "$ADDONS/Bystander" "$ADDONS/Alpha"
printf 'keep\n' > "$ADDONS/Bystander/Bystander.toc"
printf 'release\n' > "$ADDONS/Alpha/Alpha.toc"

bash "$SYNC_SCRIPT"

# Dev variant lands beside the release with renamed .toc and suffixed variables.
[[ -f "$ADDONS/Alpha-Dev/Alpha-Dev.toc" ]]
[[ ! -e "$ADDONS/Alpha-Dev/Alpha.toc" ]]
grep -q '^## Title: Alpha \[DEV\]$' "$ADDONS/Alpha-Dev/Alpha-Dev.toc"
grep -q '^## SavedVariables: AlphaDBDev, AlphaErrorsDev$' "$ADDONS/Alpha-Dev/Alpha-Dev.toc"
grep -q '^## SavedVariablesPerCharacter: AlphaCharDBDev$' "$ADDONS/Alpha-Dev/Alpha-Dev.toc"
grep -q '^AlphaDBDev = AlphaDBDev or {}$' "$ADDONS/Alpha-Dev/Modules/init.lua"
grep -q '^AlphaCharDBDev = 1$' "$ADDONS/Alpha-Dev/Modules/init.lua"
# A longer identifier that merely starts with a variable name is untouched.
grep -q 'AlphaDBExtra$' "$ADDONS/Alpha-Dev/Modules/init.lua"
# Libraries are never rewritten.
grep -q '^LibStub = LibStub or {}$' "$ADDONS/Alpha-Dev/Libs/LibStub/LibStub.lua"
[[ ! -e "$ADDONS/Alpha-Dev/.git" ]]
[[ ! -e "$ADDONS/my-addon-repo" ]]
[[ -f "$ADDONS/Beta-Dev/Beta-Dev_Mainline.toc" ]]
[[ "$(<"$ADDONS/Bystander/Bystander.toc")" == keep ]]
[[ "$(<"$ADDONS/Alpha/Alpha.toc")" == release ]]

# Deletions and edits propagate on the next pass; neighbours still survive.
rm "$REPO_A/drop-me.lua"
printf 'AlphaDB = 2\n' > "$REPO_A/Modules/init.lua"
bash "$SYNC_SCRIPT"

[[ ! -e "$ADDONS/Alpha-Dev/drop-me.lua" ]]
[[ "$(<"$ADDONS/Alpha-Dev/Modules/init.lua")" == "AlphaDBDev = 2" ]]
[[ "$(<"$ADDONS/Bystander/Bystander.toc")" == keep ]]
[[ "$(<"$ADDONS/Alpha/Alpha.toc")" == release ]]

# An empty suffix syncs under the real name and overwrites the release.
WOW_DEV_SUFFIX="" CODER_REPO_DIRS="my-addon-repo" bash "$SYNC_SCRIPT"
[[ -f "$ADDONS/Alpha/Alpha.toc" ]]
grep -q '^## SavedVariables: AlphaDB, AlphaErrors$' "$ADDONS/Alpha/Alpha.toc"
[[ -f "$ADDONS/Alpha-Dev/Alpha-Dev.toc" ]]

# --dry-run writes nothing.
printf 'dry\n' > "$REPO_A/Modules/init.lua"
bash "$SYNC_SCRIPT" --dry-run
[[ "$(<"$ADDONS/Alpha-Dev/Modules/init.lua")" == "AlphaDBDev = 2" ]]

# A failed transfer is reported, not announced as synced, and fails the run.
mkdir -p "$ADDONS/Beta-Dev"
chmod 0555 "$ADDONS/Beta-Dev"
printf 'changed\n' > "$REPO_B/Beta/new.lua"
if CODER_REPO_DIRS="bundle" bash "$SYNC_SCRIPT" > "$TEST_ROOT/fail.log" 2>&1; then
  chmod 0755 "$ADDONS/Beta-Dev"
  printf 'FAIL: sync into a read-only addon directory exited 0\n' >&2
  exit 1
fi
chmod 0755 "$ADDONS/Beta-Dev"
if grep -q 'synced Beta' "$TEST_ROOT/fail.log"; then
  printf 'FAIL: failed sync was reported as synced\n' >&2
  exit 1
fi
grep -q 'sync of Beta .* failed' "$TEST_ROOT/fail.log"
rm "$REPO_B/Beta/new.lua"

# Guard rails.
if CODER_REPO_DIRS="my-addon-repo" WOW_ADDONS_PATH='' bash "$SYNC_SCRIPT" > /dev/null 2>&1; then
  printf 'FAIL: empty WOW_ADDONS_PATH was accepted\n' >&2
  exit 1
fi

if CODER_REPO_DIRS="" bash "$SYNC_SCRIPT" > /dev/null 2>&1; then
  printf 'FAIL: sync without any checkout was accepted\n' >&2
  exit 1
fi

if RCLONE_CONFIG_WOW_TYPE="" bash "$SYNC_SCRIPT" > /dev/null 2>&1; then
  printf 'FAIL: a missing wow: remote was accepted\n' >&2
  exit 1
fi

if WOW_ADDONS_PATH="$TEST_ROOT/no-such-dir/AddOns" bash "$SYNC_SCRIPT" > /dev/null 2>&1; then
  printf 'FAIL: an unreachable AddOns path was accepted\n' >&2
  exit 1
fi

if RCLONE_CONFIG_WOW_KEY_FILE="$TEST_ROOT/no-key" bash "$SYNC_SCRIPT" > /dev/null 2>&1; then
  printf 'FAIL: a missing key file was accepted\n' >&2
  exit 1
fi

printf 'PASS: dev variants staged and pushed over rclone, deletions propagated, release untouched\n'
