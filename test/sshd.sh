#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/.ssh" "$tmp/bin"

cat > "$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  install|chmod) exit 0 ;;
  test) shift; /bin/test "$@" ;;
  /usr/sbin/sshd) printf 'sshd:%s\n' "$*" >> "$AUTO_CODE_TEST_LOG"; exit 0 ;;
  *) exec "$@" ;;
esac
EOF
cat > "$tmp/bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -l ] || exit 0
grep -q malformed "${!#}" && exit 1
exit 0
EOF
chmod 0755 "$tmp/bin/sudo" "$tmp/bin/ssh-keygen"

check_rejected() {
  local kind=$1 source=${2:-/missing}
  : > "$tmp/log"
  if HOME="$tmp/home" PATH="$tmp/bin:/usr/bin:/bin" AUTO_CODE_TEST_LOG="$tmp/log" \
    AUTO_CODE_AUTHORIZED_KEYS_FILE="$source" "$repo_dir/bin/auto-code-sshd" start; then
    echo "sshd test: malformed $kind key was accepted" >&2
    exit 1
  fi
  test ! -s "$tmp/log"
}

printf 'malformed manual key\n' > "$tmp/home/.ssh/authorized_keys"
check_rejected manual
rm "$tmp/home/.ssh/authorized_keys"
printf 'malformed managed key\n' > "$tmp/managed.pub"
check_rejected managed "$tmp/managed.pub"

printf 'PASS: malformed SSH keys reject startup\n'
