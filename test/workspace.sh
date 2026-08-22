#!/usr/bin/env bash
set -euo pipefail

target=${1:-}
old_image=${2:-}
new_image=${3:-}
[[ $target =~ ^dev-(full|pilot|hermes|both)$ && -n $old_image && -n $new_image ]] || {
  echo "usage: $0 <dev-full|dev-pilot|dev-hermes|dev-both> <old-image> <new-image>" >&2
  exit 2
}

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
project="auto-code-workspace-${RANDOM}-${RANDOM}"
port=$((20000 + RANDOM % 20000))
known_hosts=$tmp/known_hosts
backup=$tmp/workspace.tar.gz

cleanup() {
  COMPOSE_PROJECT_NAME=$project AUTO_CODE_IMAGE=${AUTO_CODE_IMAGE:-$old_image} \
    AUTO_CODE_AUTHORIZED_KEYS_FILE=$tmp/authorized_keys AUTO_CODE_SSH_PORT=$port \
    docker compose -f "$repo_dir/workspace.compose.yaml" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N '' -f "$tmp/client"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/client-rotated"
cp "$tmp/client.pub" "$tmp/authorized_keys"

export COMPOSE_PROJECT_NAME=$project
export AUTO_CODE_IMAGE=$old_image
export AUTO_CODE_AUTHORIZED_KEYS_FILE=$tmp/authorized_keys
export AUTO_CODE_SSH_BIND=127.0.0.1
export AUTO_CODE_SSH_PORT=$port
export AUTO_CODE_COMPOSE_FILE=$repo_dir/workspace.compose.yaml

compose() { docker compose -f "$repo_dir/workspace.compose.yaml" "$@"; }

scan_host() {
  : > "$known_hosts"
  for _ in $(seq 1 30); do
    ssh-keyscan -q -p "$port" 127.0.0.1 > "$known_hosts" 2>/dev/null && return 0
    sleep 1
  done
  echo "workspace[$target]: SSH host never became ready" >&2
  return 1
}

remote() {
  local key=$1
  shift
  ssh -p "$port" -i "$key" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" \
    dev@127.0.0.1 "$@"
}

compose up -d --wait
scan_host
remote "$tmp/client" 'test "$(id -u)" = 1000; test -s /run/auto-code-env/ready; docker info >/dev/null; printf "persist\n" > "$HOME/workspace/sentinel"'
first_fingerprint=$(ssh-keygen -lf "$known_hosts" | awk '{print $2}')

compose up -d --force-recreate --wait
scan_host
test "$(ssh-keygen -lf "$known_hosts" | awk '{print $2}')" = "$first_fingerprint"
remote "$tmp/client" 'grep -qx persist "$HOME/workspace/sentinel"'

cp "$tmp/client-rotated.pub" "$tmp/authorized_keys"
compose up -d --force-recreate --wait
scan_host
if remote "$tmp/client" true >/dev/null 2>&1; then
  echo "workspace[$target]: revoked SSH key still works" >&2
  exit 1
fi
remote "$tmp/client-rotated" true

AUTO_CODE_IMAGE=$new_image compose up -d --force-recreate --wait
export AUTO_CODE_IMAGE=$new_image
scan_host
test "$(ssh-keygen -lf "$known_hosts" | awk '{print $2}')" = "$first_fingerprint"
remote "$tmp/client-rotated" 'grep -qx persist "$HOME/workspace/sentinel"; test -s /run/auto-code-env/ready'
if [[ $old_image != "$new_image" ]]; then
  AUTO_CODE_IMAGE=$old_image compose up -d --force-recreate --wait
  export AUTO_CODE_IMAGE=$old_image
  scan_host
  test "$(ssh-keygen -lf "$known_hosts" | awk '{print $2}')" = "$first_fingerprint"
  remote "$tmp/client-rotated" 'grep -qx persist "$HOME/workspace/sentinel"; test -s /run/auto-code-env/ready'

  AUTO_CODE_IMAGE=$new_image compose up -d --force-recreate --wait
  export AUTO_CODE_IMAGE=$new_image
  scan_host
  test "$(ssh-keygen -lf "$known_hosts" | awk '{print $2}')" = "$first_fingerprint"
  remote "$tmp/client-rotated" 'grep -qx persist "$HOME/workspace/sentinel"; test -s /run/auto-code-env/ready'
fi

mkdir -p "$tmp/wrong-archive"
printf 'wrong\n' > "$tmp/wrong-archive/file"
tar -czf "$tmp/wrong.tar.gz" -C "$tmp/wrong-archive" file
if "$repo_dir/scripts/workspace-state.sh" restore "$tmp/wrong.tar.gz" >/dev/null 2>&1; then
  echo "workspace[$target]: unrelated archive was accepted" >&2
  exit 1
fi
compose up -d --wait
scan_host
test "$(ssh-keygen -lf "$known_hosts" | awk '{print $2}')" = "$first_fingerprint"
remote "$tmp/client-rotated" 'grep -qx persist "$HOME/workspace/sentinel"'

"$repo_dir/scripts/workspace-state.sh" backup "$backup"
compose down -v
compose run --rm --no-deps --user root --entrypoint /bin/bash dev -c '
  mkdir -p /home/dev/workspace /var/lib/auto-code-env/sshd
  touch /home/dev/workspace/stale-after-backup /var/lib/auto-code-env/sshd/stale-after-backup
'
"$repo_dir/scripts/workspace-state.sh" restore "$backup"
scan_host
test "$(ssh-keygen -lf "$known_hosts" | awk '{print $2}')" = "$first_fingerprint"
remote "$tmp/client-rotated" 'grep -qx persist "$HOME/workspace/sentinel"; test ! -e "$HOME/workspace/stale-after-backup"; test ! -e /var/lib/auto-code-env/sshd/stale-after-backup; test "$(id -u)" = 1000'

cat > "$tmp/no-restart.yaml" <<'EOF'
services:
  dev:
    restart: "no"
EOF
cat > "$tmp/no-docker.yaml" <<'EOF'
services:
  dev:
    restart: "no"
    environment:
      DOCKER_HOST: unix:///missing
EOF

if docker compose -f "$repo_dir/workspace.compose.yaml" -f "$tmp/no-docker.yaml" up -d --force-recreate --wait --wait-timeout 20 >/dev/null 2>&1; then
  echo "workspace[$target]: unavailable required Docker daemon reached healthy state" >&2
  exit 1
fi

compose run --rm --no-deps --user root --entrypoint chmod dev 0555 /home/dev
if docker compose -f "$repo_dir/workspace.compose.yaml" -f "$tmp/no-restart.yaml" up -d --force-recreate --wait --wait-timeout 20 >/dev/null 2>&1; then
  echo "workspace[$target]: unwritable home reached healthy state" >&2
  exit 1
fi
compose run --rm --no-deps --user root --entrypoint chmod dev 0755 /home/dev

: > "$tmp/authorized_keys"
if docker compose -f "$repo_dir/workspace.compose.yaml" -f "$tmp/no-restart.yaml" up -d --force-recreate --wait --wait-timeout 20 >/dev/null 2>&1; then
  echo "workspace[$target]: missing authorized key reached healthy state" >&2
  exit 1
fi

printf 'PASS: workspace lifecycle %s\n' "$target"
