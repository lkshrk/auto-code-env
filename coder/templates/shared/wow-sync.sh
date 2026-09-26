#!/usr/bin/env bash

set -euo pipefail

: "${WOW_ADDONS_PATH:?WOW_ADDONS_PATH is required}"
: "${WOW_DEV_SUFFIX=Dev}"
: "${WOW_REMOTE:=wow}"
: "${WOW_SWITCH_ADDON:=WowSync}"
export RCLONE_CONFIG=/dev/null

readonly STAGE_EXCLUDES=(
  --exclude '.*/**'
  --exclude '.*'
  --exclude 'node_modules/**'
)

readonly SYNC_FLAGS=(
  --create-empty-src-dirs
  --modify-window 2s
  --max-delete 200
  --transfers 4
  --checkers 8
  --retries 3
  --low-level-retries 10
  --contimeout 15s
  --timeout 60s
)

usage() {
  cat <<'USAGE'
Usage: wow-sync [--watch] [--dry-run] [--addon NAME]... [--changed] [path...]
       wow-sync --off

Pushes addons found under the given paths (repositories or single addon
directories) to the game's AddOns directory on the rclone remote `wow:`, at
WOW_ADDONS_PATH. With no path arguments, uses CODER_REPO_DIRS.

An addon is any directory holding a .toc file, except embedded libraries under
Libs/; the addon name comes from the .toc, not from the directory, so a
repository may be named anything.

With WOW_DEV_SUFFIX set (default "Dev"), each addon is installed as
<Name>-<suffix>: the .toc is renamed, its Title is marked, and every
SavedVariables name gains the suffix in the .toc and in the Lua sources. The
dev copy then runs beside the released addon and cannot touch its settings.
Addons synced together form a set: dependency lines, Interface\AddOns\<Name>
paths and Lua string literals naming another member are pointed at its dev
copy, so a suite keeps working as a whole. Sync a single module directory and
its references keep pointing at the released rest of the suite. Nested addon
directories and hidden files are never copied into a parent addon.

Dev copies are marked LoadOnDemand, so the game never starts one beside its
released addon. Every dev sync also installs the helper addon WowSync: it
disables each released addon that has a dev copy (for all characters), reloads
once if the release was active, and then loads the dev copies itself. In game,
/wowsync release|dev|status flips between the two; the last result is in the
WowSyncDB SavedVariable. A suffix other than WOW_DEV_SUFFIX_CONFIGURED is
refused unless --any-suffix is given.

The remote is configured entirely through RCLONE_CONFIG_WOW_* environment
variables, which Coder user secrets provide; wow-sync never reads a config file.

  --addon NAME  sync only this addon of those found (repeatable)
  --changed     sync only addons with uncommitted changes or commits ahead of
                their git upstream
  --watch       resync on every change instead of exiting after one pass
  --dry-run     show what rclone would change without writing to the game
  --off         switch the game back to the released addons at next login
  --any-suffix  allow a WOW_DEV_SUFFIX that differs from the workspace setting
USAGE
}

log() { printf 'wow-sync: %s\n' "$1" >&2; }

