#!/usr/bin/env bash
set -euo pipefail

action=${1:-}
archive=${2:-}
compose_file=${AUTO_CODE_COMPOSE_FILE:-workspace.compose.yaml}

usage() {
  echo "usage: $0 backup <archive.tar.gz> | restore <archive.tar.gz>" >&2
  exit 2
}

[[ $action == backup || $action == restore ]] || usage
[[ -n $archive ]] || usage
archive_dir=$(dirname "$archive")
[[ $action == restore ]] || mkdir -p "$archive_dir"
archive_dir=$(cd "$archive_dir" && pwd)
archive_name=$(basename "$archive")
[[ $archive_name =~ ^[A-Za-z0-9._-]+$ ]] || { echo "workspace-state: unsafe archive name: $archive_name" >&2; exit 2; }
archive=$archive_dir/$archive_name

validate_archive() (
  local file=$1 members
  members=$(mktemp)
  trap 'rm -f "$members"' EXIT
  tar -tzf "$file" > "$members"
  grep -Eq '^home/dev(/|$)' "$members"
  grep -qx 'var/lib/auto-code-env/sshd/ssh_host_ed25519_key' "$members"
  ! awk '
    /^\// || /(^|\/)\.\.($|\/)/ { bad = 1 }
    !/^home\/dev(\/|$)/ && !/^var\/lib\/auto-code-env\/sshd(\/|$)/ { bad = 1 }
    END { exit bad ? 0 : 1 }
  ' "$members"
)

case $action in
  backup)
    docker compose -f "$compose_file" stop dev
    trap 'docker compose -f "$compose_file" start dev >/dev/null 2>&1 || true' EXIT
    docker compose -f "$compose_file" run --rm --no-deps --user root \
      --entrypoint /bin/bash -v "$archive_dir:/backup" dev -c '
        set -e
        name=$1
        tmp="/backup/.$name.tmp.$$"
        trap '\''rm -f "$tmp"'\'' EXIT
        tar -czf "$tmp" --numeric-owner -C / home/dev var/lib/auto-code-env/sshd
        tar -tzf "$tmp" >/dev/null
        mv -f "$tmp" "/backup/$name"
        trap - EXIT
      ' bash "$archive_name"
    docker compose -f "$compose_file" start dev
    trap - EXIT
    ;;
  restore)
    [[ -f $archive ]] || { echo "workspace-state: archive not found: $archive" >&2; exit 1; }
    validate_archive "$archive" || { echo "workspace-state: invalid workspace archive: $archive" >&2; exit 1; }
    docker compose -f "$compose_file" stop dev
    docker compose -f "$compose_file" run --rm --no-deps --user root \
      --entrypoint /bin/bash -v "$archive_dir:/backup" dev -c '
        set -e
        archive="/backup/$1"
        rollback="/backup/.restore-rollback.$$.tar.gz"
        tar -czf "$rollback" --numeric-owner -C / home/dev var/lib/auto-code-env/sshd
        restore_rollback() {
          find /home/dev -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
          find /var/lib/auto-code-env/sshd -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
          tar -xzf "$rollback" --numeric-owner -C /
        }
        find /home/dev -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        find /var/lib/auto-code-env/sshd -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        if ! tar -xzf "$archive" --numeric-owner -C /; then
          restore_rollback
          rm -f "$rollback"
          exit 1
        fi
        rm -f "$rollback"
      ' bash "$archive_name"
    docker compose -f "$compose_file" up -d --wait dev
    ;;
esac
