#!/usr/bin/env bash

set -euo pipefail

: "${WOW_ADDONS_PATH:?WOW_ADDONS_PATH is required}"
: "${WOW_DEV_SUFFIX=Dev}"
: "${WOW_REMOTE:=wow}"
export RCLONE_CONFIG=/dev/null

readonly STAGE_EXCLUDES=(
  --exclude '.git/**'
  --exclude '.github/**'
  --exclude '.claude/**'
  --exclude '.gitignore'
  --exclude '.gitattributes'
  --exclude '.editorconfig'
  --exclude '.luacheckrc'
  --exclude '.pkgmeta'
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
Usage: wow-sync [--watch] [--dry-run] [repo...]

Pushes every addon found in the given checkouts to the game's AddOns directory
on the rclone remote `wow:`, at WOW_ADDONS_PATH. With no repo arguments, uses
CODER_REPO_DIRS.

An addon is any directory holding a .toc file; the addon name comes from the
.toc, not from the directory, so a repository may be named anything.

With WOW_DEV_SUFFIX set (default "Dev"), each addon is installed as
<Name>-<suffix>: the .toc is renamed, its Title is marked, and every
SavedVariables name gains the suffix in the .toc and in the Lua sources. The
dev copy then runs beside the released addon and cannot touch its settings.

The remote is configured entirely through RCLONE_CONFIG_WOW_* environment
variables, which Coder user secrets provide; wow-sync never reads a config file.

  --watch     resync on every change instead of exiting after one pass
  --dry-run   show what rclone would change without writing to the game
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

# Emits "<name>\t<directory>" for every addon directory in the given checkouts.
discover_addons() {
  local repo toc dir name
  for repo in "$@"; do
    [ -d "$repo" ] || continue
    while IFS= read -r toc; do
      dir=${toc%/*}
      name=$(addon_name_from_toc "$toc")
      [ -n "$name" ] || continue
      printf '%s\t%s\n' "$name" "$dir"
    done < <(find "$repo" -maxdepth 3 -type f -name '*.toc' -not -path '*/.git/*' 2>/dev/null)
  done | sort -u
}

# Rewrites the staged copy into the dev variant: renamed .toc files, a marked
# Title, and suffixed SavedVariables names in both the .toc and the Lua sources.
apply_dev_suffix() {
  local stage=$1 name=$2 suffix=$3
  local toc vars=() var expr=""

  while IFS= read -r toc; do
    while IFS= read -r var; do
      [ -n "$var" ] && vars+=("$var")
    done < <(sed -n -E 's/^## SavedVariables(PerCharacter)?:[[:space:]]*//p' "$toc" | tr -d ' \t\r' | tr ',' '\n')
  done < <(find "$stage" -maxdepth 1 -type f -name '*.toc')

  for var in "${vars[@]+"${vars[@]}"}"; do
    expr+="s/\\b\Q${var}\E\\b/${var}${suffix}/g;"
  done

  while IFS= read -r toc; do
    perl -pi -e "s/^(## Title:.*)\$/\$1 [${suffix^^}]/" "$toc"
    [ -n "$expr" ] && perl -pi -e "if (/^## SavedVariables(PerCharacter)?:/) { $expr }" "$toc"
    mv -- "$toc" "$stage/$name-$suffix${toc#"$stage/$name"}"
  done < <(find "$stage" -maxdepth 1 -type f -name "$name*.toc")

  [ -n "$expr" ] || return 0
  find "$stage" -type f -name '*.lua' -not -path '*/Libs/*' -exec perl -pi -e "$expr" {} +
}

sync_addon() {
  local name=$1 src=$2 dry=$3 stage target dest

  case "$name" in
    '' | . | .. | */* | *\\*)
      log "refusing to sync addon with unusable name: $name"
      return 1
      ;;
  esac

  target=$name
  [ -n "$WOW_DEV_SUFFIX" ] && target="$name-$WOW_DEV_SUFFIX"
  dest="$WOW_REMOTE:$WOW_ADDONS_PATH/$target"

  # A destination that exists but holds no <target>.toc belongs to something
  # else; sync would delete its contents, so refuse instead of guessing.
  local existing
  if existing=$(rclone lsf "$dest" --max-depth 1 2>/dev/null) && [ -n "$existing" ] \
    && ! printf '%s\n' "$existing" | grep -qi "^${target}.*\.toc$"; then
    log "refusing to sync $name: $dest exists and is not a $target addon (no $target*.toc)"
    return 1
  fi

  stage=$(mktemp -d -t wow-sync.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -rf '$stage'" RETURN

  rclone copy "$src" "$stage" "${STAGE_EXCLUDES[@]}" || { log "staging $name failed"; return 1; }
  if [ -n "$WOW_DEV_SUFFIX" ]; then
    apply_dev_suffix "$stage" "$name" "$WOW_DEV_SUFFIX" || { log "dev rewrite of $name failed"; return 1; }
  fi

  # rclone sync only ever deletes inside $dest, which is one addon directory,
  # and it verifies size and modtime of everything it writes.
  # shellcheck disable=SC2086
  rclone sync "$stage" "$dest" "${SYNC_FLAGS[@]}" $dry || { log "sync of $name -> $dest failed"; return 1; }
  log "synced $name -> $dest"
}

sync_all() {
  local dry=$1
  shift
  local name src status=0 count=0 seen=""

  while IFS=$'\t' read -r name src; do
    [ -n "$name" ] || continue
    case "$seen" in
      *"|$name|"*)
        log "skipping duplicate addon name $name at $src"
        continue
        ;;
    esac
    seen="$seen|$name|"
    count=$((count + 1))
    sync_addon "$name" "$src" "$dry" || status=1
  done < <(discover_addons "$@")

  [ "$count" -gt 0 ] || log "no addons found in: $*"
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

main() {
  local watch=0 dry=""
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
