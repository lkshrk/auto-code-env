#!/usr/bin/env bash
# Host-side image contract. Usage: test/smoke.sh <target> <image-ref>
set -euo pipefail

target=${1:-}
image=${2:-}
platform=${PLATFORM:-linux/amd64}

case "$target" in
  dev-full|dev-pilot|dev-hermes|dev-both) ;;
  *) echo "usage: $0 <dev-full|dev-pilot|dev-hermes|dev-both> <image-ref>" >&2; exit 2 ;;
esac
[[ -n "$image" ]] || { echo "usage: $0 <target> <image-ref>" >&2; exit 2; }

fail() { echo "smoke[$target]: $*" >&2; exit 1; }
run() { docker run --rm --platform "$platform" --user dev --entrypoint /bin/bash "$image" -c "$1"; }
run_offline() { docker run --rm --network none --platform "$platform" --user dev --entrypoint /bin/bash "$image" -c "$1"; }

docker image inspect "$image" >/dev/null || fail "image not found: $image"

run 'test "$(id -u)" = 1000 && test "$(id -g)" = 1000 && test "$USER" = dev && test "$HOME" = /home/dev' \
  || fail 'dev identity is not uid/gid 1000 with /home/dev'

run 'for tool in bash git curl jq make omni ssh ssh-add sshd auto-code-health auto-code-init auto-code-sshd rbw rbw-agent ssh-secret-run pinentry-curses; do command -v "$tool" >/dev/null || exit 1; done' \
  || fail 'core tools are missing'

run '
  . /usr/local/share/auto-code-env/versions.env
  test "$(rbw --version | awk "{print \$2}")" = "$RBW_VERSION"
  test "$XDG_RUNTIME_DIR" = /run/user/1000
  test "$SSH_AUTH_SOCK" = /run/user/1000/rbw/ssh-agent-socket
  ssh -G github.com 2>/dev/null | grep -qx "forwardagent no"
  ssh -G github.com 2>/dev/null | grep -qx "hashknownhosts yes"
  ssh -G github.com 2>/dev/null | grep -qx "stricthostkeychecking accept-new"
  ! grep -R -l -- "BEGIN OPENSSH PRIVATE KEY" /home/dev /opt/dotfiles >/dev/null 2>&1
  test "$(AUTO_CODE_SSH_KEY_FILE=/missing ssh-secret-run 2>&1 || true)" = "ssh-secret-run: key not found: /missing"
' || fail 'rbw or hardened SSH client contract is broken'

run '
  set -eu
  tmp=$(mktemp -d)
  trap "rm -rf \"$tmp\"" EXIT
  ssh-keygen -q -t ed25519 -N "" -f "$tmp/key"
  AUTO_CODE_SSH_KEY_FILE="$tmp/key" ssh-secret-run ssh-add -l | grep -q ED25519
  printf bad > "$tmp/bad-key"
  if AUTO_CODE_SSH_KEY_FILE="$tmp/bad-key" ssh-secret-run touch "$tmp/secret-payload" >/dev/null 2>&1; then exit 1; fi
  test ! -e "$tmp/secret-payload"
' || fail 'explicit SSH secret failed to create an isolated agent'