# Trailing flavour suffixes Blizzard appends to per-flavour .toc files.
addon_name_from_toc() {
  local base=${1##*/}
  base=${base%.toc}
  shopt -s nocasematch
  if [[ $base =~ ^(.+)[_-](mainline|standard|vanilla|classic|tbc|wrath|cata|mists|legion|bcc)$ ]]; then
    base=${BASH_REMATCH[1]}
  fi
  shopt -u nocasematch
  printf '%s\n' "$base"
}

# Emits "<name>\t<directory>" for every addon directory under the given paths.
discover_addons() {
  local path toc dir name
  for path in "$@"; do
    [ -d "$path" ] || continue
    while IFS= read -r toc; do
      dir=${toc%/*}
      name=$(addon_name_from_toc "$toc")
      [ -n "$name" ] || continue
      printf '%s\t%s\n' "$name" "$dir"
    done < <(find "$path" -maxdepth 3 -type f -name '*.toc' -not -path '*/.*/*' -not -ipath '*/libs/*' 2>/dev/null)
  done | sort -u
}

# Emits absolute paths of files changed in the checkout holding $1: the working
# tree against HEAD, plus commits ahead of the upstream branch when one is set.
changed_files() {
  local root
  root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
  {
    git -C "$root" status --porcelain --untracked-files=all | cut -c4- | sed -E 's/^.* -> //'
    git -C "$root" diff --name-only '@{upstream}...HEAD' 2>/dev/null || true
  } | sed "s|^|$root/|" | sort -u
}

# Highest ## Interface number declared by the given .toc files.
max_interface() {
  cat "$@" 2>/dev/null | sed -n -E 's/^## Interface:[[:space:]]*//p' | tr -d ' \t\r' | tr ',' '\n' | grep -E '^[0-9]+$' | sort -n | tail -1
}

# Rewrites the staged copy into the dev variant: renamed .toc files, a marked
# Title, suffixed SavedVariables names, and every reference to an addon of the
# synced set (dependency lines, AddOns\<Name> paths, whole Lua string literals)
# pointed at that addon's dev copy.
apply_dev_suffix() {
  local stage=$1 name=$2 suffix=$3
  shift 3
  local toc vars=() var expr="" dep_expr="" ref_expr="" member

  while IFS= read -r toc; do
    while IFS= read -r var; do
      [ -n "$var" ] && vars+=("$var")
    done < <(sed -n -E 's/^## SavedVariables(PerCharacter)?:[[:space:]]*//p' "$toc" | tr -d ' \t\r' | tr ',' '\n')
  done < <(find "$stage" -maxdepth 1 -type f -name '*.toc')

  for var in "${vars[@]+"${vars[@]}"}"; do
    expr+="s/\\b\Q${var}\E\\b/${var}${suffix}/g;"
  done
  for member in "$@"; do
    dep_expr+="s/(?<![\\w-])\Q${member}\E(?![\\w-])/${member}-${suffix}/g;"
    ref_expr+="s/(AddOns[\\\\\\/]+)\Q${member}\E(?=[\\\\\\/])/\$1${member}-${suffix}/gi;"
    ref_expr+="s/([\"'])\Q${member}\E\\1/\$1${member}-${suffix}\$1/g;"
  done

  while IFS= read -r toc; do
    tag_dev_toc "$toc" "$name"
    perl -pi -e "s/^(## Title:[^\\r\\n]*)/\$1 [${suffix^^}]/" "$toc"
    [ -n "$expr" ] && perl -pi -e "if (/^## SavedVariables(PerCharacter)?:/) { $expr }" "$toc"
    [ -n "$dep_expr" ] && perl -pi -e "if (/^## (Dependencies|RequiredDeps|OptionalDeps|LoadWith|LoadManagers|Dep\\d*):/i) { $dep_expr }" "$toc"
    [ -n "$ref_expr" ] && perl -pi -e "$ref_expr" "$toc"
    mv -- "$toc" "$stage/$name-$suffix${toc#"$stage/$name"}"
  done < <(find "$stage" -maxdepth 1 -type f -name "$name*.toc")

  [ -n "$expr" ] && find "$stage" -type f -name '*.lua' -not -path '*/Libs/*' -exec perl -pi -e "$expr" {} +
  [ -n "$ref_expr" ] && find "$stage" -type f \( -name '*.lua' -o -name '*.xml' \) -not -path '*/Libs/*' -exec perl -pi -e "$ref_expr" {} +
  return 0
}

# Dev copies are load-on-demand so the game never starts them beside the
# released addon; WowSync loads them once the release is disabled.
tag_dev_toc() {
  local toc=$1 name=$2 autoload=1
  grep -qiE '^## LoadOnDemand:[[:space:]]*1' "$toc" && autoload=0
  WS_NAME=$name WS_AUTO=$autoload perl -pi -e '
    if (/^## (LoadOnDemand|X-WowSync-[A-Za-z]+):/i) { $_ = ""; next }
    if (!$done && /^(\xef\xbb\xbf)?## /) {
      my ($eol) = /(\r?\n)\z/; $eol //= "\n";
      $_ .= "$eol" unless /\n\z/;
      $_ .= "## LoadOnDemand: 1$eol## X-WowSync-Release: $ENV{WS_NAME}$eol";
      $_ .= "## X-WowSync-Load: 1$eol" if $ENV{WS_AUTO};
      $done = 1;
    }' "$toc"
}

# A destination that exists but holds no <target>*.toc belongs to something
# else; sync would delete its contents, so refuse instead of guessing.
check_dest() {
  local name=$1 target=$2 dest=$3 existing
  if existing=$(rclone lsf "$dest" --max-depth 1 2>/dev/null) && [ -n "$existing" ] \
    && ! printf '%s\n' "$existing" | grep -qi "^${target}.*\.toc$"; then
    log "refusing to sync $name: $dest exists and is not a $target addon (no $target*.toc)"
    return 1
  fi
}

# sync_addon <name> <src> <dry> <member>... ; SET_DIRS lists every addon
# directory of the run so nested addons are left out of their parent's copy.
sync_addon() {
  local name=$1 src=$2 dry=$3 stage target dest
  shift 3

  case "$name" in
    '' | . | .. | */* | *\\*)
      log "refusing to sync addon with unusable name: $name"
      return 1
      ;;
  esac

  target=$name
  [ -n "$WOW_DEV_SUFFIX" ] && target="$name-$WOW_DEV_SUFFIX"
  dest="$WOW_REMOTE:${WOW_ADDONS_PATH%/}/$target"
  check_dest "$name" "$target" "$dest" || return 1

  stage=$(mktemp -d -t wow-sync.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -rf '$stage'" RETURN

  local nested=() other
  for other in "${SET_DIRS[@]+"${SET_DIRS[@]}"}"; do
    case "$other" in
      "$src"/*) nested+=(--exclude "${other#"$src"/}/**") ;;
    esac
  done

  rclone copy "$src" "$stage" "${STAGE_EXCLUDES[@]}" "${nested[@]+"${nested[@]}"}" || { log "staging $name failed"; return 1; }
  if [ -n "$WOW_DEV_SUFFIX" ]; then
    apply_dev_suffix "$stage" "$name" "$WOW_DEV_SUFFIX" "$@" || { log "dev rewrite of $name failed"; return 1; }
  fi

  # rclone sync only ever deletes inside $dest, which is one addon directory,
  # and it verifies size and modtime of everything it writes.
  # shellcheck disable=SC2086
  rclone sync "$stage" "$dest" "${SYNC_FLAGS[@]}" $dry || { log "sync of $name -> $dest failed"; return 1; }
  log "synced $name -> $dest"
}

# Installs the in-game switch addon. Its Interface version follows the synced
# addons, else the copy already on the remote, so the game never hides it.
install_switch_addon() {
  local mode=$1 interface=$2 dry=$3 dest stage
  dest="$WOW_REMOTE:${WOW_ADDONS_PATH%/}/$WOW_SWITCH_ADDON"
  [ -n "$dry" ] && return 0
  check_dest "$WOW_SWITCH_ADDON" "$WOW_SWITCH_ADDON" "$dest" || return 1

  if [ -z "$interface" ]; then
    interface=$(rclone cat "$dest/$WOW_SWITCH_ADDON.toc" 2>/dev/null | sed -n -E 's/^## Interface:[[:space:]]*//p' | tr -d ' \r')
  fi
  if [ -z "$interface" ]; then
    log "no ## Interface found to give $WOW_SWITCH_ADDON; set WOW_INTERFACE or sync an addon first"
    return 1
  fi

  stage=$(mktemp -d -t wow-sync.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -rf '$stage'" RETURN

  cat > "$stage/$WOW_SWITCH_ADDON.toc" <<TOC
## Interface: $interface
## Title: $WOW_SWITCH_ADDON
## Notes: Switches between released addons and the -$WOW_DEV_SUFFIX copies pushed by wow-sync.
## SavedVariables: WowSyncDB
Mode.lua
$WOW_SWITCH_ADDON.lua
TOC
  printf 'WowSyncMode = "%s"\nWowSyncStamp = "%s"\n' "$mode" "$(date +%s)" > "$stage/Mode.lua"
  cat > "$stage/$WOW_SWITCH_ADDON.lua" <<'LUA'
local ADDON = ...
local SUFFIX = "-@SUFFIX@"
local RELOAD_GUARD = 60
local reloadPending = false

local function meta(name, key)
  local v = C_AddOns.GetAddOnMetadata(name, key)
  if v and v ~= "" then return v end
end

-- Copies from older syncs carry no X-WowSync-Release and are found by suffix.
local function devCopies()
  local list, seen = {}, {}
  for i = 1, C_AddOns.GetNumAddOns() do
    local name = C_AddOns.GetAddOnInfo(i)
    local rel = meta(name, "X-WowSync-Release")
    local legacy = not rel and name:sub(-#SUFFIX) == SUFFIX
    if rel or legacy then
      rel = rel or name:sub(1, -#SUFFIX - 1)
      list[#list + 1] = { dev = name, rel = rel, autoload = meta(name, "X-WowSync-Load") == "1", legacy = legacy, duplicate = seen[rel] or false }
      seen[rel] = true
    end
  end
  return list
end

local function relActive(rel)
  if not C_AddOns.DoesAddOnExist(rel) then return false end
  if C_AddOns.IsAddOnLoaded(rel) then return true end
  return C_AddOns.GetAddOnEnableState(rel, UnitName("player")) ~= Enum.AddOnEnableState.None
end

-- Never loads a dev copy while its release is loaded or enabled; that session reloads first.
local function apply(mode)
  local report = { mode = mode, time = time(), loaded = {}, waiting = {}, failed = {} }
  local reload, toLoad = false, {}
  for _, c in ipairs(devCopies()) do
    local hasRel = C_AddOns.DoesAddOnExist(c.rel)
    if mode == "dev" and not c.duplicate then
      local active = relActive(c.rel)
      if hasRel then C_AddOns.DisableAddOn(c.rel) end
      C_AddOns.EnableAddOn(c.dev)
      if active then
        reload = true
        report.waiting[#report.waiting + 1] = c.dev
      elseif c.autoload and not C_AddOns.IsAddOnLoaded(c.dev) then
        toLoad[#toLoad + 1] = c.dev
      end
    else
      if c.duplicate then report.failed[c.dev] = "second dev copy of " .. c.rel .. ", disabled" end
      if C_AddOns.IsAddOnLoaded(c.dev) then reload = true end
      C_AddOns.DisableAddOn(c.dev)
      if mode ~= "dev" and hasRel and not relActive(c.rel) then
        C_AddOns.EnableAddOn(c.rel)
        reload = true
      end
    end
  end
  -- Repeated passes let suite members load after the dev copies they depend on.
  while #toLoad > 0 do
    local retry = {}
    for _, dev in ipairs(toLoad) do
      local ok, reason = C_AddOns.LoadAddOn(dev)
      if ok then
        report.loaded[#report.loaded + 1] = dev
        report.failed[dev] = nil
      else
        report.failed[dev] = tostring(reason)
        retry[#retry + 1] = dev
      end
    end
    if #retry == #toLoad then break end
    toLoad = retry
  end
  WowSyncDB.last = report
  return reload, report
end

local function say(fmt, ...)
  print("|cff33ff99WowSync|r: " .. fmt:format(...))
end

local function status()
  local names = {}
  for _, c in ipairs(devCopies()) do
    names[#names + 1] = c.dev .. (C_AddOns.IsAddOnLoaded(c.dev) and " (loaded)" or "")
  end
  say("mode %s, %d dev copies: %s", WowSyncDB.mode, #names, table.concat(names, ", "))
  local last = WowSyncDB.last
  if last then
    for dev, reason in pairs(last.failed) do say("%s not loaded: %s", dev, reason) end
  end
end

local function reloadNow(reason)
  if WowSyncDB.lastReload and time() - WowSyncDB.lastReload < RELOAD_GUARD then
    say("%s needs a reload but one just happened; /reload by hand", reason)
    return
  end
  WowSyncDB.lastReload = time()
  say("%s, reloading", reason)
  C_Timer.After(1, ReloadUI)
end

SLASH_WOWSYNC1 = "/wowsync"
SlashCmdList.WOWSYNC = function(msg)
  msg = (msg or ""):lower():match("^%s*(%S*)")
  if msg == "dev" or msg == "release" then
    WowSyncDB.mode = msg
    if apply(msg) then reloadNow("switched to " .. msg) else status() end
  else
    status()
  end
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event, name)
  if event == "ADDON_LOADED" then
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    WowSyncDB = WowSyncDB or {}
    if WowSyncDB.stamp ~= WowSyncStamp then
      WowSyncDB.stamp = WowSyncStamp
      WowSyncDB.mode = WowSyncMode
    end
    reloadPending = apply(WowSyncDB.mode or WowSyncMode)
  else
    status()
    if reloadPending then reloadNow("released copies disabled for " .. WowSyncDB.mode .. " mode") end
  end
end)
LUA
  perl -pi -e "s/\@SUFFIX\@/${WOW_DEV_SUFFIX}/" "$stage/$WOW_SWITCH_ADDON.lua"

  rclone sync "$stage" "$dest" "${SYNC_FLAGS[@]}" || { log "install of $WOW_SWITCH_ADDON failed"; return 1; }
  log "installed $WOW_SWITCH_ADDON (mode $mode, Interface $interface)"
}

sync_all() {
  local dry=$1
  shift
  local name src status=0 i j seen="" changed=() f best
  local names=() srcs=() pick=()
  SET_DIRS=()

  while IFS=$'\t' read -r name src; do
    [ -n "$name" ] || continue
    case "$seen" in
      *"|$name|"*)
        log "skipping duplicate addon name $name at $src"
        continue
        ;;
    esac
    seen="$seen|$name|"
    names+=("$name")
    srcs+=("$src")
    SET_DIRS+=("$src")
    pick+=(1)
  done < <(discover_addons "$@")

  if [ ${#ONLY_ADDONS[@]} -gt 0 ]; then
    for i in "${!names[@]}"; do
      pick[i]=0
      for name in "${ONLY_ADDONS[@]}"; do
        [ "${names[$i]}" = "$name" ] && pick[i]=1
      done
    done
  fi

  if [ "$CHANGED_ONLY" -eq 1 ]; then
    # git reports physical paths, so addon directories are compared the same way.
    local real=()
    for i in "${!srcs[@]}"; do real+=("$(cd "${srcs[$i]}" && pwd -P)"); done
    for src in "$@"; do
      while IFS= read -r f; do
        [ -n "$f" ] && changed+=("$f")
      done < <(changed_files "$src")
    done
    for i in "${!names[@]}"; do
      [ "${pick[$i]}" -eq 1 ] || continue
      pick[i]=0
      for f in "${changed[@]+"${changed[@]}"}"; do
        case "$f" in
          "${real[$i]}"/*) ;;
          *) continue ;;
        esac
        # A change inside a nested addon belongs to the nested addon.
        best=1
        for j in "${!real[@]}"; do
          [ "$j" != "$i" ] && case "${real[$j]}" in "${real[$i]}"/*) case "$f" in "${real[$j]}"/*) best=0 ;; esac ;; esac
        done
        [ "$best" -eq 1 ] && { pick[i]=1; break; }
      done
    done
  fi

  local members=() tocs=() count=0
  for i in "${!names[@]}"; do
    [ "${pick[$i]}" -eq 1 ] || continue
    members+=("${names[$i]}")
    while IFS= read -r f; do tocs+=("$f"); done < <(find "${srcs[$i]}" -maxdepth 1 -type f -name '*.toc')
  done

  if [ ${#members[@]} -eq 0 ]; then
    [ ${#names[@]} -gt 0 ] && log "nothing selected to sync" || log "no addons found in: $*"
    return 0
  fi

  for i in "${!names[@]}"; do
    [ "${pick[$i]}" -eq 1 ] || continue
    if [ -n "$WOW_DEV_SUFFIX" ]; then
      count=0
      for j in "${!srcs[@]}"; do
        [ "${pick[$j]}" -eq 0 ] && case "${srcs[$j]}" in "${srcs[$i]}"/*) count=$((count + 1)) ;; esac
      done
      [ "$count" -gt 0 ] && log "warning: ${names[$i]} goes out as ${names[$i]}-$WOW_DEV_SUFFIX while $count nested addon(s) stay on the released ${names[$i]}; sync them together or set WOW_DEV_SUFFIX=''"
    fi
    sync_addon "${names[$i]}" "${srcs[$i]}" "$dry" "${members[@]}" || status=1
  done

  if [ -n "$WOW_DEV_SUFFIX" ]; then
    install_switch_addon dev "${WOW_INTERFACE:-$(max_interface "${tocs[@]+"${tocs[@]}"}")}" "$dry" || status=1
  fi
  return "$status"
}

default_repos() {
  local entry
  local IFS=,
  for entry in ${CODER_REPO_DIRS:-}; do
    entry=$(printf '%s' "$entry" | tr -d '[:space:]')
    [ -n "$entry" ] || continue
    [ -d "$HOME/$entry" ] || continue
    printf '%s\n' "$HOME/$entry"
  done
}

watch_repos() {
  local dry=$1
  shift

  if ! command -v inotifywait >/dev/null 2>&1; then
    log "inotifywait not found; install inotify-tools to use --watch"
    return 1
  fi

  sync_all "$dry" "$@" || true
  log "watching for changes"
  while inotifywait -qq -r -e modify,create,delete,move --exclude '/\.git/' "$@"; do
    sleep 1
    sync_all "$dry" "$@" || true
  done
}

ONLY_ADDONS=()
CHANGED_ONLY=0

main() {
  local watch=0 dry="" off=0 any_suffix=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --watch)
        watch=1
        shift
        ;;
      --dry-run)
        dry="--dry-run"
        shift
        ;;
      --addon)
        [ $# -ge 2 ] || { usage >&2; return 2; }
        ONLY_ADDONS+=("$2")
        shift 2
        ;;
      --changed)
        CHANGED_ONLY=1
        shift
        ;;
      --off)
        off=1
        shift
        ;;
      --any-suffix)
        any_suffix=1
        shift
        ;;
      -h | --help)
        usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        usage >&2
        return 2
        ;;
      *) break ;;
    esac
  done

  local configured=${WOW_DEV_SUFFIX_CONFIGURED:-}
  if [ "$any_suffix" -eq 0 ] && [ -n "$configured" ] && [ -n "$WOW_DEV_SUFFIX" ] && [ "$WOW_DEV_SUFFIX" != "$configured" ]; then
    log "refusing suffix '$WOW_DEV_SUFFIX': this workspace uses '$configured'; a second dev copy of an addon conflicts with the first (--any-suffix overrides)"
    return 2
  fi

  local key_file=${RCLONE_CONFIG_WOW_KEY_FILE:-}
  if [ -n "$key_file" ] && [ ! -f "${key_file/#\~/$HOME}" ]; then
    log "$key_file is missing; create it with: coder secret create wow-sync-key --file ~/.ssh/wow-sync < ~/.ssh/wow-sync"
    return 1
  fi

  if ! rclone lsd "$WOW_REMOTE:$WOW_ADDONS_PATH" --contimeout 15s --timeout 60s >/dev/null 2>&1; then
    log "cannot list $WOW_REMOTE:$WOW_ADDONS_PATH; check the RCLONE_CONFIG_${WOW_REMOTE^^}_* settings and that the sync server is up"
    return 1
  fi

  if [ "$WOW_ADDONS_PATH" != "/" ] && [ "${WOW_ADDONS_PATH##*/}" != "AddOns" ]; then
    log "warning: $WOW_ADDONS_PATH is not named AddOns; check the remote path"
  fi

  if [ "$off" -eq 1 ]; then
    [ -n "$WOW_DEV_SUFFIX" ] || { log "--off needs WOW_DEV_SUFFIX; nothing to switch"; return 1; }
    install_switch_addon release "${WOW_INTERFACE:-}" "$dry"
    return
  fi

  local repos=() entry
  if [ $# -gt 0 ]; then
    repos=("$@")
  else
    while IFS= read -r entry; do
      repos+=("$entry")
    done < <(default_repos)
  fi

  if [ ${#repos[@]} -eq 0 ]; then
    log "no checkouts to sync; pass them as arguments or set CODER_REPO_DIRS"
    return 1
  fi

  if [ "$watch" -eq 1 ]; then
    watch_repos "$dry" "${repos[@]}"
  else
    sync_all "$dry" "${repos[@]}"
  fi
}

main "$@"
