#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
archive_dir=$tmp/archive
archive=$archive_dir/workspace.tar.gz
mkdir -p "$archive_dir" "$tmp/payload/home/dev" "$tmp/payload/var/lib/auto-code-env/sshd" "$tmp/bin"
printf 'restore\n' > "$tmp/payload/home/dev/restored"
printf 'restored-key\n' > "$tmp/payload/var/lib/auto-code-env/sshd/ssh_host_ed25519_key"
tar -czf "$archive" -C "$tmp/payload" home/dev var/lib/auto-code-env/sshd

# A failed stop must leave the live workspace alone: the destructive compose run
# must not be issued.
cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AUTO_CODE_TEST_LOG"
case " $* " in
  *' stop dev '*) exit 1 ;;
  *' run '*) exit 99 ;;
esac
EOF
chmod 0755 "$tmp/bin/docker"
: > "$tmp/log"
if PATH="$tmp/bin:/usr/bin:/bin" AUTO_CODE_TEST_LOG="$tmp/log" \
  AUTO_CODE_COMPOSE_FILE="$tmp/compose.yaml" "$repo_dir/scripts/workspace-state.sh" restore "$archive"; then
  echo 'workspace-state test: restore continued after stop failure' >&2
  exit 1
fi
grep -q ' stop dev' "$tmp/log"
if grep -q ' run ' "$tmp/log"; then
  echo 'workspace-state test: restore ran after stop failure' >&2
  exit 1
fi

# Run the compose helper locally against a disposable fake container root. Its
# tar shim fails only extraction, so a failed restore must put the backup back.
root=$tmp/root
mkdir -p "$root/home/dev/workspace" "$root/var/lib/auto-code-env/sshd"
printf 'keep\n' > "$root/home/dev/workspace/keep"
printf 'old-key\n' > "$root/var/lib/auto-code-env/sshd/ssh_host_ed25519_key"
cat > "$tmp/bin/tar" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = -xzf ] && [ ! -e "$AUTO_CODE_TEST_TAR_CALLS" ]; then
    : > "$AUTO_CODE_TEST_TAR_CALLS"
    exit 1
  fi
done
exec /usr/bin/tar "$@"
EOF
cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AUTO_CODE_TEST_LOG"
case " $* " in
  *' stop dev '*) exit 0 ;;
  *' up '*) exit 99 ;;
  *' run '*)
    while [ "$1" != -c ]; do shift; done
    program=$2
    program=${program//\/home\/dev/$AUTO_CODE_TEST_ROOT/home/dev}
    program=${program//\/var\/lib\/auto-code-env\/sshd/$AUTO_CODE_TEST_ROOT/var/lib/auto-code-env/sshd}
    program=${program//\/backup/$AUTO_CODE_TEST_ARCHIVE_DIR}
    program=${program//-C \//-C "$AUTO_CODE_TEST_ROOT"}
    shift 2
    while [ "$1" != bash ]; do shift; done
    PATH="$AUTO_CODE_TEST_BIN:/usr/bin:/bin" bash -c "$program" bash "$2"
    ;;
esac
EOF
chmod 0755 "$tmp/bin/docker" "$tmp/bin/tar"
: > "$tmp/log"
if PATH="$tmp/bin:/usr/bin:/bin" AUTO_CODE_TEST_BIN="$tmp/bin" AUTO_CODE_TEST_ROOT="$root" \
  AUTO_CODE_TEST_ARCHIVE_DIR="$archive_dir" AUTO_CODE_TEST_TAR_CALLS="$tmp/tar-calls" AUTO_CODE_TEST_LOG="$tmp/log" \
  AUTO_CODE_COMPOSE_FILE="$tmp/compose.yaml" "$repo_dir/scripts/workspace-state.sh" restore "$archive"; then
  echo 'workspace-state test: extraction failure was accepted' >&2
  exit 1
fi
grep -qx keep "$root/home/dev/workspace/keep"
grep -qx old-key "$root/var/lib/auto-code-env/sshd/ssh_host_ed25519_key"
test ! -e "$root/home/dev/restored"
if grep -q ' up ' "$tmp/log"; then
  echo 'workspace-state test: restore started after failed extraction' >&2
  exit 1
fi

printf 'PASS: workspace restore failure handling\n'
