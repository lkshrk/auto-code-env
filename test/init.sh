#!/usr/bin/env bash
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

source_dir=$tmp/source
home=$tmp/home
run_dir=$tmp/run
fake_bin=$tmp/bin
log=$tmp/init.log

mkdir -p "$source_dir/scripts" "$source_dir/dotfiles/omni/.config/omni" "$source_dir/dotfiles/zshrc" "$fake_bin" "$home"
git init -q "$source_dir"
printf '{}\n' > "$source_dir/dotfiles/omni/.config/omni/settings.json"
printf '# test zshrc\n' > "$source_dir/dotfiles/zshrc/.zshrc"

cat > "$source_dir/scripts/volatile-dots.sh" <<'EOF'
#!/bin/sh
printf 'volatile:%s\n' "$1" >> "$AUTO_CODE_TEST_LOG"
[ "$1" != prepare ] || [ "${AUTO_CODE_TEST_FAIL_PREPARE:-0}" != 1 ]
EOF
chmod 0755 "$source_dir/scripts/volatile-dots.sh"

cat > "$fake_bin/omni" <<'EOF'
#!/bin/sh
printf 'omni:%s\n' "$*" >> "$AUTO_CODE_TEST_LOG"
[ "${AUTO_CODE_TEST_FAIL_OMNI:-0}" != 1 ] || exit 1
mkdir -p "$HOME/.config/omni"
ln -sfn "$HOME/dotfiles/dotfiles/omni/.config/omni/settings.json" "$HOME/.config/omni/settings.json"
ln -sfn "$HOME/dotfiles/dotfiles/zshrc/.zshrc" "$HOME/.zshrc"
EOF

cat > "$fake_bin/docker" <<'EOF'
#!/bin/sh
[ "$1" = info ]
[ "${AUTO_CODE_TEST_FAIL_DOCKER:-0}" != 1 ]
EOF
cat > "$fake_bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "$fake_bin/omni" "$fake_bin/docker" "$fake_bin/flock"

run_init() {
  HOME="$home" \
  PATH="$fake_bin:/usr/bin:/bin" \
  AUTO_CODE_DOTFILES_SOURCE="$source_dir" \
  AUTO_CODE_RUN_DIR="$run_dir" \
  XDG_RUNTIME_DIR="$tmp/runtime" \
  AUTO_CODE_TEST_LOG="$log" \
  AUTO_CODE_REQUIRE_DOCKER=1 \
    "$repo_dir/bin/auto-code-init"
}

run_init
test -d "$home/dotfiles/.git"
test -d "$home/workspace"
test -s "$run_dir/ready"
test -L "$home/.config/omni/settings.json"
test -L "$home/.zshrc"
test "$(sed -n '1p' "$log")" = volatile:prepare
test "$(sed -n '2p' "$log")" = 'omni:--config'" $home/dotfiles/dotfiles/omni/.config/omni/settings.json --yes dots sync --use-repo"
test "$(sed -n '3p' "$log")" = volatile:detach

printf 'preserve me\n' > "$home/dotfiles/local-change"
run_init
grep -qx 'preserve me' "$home/dotfiles/local-change"
test "$(grep -c '^omni:' "$log")" = 2

rm -f "$run_dir/ready"
if HOME="$home" PATH="$fake_bin:/usr/bin:/bin" \
  AUTO_CODE_DOTFILES_SOURCE="$source_dir" AUTO_CODE_RUN_DIR="$run_dir" \
  XDG_RUNTIME_DIR="$tmp/runtime" \
  AUTO_CODE_TEST_LOG="$log" AUTO_CODE_TEST_FAIL_OMNI=1 \
  "$repo_dir/bin/auto-code-init"; then
  echo 'init test: failed Omni unexpectedly produced success' >&2
  exit 1
fi
test ! -e "$run_dir/ready"
test "$(tail -1 "$log")" = volatile:detach

if HOME="$home" PATH="$fake_bin:/usr/bin:/bin" \
  AUTO_CODE_DOTFILES_SOURCE="$source_dir" AUTO_CODE_RUN_DIR="$run_dir" \
  XDG_RUNTIME_DIR="$tmp/runtime" AUTO_CODE_TEST_LOG="$log" AUTO_CODE_TEST_FAIL_DOCKER=1 \
  AUTO_CODE_REQUIRE_DOCKER=1 "$repo_dir/bin/auto-code-init"; then
  echo 'init test: unavailable required Docker unexpectedly produced success' >&2
  exit 1
fi
test ! -e "$run_dir/ready"

if HOME="$home" PATH="$fake_bin:/usr/bin:/bin" \
  AUTO_CODE_DOTFILES_SOURCE="$source_dir" AUTO_CODE_RUN_DIR="$run_dir" \
  XDG_RUNTIME_DIR="$tmp/runtime" AUTO_CODE_TEST_LOG="$log" AUTO_CODE_TEST_FAIL_PREPARE=1 \
  "$repo_dir/bin/auto-code-init"; then
  echo 'init test: failed volatile prepare unexpectedly produced success' >&2
  exit 1
fi
test ! -e "$run_dir/ready"
test "$(tail -1 "$log")" = volatile:detach

printf 'PASS: strict workspace initialization\n'
