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
printf '## Title: LibStub\nLibStub.lua\n' > "$REPO_A/Libs/LibStub/LibStub.toc"
printf 'stale\n' > "$REPO_A/drop-me.lua"
printf 'secret\n' > "$REPO_A/.git/config"

# A repository nesting a per-flavour addon one level down.
REPO_B="$HOME/bundle"
mkdir -p "$REPO_B/Beta"
printf '## Title: Beta\n## LoadOnDemand: 1\n' > "$REPO_B/Beta/Beta_Mainline.toc"

# A repository checked out with CRLF line endings and a BOM, as Windows editors produce.
REPO_C="$HOME/crlf"
mkdir -p "$REPO_C/Gamma"
printf '\xef\xbb\xbf## Interface: 110200\r\n## Title: Gamma\r\n## SavedVariables: GammaDB\r\nGamma.lua\r\n' > "$REPO_C/Gamma/Gamma.toc"
printf 'GammaDB = GammaDB or {}\r\n' > "$REPO_C/Gamma/Gamma.lua"

# A suite: the repository root is one addon and ships its modules as nested
# addons that depend on it, reference each other by name, and load media
# through Interface\AddOns\<Name> paths.
REPO_D="$HOME/suite"
mkdir -p "$REPO_D/SuiteBags" "$REPO_D/Libs/LibFoo" "$REPO_D/.tools" "$REPO_D/media"
cat > "$REPO_D/Suite.toc" <<'TOC'
## Interface: 110200
## Title: Suite
## IconTexture: Interface\AddOns\Suite\media\logo.tga
## SavedVariables: SuiteDB
Suite.lua
TOC
printf 'SuiteDB = SuiteDB or {}\nlocal colors = { ["Suite"] = 1, ["SuiteBags"] = 2, ["Suiteness"] = 3 }\nlocal font = "Interface\\\\AddOns\\\\Suite\\\\media\\\\f.ttf"\nif C_AddOns.IsAddOnLoaded("SuiteBags") then end\n' > "$REPO_D/Suite.lua"
printf 'local n = "Suite"\n' > "$REPO_D/Libs/LibFoo/LibFoo.lua"
printf 'x\n' > "$REPO_D/.tools/gen.sh"
printf 'x\n' > "$REPO_D/media/logo.tga"
cat > "$REPO_D/SuiteBags/SuiteBags.toc" <<'TOC'
## Interface: 110200
## Title: Suite Bags
## Dependencies: Suite
## OptionalDeps: LibStub, SuiteBags, Other
SuiteBags.lua
TOC
printf 'if folder == "Suite" then end\nlocal t = "Interface/AddOns/suite/media/x.tga"\n' > "$REPO_D/SuiteBags/SuiteBags.lua"

