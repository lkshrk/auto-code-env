#!/usr/bin/env bash
# Own owners act as the agent account (GH_TOKEN), all others as the personal one (GH_TOKEN_PERSONAL).

set -euo pipefail

: "${GITHUB_OWN_OWNERS:=lkshrk loc-news routivo webdev-harke}"
: "${GITHUB_AGENT_NAME:=agent-npa}"
: "${GITHUB_AGENT_EMAIL:=295295787+agent-npa@users.noreply.github.com}"
: "${GITHUB_PERSONAL_NAME:=lkshrk}"
: "${GITHUB_PERSONAL_EMAIL:=5067446+lkshrk@users.noreply.github.com}"

self="$HOME/.local/bin/github-identity"

owner_of() {
  local s=${1%.git}
  case "$s" in
    *github.com[:/]*) s=${s#*github.com[:/]} ;;
    */*) ;;
    *) return 0 ;;
  esac
  s=${s#/}
  printf '%s\n' "${s%%/*}"
}

is_own() {
  case " $GITHUB_OWN_OWNERS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# A fork checkout is judged by the repository it was forked from.
checkout_owner() {
  local remote url
  for remote in upstream origin; do
    if url=$(git remote get-url "$remote" 2>/dev/null); then
      owner_of "$url"
      return 0
    fi
  done
}

identity_for() {
  local owner=$1
  if [ -n "$owner" ] && ! is_own "$owner" && [ -n "${GH_TOKEN_PERSONAL:-}" ]; then
    echo personal
  else
    echo agent
  fi
}

token_for() {
  if [ "$1" = personal ]; then
    printf '%s' "$GH_TOKEN_PERSONAL"
  else
    printf '%s' "${GH_TOKEN:-}"
  fi
}

set_author() {
  local dir=$1 who=$2
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return 0
  if [ "$who" = personal ]; then
    git -C "$dir" config user.name "$GITHUB_PERSONAL_NAME"
    git -C "$dir" config user.email "$GITHUB_PERSONAL_EMAIL"
  fi
}

real_gh() {
  local dir candidate
  local IFS=:
  for dir in $PATH; do
    candidate="$dir/gh"
    [ -x "$candidate" ] || continue
    [ "$(readlink -f "$candidate")" = "$(readlink -f "$HOME/.local/bin/gh")" ] && continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

cmd_gh() {
  local owner="" prev="" arg target="" sub1="${1:-}" sub2="${2:-}"
  for arg in "$@"; do
    case "$prev" in
      -R | --repo) owner=$(owner_of "$arg") ;;
    esac
    case "$arg" in
      --repo=*) owner=$(owner_of "${arg#--repo=}") ;;
    esac
    prev=$arg
  done

  if [ -z "$owner" ] && [ "$sub1" = repo ]; then
    case "$sub2" in
      clone | fork | view)
        for arg in "${@:3}"; do
          case "$arg" in
            -*) ;;
            *) target=$arg; owner=$(owner_of "$arg"); break ;;
          esac
        done
        ;;
    esac
  fi
  [ -n "$owner" ] || owner=$(checkout_owner)

  local who gh status=0
  who=$(identity_for "$owner")
  gh=$(real_gh) || { echo "github-identity: gh is not installed" >&2; return 127; }
  GH_TOKEN=$(token_for "$who") "$gh" "$@" || status=$?

  if [ "$status" -eq 0 ] && [ "$who" = personal ]; then
    if [ -n "$target" ] && [ "$sub1" = repo ] && { [ "$sub2" = clone ] || [ "$sub2" = fork ]; }; then
      set_author "$(basename "${target%.git}")" personal
    else
      set_author . personal
    fi
  fi
  return "$status"
}

# git credential helper protocol: key=value lines on stdin, answer on stdout.
cmd_credential() {
  [ "${1:-}" = get ] || return 0
  local line host="" path="" owner who
  while IFS= read -r line && [ -n "$line" ]; do
    case "$line" in
      host=*) host=${line#host=} ;;
      path=*) path=${line#path=} ;;
    esac
  done
  [ "$host" = github.com ] || return 0

  owner=$(owner_of "$path")
  if [ -z "$owner" ] || is_own "$owner"; then
    owner=$(checkout_owner)
    [ -n "$owner" ] || owner=$(owner_of "$path")
  fi
  who=$(identity_for "$owner")
  printf 'username=x-access-token\npassword=%s\n' "$(token_for "$who")"
}

cmd_install() {
  mkdir -p "$HOME/.local/bin"
  if [ "$(readlink -f "$0")" != "$(readlink -f "$self")" ]; then
    install -m 0755 "$0" "$self"
  fi
  printf '#!/bin/sh\nexec "%s" gh "$@"\n' "$self" > "$HOME/.local/bin/gh"
  chmod 0755 "$HOME/.local/bin/gh"

  git config --global user.name "$GITHUB_AGENT_NAME"
  git config --global user.email "$GITHUB_AGENT_EMAIL"
  git config --global --replace-all credential.https://github.com.helper ""
  git config --global --add credential.https://github.com.helper "!$self credential"
  git config --global credential.https://github.com.useHttpPath true
  git config --global --replace-all url.https://github.com/.insteadOf git@github.com:
  git config --global --add url.https://github.com/.insteadOf ssh://git@github.com/
}

case "${1:-}" in
  gh) shift; cmd_gh "$@" ;;
  credential) shift; cmd_credential "$@" ;;
  install) cmd_install ;;
  whoami)
    if [ -n "${2:-}" ]; then identity_for "$(owner_of "$2")"; else identity_for "$(checkout_owner)"; fi
    ;;
  *) echo "usage: github-identity install|gh ...|credential get|whoami [OWNER/REPO]" >&2; exit 2 ;;
esac