run '
  set -eu
  test ! -e /etc/ssh/ssh_host_ed25519_key
  tmp=$(mktemp -d)
  trap "auto-code-sshd stop; rm -rf \"$tmp\"" EXIT
  ssh-keygen -q -t ed25519 -N "" -f "$tmp/client"
  ssh-keygen -q -t ed25519 -N "" -f "$tmp/client-rotated"
  AUTO_CODE_AUTHORIZED_KEYS="$(cat "$tmp/client.pub")" auto-code-sshd start
  AUTO_CODE_AUTHORIZED_KEYS="$(cat "$tmp/client.pub")" auto-code-sshd start
  sudo sshd -T | grep -qx "permitrootlogin no"
  sudo sshd -T | grep -qx "passwordauthentication no"
  sudo sshd -T | grep -qx "kbdinteractiveauthentication no"
  sudo sshd -T | grep -qx "authenticationmethods publickey"
  sudo sshd -T | grep -qx "allowusers dev"
  sudo test -s /var/lib/auto-code-env/sshd/ssh_host_ed25519_key
  test "$(sudo stat -c %a /var/lib/auto-code-env/sshd/ssh_host_ed25519_key)" = 600
  ssh-keyscan -p 22 127.0.0.1 > "$tmp/known_hosts" 2>/dev/null
  ssh -p 22 -i "$tmp/client" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$tmp/known_hosts" dev@127.0.0.1 \
    "test \"\$(id -u)\" = 1000 &&
     test \"\$XDG_RUNTIME_DIR\" = /run/user/1000 &&
     test \"\$SSH_AUTH_SOCK\" = /run/user/1000/rbw/ssh-agent-socket &&
     command -v go rbw omni >/dev/null"

  auto-code-sshd stop
  printf %s "$(cat "$tmp/client-rotated.pub")" > "$tmp/authorized_keys"
  AUTO_CODE_AUTHORIZED_KEYS_FILE="$tmp/authorized_keys" auto-code-sshd start
  if ssh -p 22 -i "$tmp/client" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$tmp/known_hosts" dev@127.0.0.1 true >/dev/null 2>&1; then exit 1; fi
  ssh -p 22 -i "$tmp/client-rotated" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$tmp/known_hosts" dev@127.0.0.1 true
' || fail 'public-key SSH server contract or real login failed'

run 'for tool in go node python3 uv pnpm bun claude codex herdr; do command -v "$tool" >/dev/null || exit 1; done' \
  || fail 'full language and development toolchain is incomplete'
run '. /usr/local/share/auto-code-env/versions.env; test "$(codex --version | awk "{print \$2}")" = "$CODEX_VERSION"; test "$(herdr --version | awk "{print \$2}")" = "$HERDR_VERSION"' \
  || fail 'shared agent tools are not pinned'

case "$target" in
  dev-pilot|dev-both)
    run 'for tool in pilot lazygit; do command -v "$tool" >/dev/null || exit 1; done; . /usr/local/share/auto-code-env/versions.env; test "$(lazygit --version | awk -F", " "{for (i=1; i<=NF; i++) if (\$i ~ /^version=/) {sub(/^version=/, \"\", \$i); print \$i; exit}}")" = "$LAZYGIT_VERSION"' \
      || fail 'Pilot overlay is incomplete or unpinned'
    ;;
esac

case "$target" in
  dev-hermes|dev-both)
    run '. /usr/local/share/auto-code-env/versions.env; test "$HERMES_HOME" = /home/dev/.hermes; test "$(git -C /opt/auto-code-env/.hermes/hermes-agent rev-parse HEAD)" = "$HERMES_COMMIT"; test "$(hermes --version 2>/dev/null | grep -Eo "v?[0-9]+(\.[0-9]+){2,3}" | head -1 | sed "s/^v//")" = "$HERMES_VERSION"' \
      || fail 'Hermes overlay is incomplete or unpinned'
    ;;
esac

case "$target" in
  dev-full)
    run '! command -v pilot >/dev/null 2>&1 && ! command -v hermes >/dev/null 2>&1 && test ! -e /usr/local/bin/pilot && test ! -d /opt/pilot && test ! -d /opt/auto-code-env/.hermes' \
      || fail 'plain image contains a persona overlay'
    ;;
  dev-pilot)
    run '! command -v hermes >/dev/null 2>&1 && test ! -d /opt/auto-code-env/.hermes' || fail 'Pilot image contains Hermes'
    ;;
  dev-hermes)
    run '! command -v pilot >/dev/null 2>&1 && test ! -e /usr/local/bin/pilot && test ! -d /opt/pilot' || fail 'Hermes image contains Pilot'
    ;;