export CODER_REPO_DIRS="my-addon-repo,bundle,crlf,suite"

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
[[ -f "$ADDONS/Alpha-Dev/Libs/LibStub/LibStub.toc" ]]
[[ ! -e "$ADDONS/LibStub-Dev" ]]
[[ ! -e "$ADDONS/Alpha-Dev/.git" ]]
[[ ! -e "$ADDONS/my-addon-repo" ]]
[[ -f "$ADDONS/Beta-Dev/Beta-Dev_Mainline.toc" ]]
# CRLF endings and the BOM survive; the suffix lands before the CR, never after it.
printf '\xef\xbb\xbf## Interface: 110200\r\n## LoadOnDemand: 1\r\n## X-WowSync-Release: Gamma\r\n## X-WowSync-Load: 1\r\n## Title: Gamma [DEV]\r\n## SavedVariables: GammaDBDev\r\nGamma.lua\r\n' | cmp -s - "$ADDONS/Gamma-Dev/Gamma-Dev.toc"
printf 'GammaDBDev = GammaDBDev or {}\r\n' | cmp -s - "$ADDONS/Gamma-Dev/Gamma.lua"
# A suite: nested addons and hidden directories stay out of the parent, and
# every reference between members follows the rename.
[[ ! -e "$ADDONS/Suite-Dev/SuiteBags" ]]
[[ ! -e "$ADDONS/Suite-Dev/.tools" ]]
[[ -f "$ADDONS/Suite-Dev/media/logo.tga" ]]
grep -q '^## IconTexture: Interface\\AddOns\\Suite-Dev\\media\\logo.tga$' "$ADDONS/Suite-Dev/Suite-Dev.toc"
grep -q '^## SavedVariables: SuiteDBDev$' "$ADDONS/Suite-Dev/Suite-Dev.toc"
grep -q '^## Dependencies: Suite-Dev$' "$ADDONS/SuiteBags-Dev/SuiteBags-Dev.toc"
# Dev copies never autoload; the release name stays unsuffixed for WowSync.
grep -q '^## LoadOnDemand: 1$' "$ADDONS/Suite-Dev/Suite-Dev.toc"
grep -q '^## X-WowSync-Release: Suite$' "$ADDONS/Suite-Dev/Suite-Dev.toc"
grep -q '^## X-WowSync-Load: 1$' "$ADDONS/SuiteBags-Dev/SuiteBags-Dev.toc"
grep -q '^## X-WowSync-Release: SuiteBags$' "$ADDONS/SuiteBags-Dev/SuiteBags-Dev.toc"
[ "$(grep -c '^## LoadOnDemand' "$ADDONS/Alpha-Dev/Alpha-Dev.toc")" = 1 ]
# An addon that is load-on-demand upstream stays that way and WowSync leaves loading it to its owner.
[ "$(grep -c '^## LoadOnDemand' "$ADDONS/Beta-Dev/Beta-Dev_Mainline.toc")" = 1 ]
! grep -q '^## X-WowSync-Load' "$ADDONS/Beta-Dev/Beta-Dev_Mainline.toc"
grep -q '^## OptionalDeps: LibStub, SuiteBags-Dev, Other$' "$ADDONS/SuiteBags-Dev/SuiteBags-Dev.toc"
grep -qF '["Suite-Dev"] = 1, ["SuiteBags-Dev"] = 2, ["Suiteness"] = 3' "$ADDONS/Suite-Dev/Suite.lua"
grep -qF 'Interface\\AddOns\\Suite-Dev\\media\\f.ttf' "$ADDONS/Suite-Dev/Suite.lua"
grep -qF 'IsAddOnLoaded("SuiteBags-Dev")' "$ADDONS/Suite-Dev/Suite.lua"
grep -q '^SuiteDBDev = SuiteDBDev or {}$' "$ADDONS/Suite-Dev/Suite.lua"
grep -qxF 'local n = "Suite"' "$ADDONS/Suite-Dev/Libs/LibFoo/LibFoo.lua"
grep -qF 'if folder == "Suite-Dev" then' "$ADDONS/SuiteBags-Dev/SuiteBags.lua"
grep -qF 'Interface/AddOns/Suite-Dev/media/x.tga' "$ADDONS/SuiteBags-Dev/SuiteBags.lua"
# The switch addon is installed in dev mode with the newest Interface of the set.
grep -q '^## Interface: 110200$' "$ADDONS/WowSync/WowSync.toc"
grep -q '^WowSyncMode = "dev"$' "$ADDONS/WowSync/Mode.lua"
grep -q '^local SUFFIX = "-Dev"$' "$ADDONS/WowSync/WowSync.lua"
lua=$(command -v lua5.1 || command -v lua || true)
[ -n "$lua" ] || { printf 'FAIL: lua5.1 is needed for the WowSync helper test\n' >&2; exit 1; }
"$lua" "$(dirname "${BASH_SOURCE[0]}")/wow-sync-helper.lua" "$ADDONS/WowSync/WowSync.lua" "$ADDONS/WowSync/Mode.lua"
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

# --addon narrows the run; the suite core alone warns about its released modules.
rm -rf "$ADDONS/Suite-Dev" "$ADDONS/SuiteBags-Dev"
printf 'if folder == "Suite" then end\n' > "$REPO_D/SuiteBags/SuiteBags.lua"
bash "$SYNC_SCRIPT" --addon Suite "$REPO_D" > "$TEST_ROOT/only.log" 2>&1
[[ -f "$ADDONS/Suite-Dev/Suite-Dev.toc" ]]
[[ ! -e "$ADDONS/SuiteBags-Dev" ]]
[[ ! -e "$ADDONS/Suite-Dev/SuiteBags" ]]
grep -q 'warning: Suite goes out as Suite-Dev while 1 nested addon' "$TEST_ROOT/only.log"
# A module synced on its own keeps pointing at the released core.
bash "$SYNC_SCRIPT" "$REPO_D/SuiteBags"
grep -q '^## Dependencies: Suite$' "$ADDONS/SuiteBags-Dev/SuiteBags-Dev.toc"
grep -qF 'if folder == "SuiteBags-Dev"' "$ADDONS/SuiteBags-Dev/SuiteBags.lua" || true
grep -qF 'if folder == "Suite" then' "$ADDONS/SuiteBags-Dev/SuiteBags.lua"

