#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/run" "$tmp/bin"
printf 'ready=1\n' > "$tmp/run/ready"

cat > "$tmp/bin/ssh-keyscan" <<'EOF'
#!/bin/sh
[ "${AUTO_CODE_TEST_FAIL_SSH:-0}" != 1 ]
EOF
chmod 0755 "$tmp/bin/ssh-keyscan"

health() {
  HOME="$tmp/home" PATH="$tmp/bin:/usr/bin:/bin" AUTO_CODE_RUN_DIR="$tmp/run" \
    "$repo_dir/bin/auto-code-health"
}

health
if AUTO_CODE_TEST_FAIL_SSH=1 health; then exit 1; fi
chmod 0500 "$tmp/home"
if health; then exit 1; fi
chmod 0700 "$tmp/home"
rm "$tmp/run/ready"
if health; then exit 1; fi

printf 'PASS: workspace health contract\n'