esac

run_offline '
  set -a
  . /usr/local/share/auto-code-env/versions.env
  set +a
  test "$(pnpm --version)" = "$PNPM_VERSION"
  test "$(claude --version | awk "{print \$1}")" = "$CLAUDE_CODE_VERSION"
' || fail 'pnpm or Claude Code is not pinned and runnable without network access'

run '
  set -a
  . /usr/local/share/auto-code-env/versions.env
  set +a
  test -n "$OMNI_VERSION"
  test -n "$DOTFILES_COMMIT"
  test "$OMNI_CONFIG" = /opt/dotfiles/dotfiles/omni/.config/omni/settings.json
  test "$(omni --version | sed -nE "s/.*([0-9]+\\.[0-9]+\\.[0-9]+).*/\\1/p")" = "$OMNI_VERSION"
  test "$(git -C /opt/dotfiles rev-parse HEAD)" = "$DOTFILES_COMMIT"
  test -z "$(git -C /opt/dotfiles status --porcelain)"
  test ! -e /opt/omni-build
  test -z "${OMNI_HOSTNAME:-}"
' || fail 'configured Omni or dotfiles version does not match versions.env'

# The entrypoint must strictly initialize a fresh persistent home without
# network access before executing the requested process.
dots_volume="auto-code-env-smoke-dots-$RANDOM-$RANDOM"
nested_project=""
cleanup_nested() {
  [[ -n "$nested_project" ]] || return 0
  local ids
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=$nested_project")"
  [[ -z "$ids" ]] || docker rm -f $ids >/dev/null 2>&1 || true
  ids="$(docker volume ls -q --filter "label=com.docker.compose.project=$nested_project")"
  [[ -z "$ids" ]] || docker volume rm $ids >/dev/null 2>&1 || true
  ids="$(docker network ls -q --filter "label=com.docker.compose.project=$nested_project")"
  [[ -z "$ids" ]] || docker network rm $ids >/dev/null 2>&1 || true
}
cleanup() {
  cleanup_nested
  docker volume rm -f "$dots_volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker volume create "$dots_volume" >/dev/null
docker run --rm --platform "$platform" --user root --mount "source=$dots_volume,target=/home/dev" \
  --entrypoint /bin/bash "$image" -c 'chown dev:dev /home/dev'
docker run --rm --network none --platform "$platform" --user dev --mount "source=$dots_volume,target=/home/dev" \
  --entrypoint /usr/local/bin/auto-code-entrypoint "$image" /bin/bash -c '
    test -s /run/auto-code-env/ready
    test -d "$HOME/dotfiles/.git"
    test -d "$HOME/workspace"
    test -L "$HOME/.zshrc"
    test -L "$HOME/.config/omni/settings.json"
    test "$OMNI_CONFIG" = "$HOME/.config/omni/settings.json"
  ' || fail 'fresh persistent home did not initialize offline'

docker run --rm --platform "$platform" --user dev --mount "source=$dots_volume,target=/home/dev" \
  --entrypoint /bin/bash "$image" -c 'printf "preserve me\n" > "$HOME/workspace/sentinel"; printf "local change\n" > "$HOME/dotfiles/local-change"'

# Concurrent boots share one persistent lock. Both must wait for reconciliation,
# preserve local state, and leave the lock reusable.
for _ in 1 2; do
  docker run --rm --network none --platform "$platform" --user dev --mount "source=$dots_volume,target=/home/dev" \
    --entrypoint /usr/local/bin/auto-code-entrypoint "$image" /bin/true &
done
wait
docker run --rm --platform "$platform" --user dev --mount "source=$dots_volume,target=/home/dev" \
  --entrypoint /bin/bash "$image" -c '
    grep -qx "preserve me" "$HOME/workspace/sentinel" &&
    grep -qx "local change" "$HOME/dotfiles/local-change" &&
    flock -n "$HOME/.local/state/auto-code-env/init.lock" true
  ' || fail 'recreation did not preserve workspace, dotfiles, or initialization lock'

docker run --rm --platform "$platform" --user dev --mount "source=$dots_volume,target=/home/dev" \
  --entrypoint /usr/bin/zsh "$image" -ic '
    test "$OMNI_CONFIG" = "$HOME/.config/omni/settings.json"
    test -L "$HOME/.config/omni/settings.json"
  ' || fail 'interactive shell did not select the synced Omni config'

if [[ "$target" == dev-pilot || "$target" == dev-both ]]; then
  run '
    test -x /usr/bin/gh
    test -x /usr/local/bin/pilot
    pilot version >/dev/null
  ' || fail 'Pilot backend, gh, or version is broken'

  # Exercise the real entrypoint without launching credential-gated Pilot.
  docker run --rm --platform "$platform" --user root --mount "source=$dots_volume,target=/home/dev" \
    --entrypoint /bin/bash "$image" -c '
      printf "%s\\n" "#!/bin/sh" "exit 0" > /usr/local/bin/pilot
      chmod 0755 /usr/local/bin/pilot
      exec /opt/pilot/bin/pilot-entrypoint --version
    ' || fail 'Pilot entrypoint could not initialize its writable-home layout'
  docker run --rm --platform "$platform" --user dev --mount "source=$dots_volume,target=/home/dev" \
    --entrypoint /bin/bash "$image" -c '
      for path in "$HOME/tmp" "$HOME/repos" "$HOME/.pilot/data" "$HOME/.cache" "$HOME/.local/share"; do test -d "$path"; done
    ' || fail 'Pilot writable-home layout is incomplete'

  if [[ "${PILOT_LIVE:-0}" == 1 ]]; then
    docker run --rm --platform "$platform" --user dev --entrypoint /opt/pilot/bin/pilot-entrypoint "$image" \
      || fail 'credential-gated live Pilot execution failed'
  else
    echo "smoke[$target]: live Pilot execution skipped (set PILOT_LIVE=1 with its required credentials)."
  fi
fi

if [[ "${NESTED_DOCKER:-0}" == 1 ]]; then
  docker_socket=${DOCKER_SOCKET:-/var/run/docker.sock}
  docker_socket=${docker_socket#unix://}
  [[ -S "$docker_socket" ]] || fail "nested Docker requested but $docker_socket is unavailable"
  nested_project="auto-code-env-smoke-docker-$RANDOM-$RANDOM"
  docker run --rm --platform "$platform" --user dev \
    --mount "type=bind,source=$docker_socket,target=/var/run/docker.sock" \
    -e COMPOSE_PROJECT_NAME="$nested_project" --entrypoint /bin/bash "$image" -ceu '
      test "$(command -v docker)" = /usr/local/bin/docker
      docker_config=$(mktemp -d)
      DOCKER_CONFIG=$docker_config docker context create smoke-owner --docker host=unix:///var/run/docker.sock >/dev/null
      test -z "$(find "$docker_config" ! -user "$(id -u)" -print -quit)"
      rm -rf "$docker_config"
      cleanup() { docker compose -f /tmp/compose.yaml down --volumes --remove-orphans; }
      trap cleanup EXIT
      cat > /tmp/compose.yaml <<"EOF"
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_PASSWORD: smoke
EOF
      docker info >/dev/null
      docker run --rm hello-world >/dev/null
      docker compose -f /tmp/compose.yaml up -d
      for _ in {1..30}; do
        docker compose -f /tmp/compose.yaml exec -T postgres pg_isready -U postgres >/dev/null && exit 0
        sleep 1
      done
      exit 1
    ' || fail 'nested Docker client, container, or Compose/Postgres check failed'
  nested_project=""
fi

echo "smoke[$target]: ok"