# --changed picks the addons whose files differ in git; a change inside a
# nested addon belongs to the nested addon, not to the core.
git -C "$REPO_D" init -q
git -C "$REPO_D" -c user.name=t -c user.email=t@t add -A
git -C "$REPO_D" -c user.name=t -c user.email=t@t commit -q -m base
rm -rf "$ADDONS/Suite-Dev" "$ADDONS/SuiteBags-Dev"
bash "$SYNC_SCRIPT" --changed "$REPO_D" > "$TEST_ROOT/changed.log" 2>&1
grep -q 'nothing selected to sync' "$TEST_ROOT/changed.log"
[[ ! -e "$ADDONS/Suite-Dev" ]]
printf 'edit\n' >> "$REPO_D/SuiteBags/SuiteBags.lua"
bash "$SYNC_SCRIPT" --changed "$REPO_D"
[[ -f "$ADDONS/SuiteBags-Dev/SuiteBags-Dev.toc" ]]
[[ ! -e "$ADDONS/Suite-Dev" ]]
printf 'edit\n' >> "$REPO_D/Suite.lua"
bash "$SYNC_SCRIPT" --changed "$REPO_D"
[[ -f "$ADDONS/Suite-Dev/Suite-Dev.toc" ]]

# --off flips the switch addon to release mode and syncs nothing else.
rm -rf "$ADDONS/Suite-Dev"
bash "$SYNC_SCRIPT" --off
grep -q '^WowSyncMode = "release"$' "$ADDONS/WowSync/Mode.lua"
grep -q '^## Interface: 110200$' "$ADDONS/WowSync/WowSync.toc"
[[ ! -e "$ADDONS/Suite-Dev" ]]

# --dry-run writes nothing.
printf 'dry\n' > "$REPO_A/Modules/init.lua"
bash "$SYNC_SCRIPT" --dry-run
[[ "$(<"$ADDONS/Alpha-Dev/Modules/init.lua")" == "AlphaDBDev = 2" ]]

# A destination that is not this addon is never emptied, even under the dev name.
rm -rf "$ADDONS/Beta-Dev"
mkdir -p "$ADDONS/Beta-Dev"
printf 'mine\n' > "$ADDONS/Beta-Dev/precious.txt"
if CODER_REPO_DIRS="bundle" bash "$SYNC_SCRIPT" > "$TEST_ROOT/foreign.log" 2>&1; then
  printf 'FAIL: sync into a foreign directory exited 0\n' >&2
  exit 1
fi
grep -q 'refusing to sync Beta' "$TEST_ROOT/foreign.log"
[[ "$(<"$ADDONS/Beta-Dev/precious.txt")" == mine ]]
[[ ! -e "$ADDONS/Beta-Dev/Beta-Dev_Mainline.toc" ]]
rm -rf "$ADDONS/Beta-Dev"

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

if WOW_DEV_SUFFIX_CONFIGURED=Dev WOW_DEV_SUFFIX=2154 bash "$SYNC_SCRIPT" > "$TEST_ROOT/suffix.log" 2>&1; then
  printf 'FAIL: a suffix other than the configured one was accepted\n' >&2
  exit 1
fi
grep -q "refusing suffix '2154'" "$TEST_ROOT/suffix.log"
[[ ! -e "$ADDONS/Alpha-2154" ]]

if RCLONE_CONFIG_WOW_KEY_FILE="$TEST_ROOT/no-key" bash "$SYNC_SCRIPT" > /dev/null 2>&1; then
  printf 'FAIL: a missing key file was accepted\n' >&2
  exit 1
fi

printf 'PASS: dev variants staged and pushed over rclone, deletions propagated, release untouched\n'
