#!/usr/bin/env bash

set -euo pipefail

: "${WOW_ADDONS_DIR:?WOW_ADDONS_DIR is required}"

readonly RSYNC_EXCLUDES=(
  --exclude=.git/
  --exclude=.github/
  --exclude=.claude/
  --exclude=.gitignore
  --exclude=.gitattributes
  --exclude=.editorconfig
  --exclude=.luacheckrc
  --exclude=.pkgmeta
  --exclude=node_modules/
)

usage() {
  cat <<'USAGE'
Usage: wow-sync [--watch] [repo...]

Copies every addon found in the given checkouts into the WoW AddOns directory
named by WOW_ADDONS_DIR. With no repo arguments, uses CODER_REPO_DIRS.

An addon is any directory holding a .toc file; the addon name comes from the
.toc, not from the directory, so a repository may be named anything.

  --watch   resync on every change instead of exiting after one pass
USAGE
}

log() { printf 'wow-sync: %s\n' "$1" >&2; }

addons_root() {
  local root
  if ! root=$(cd -- "$WOW_ADDONS_DIR" 2>/dev/null && pwd -P); then
    log "addons directory does not exist: $WOW_ADDONS_DIR"
    return 1
  fi
  printf '%s\n' "$root"
}

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

sync_addon() {
  local name=$1 src=$2 root=$3 target resolved

  case "$name" in
    '' | . | .. | */* | *\\*)
      log "refusing to sync addon with unusable name: $name"
      return 1
      ;;
  esac

  target="$root/$name"
  mkdir -p -- "$target"

  # --delete makes a wrong target destructive: it must resolve to a direct
  # child of the AddOns root, never the root itself or anything outside it.
  resolved=$(cd -- "$target" && pwd -P)
  if [ "$resolved" = "$root" ] || [ "${resolved%/*}" != "$root" ]; then
    log "refusing to sync into $resolved, which is not a direct child of $root"
    return 1
  fi

  rsync -rt --delete --no-perms --no-owner --no-group --omit-dir-times \
    "${RSYNC_EXCLUDES[@]}" "$src/" "$resolved/"
  log "synced $name from $src"
}

sync_all() {
  local root=$1
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
    sync_addon "$name" "$src" "$root" || status=1
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
  local root=$1
  shift

  if ! command -v inotifywait >/dev/null 2>&1; then
    log "inotifywait not found; install inotify-tools to use --watch"
    return 1
  fi

  sync_all "$root" "$@" || true
  log "watching for changes"
  while inotifywait -qq -r -e modify,create,delete,move --exclude '/\.git/' "$@"; do
    sleep 1
    sync_all "$root" "$@" || true
  done
}

main() {
  local watch=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --watch)
        watch=1
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

  local root
  root=$(addons_root)

  if [ "${root##*/}" != "AddOns" ]; then
    log "warning: $root is not named AddOns; check the mounted path"
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
    watch_repos "$root" "${repos[@]}"
  else
    sync_all "$root" "${repos[@]}"
  fi
}

main "$@"
