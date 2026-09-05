#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPARE_SCRIPT="$SCRIPT_DIR/../shared/prepare-dotfiles.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"

SEED_REPO="$TEST_ROOT/seed"
REMOTE_REPO="$TEST_ROOT/remote.git"
export CODER_DOTFILES_SOURCE_DIR="$HOME/dotfiles"
export CODER_DOTFILES_URL="$REMOTE_REPO"

git init --quiet --initial-branch=main "$SEED_REPO"
git -C "$SEED_REPO" config user.name test
git -C "$SEED_REPO" config user.email test@example.invalid
git -C "$SEED_REPO" config commit.gpgsign false
printf 'v1\n' > "$SEED_REPO/tracked.txt"
git -C "$SEED_REPO" add tracked.txt
git -C "$SEED_REPO" commit --quiet -m initial
git clone --quiet --bare "$SEED_REPO" "$REMOTE_REPO"
git -C "$SEED_REPO" remote add origin "$REMOTE_REPO"

bash "$PREPARE_SCRIPT"

[[ -d "$CODER_DOTFILES_SOURCE_DIR/.git" ]]
[[ "$(<"$CODER_DOTFILES_SOURCE_DIR/tracked.txt")" == "v1" ]]

printf 'local edit\n' > "$CODER_DOTFILES_SOURCE_DIR/source-only.txt"
printf 'local tracked edit\n' > "$CODER_DOTFILES_SOURCE_DIR/tracked.txt"

printf 'v2\n' > "$SEED_REPO/tracked.txt"
git -C "$SEED_REPO" add tracked.txt
git -C "$SEED_REPO" commit --quiet -m update
git -C "$SEED_REPO" push --quiet origin main

bash "$PREPARE_SCRIPT"

[[ "$(<"$CODER_DOTFILES_SOURCE_DIR/source-only.txt")" == "local edit" ]]
[[ "$(<"$CODER_DOTFILES_SOURCE_DIR/tracked.txt")" == "local tracked edit" ]]
git -C "$CODER_DOTFILES_SOURCE_DIR" rev-parse --verify --quiet origin/main >/dev/null

non_git_source="$HOME/non-git-dotfiles"
mkdir -p "$non_git_source"
printf 'keep\n' > "$non_git_source/user-data"
if CODER_DOTFILES_SOURCE_DIR="$non_git_source" \
  bash "$PREPARE_SCRIPT" >/dev/null 2>&1; then
  printf 'FAIL: non-Git source directory was accepted\n' >&2
  exit 1
fi
[[ "$(<"$non_git_source/user-data")" == keep ]]

printf 'PASS: source cloned once, local edits preserved, non-Git path rejected\n'
