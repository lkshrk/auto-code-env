#!/usr/bin/env bash

set -euo pipefail

: "${CODER_DOTFILES_URL:?CODER_DOTFILES_URL is required}"
: "${CODER_DOTFILES_SOURCE_DIR:?CODER_DOTFILES_SOURCE_DIR is required}"

mkdir -p "$(dirname "$CODER_DOTFILES_SOURCE_DIR")"

# The checkout belongs to the user. Fetch remote state for visibility, but
# never merge, reset, clean, or otherwise alter their working tree.
if [[ -d "$CODER_DOTFILES_SOURCE_DIR/.git" ]]; then
  git -C "$CODER_DOTFILES_SOURCE_DIR" remote set-url origin "$CODER_DOTFILES_URL"
  git -C "$CODER_DOTFILES_SOURCE_DIR" fetch --quiet origin
elif [[ -e "$CODER_DOTFILES_SOURCE_DIR" ]]; then
  printf 'dotfiles source exists but is not a Git checkout: %s\n' \
    "$CODER_DOTFILES_SOURCE_DIR" >&2
  exit 1
else
  git clone --quiet "$CODER_DOTFILES_URL" "$CODER_DOTFILES_SOURCE_DIR"
fi

printf 'dotfiles source: %s (preserved)\n' "$CODER_DOTFILES_SOURCE_DIR"
