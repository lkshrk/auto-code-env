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
run() { docker run --rm --platform "$platform" --user pilot --entrypoint /bin/bash "$image" -c "$1"; }
run_offline() { docker run --rm --network none --platform "$platform" --user pilot --entrypoint /bin/bash "$image" -c "$1"; }

docker image inspect "$image" >/dev/null || fail "image not found: $image"

run 'test "$(id -u)" = 1000 && test "$(id -g)" = 1000 && test "$USER" = pilot && test "$HOME" = /home/pilot' \
  || fail 'pilot identity is not uid/gid 1000 with /home/pilot'

run 'for tool in bash git curl jq make omni ssh ssh-add rbw rbw-agent rbw-ssh-add pinentry-curses; do command -v "$tool" >/dev/null || exit 1; done' \
  || fail 'core tools are missing'

run '
  . /usr/local/share/auto-code-env/versions.env
  test "$(rbw --version | awk "{print \$2}")" = "$RBW_VERSION"
  ssh -G github.com 2>/dev/null | grep -qx "forwardagent no"
  ssh -G github.com 2>/dev/null | grep -qx "hashknownhosts yes"
  ssh -G github.com 2>/dev/null | grep -qx "stricthostkeychecking accept-new"
  ! grep -R -l -- "BEGIN OPENSSH PRIVATE KEY" /home/pilot /opt/dotfiles >/dev/null 2>&1
  test "$(rbw-ssh-add fake 2>&1 || true)" = "rbw-ssh-add: SSH_AUTH_SOCK is not available"
' || fail 'rbw or hardened SSH client contract is broken'

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
    run '. /usr/local/share/auto-code-env/versions.env; test "$HERMES_HOME" = /home/pilot/.hermes; test "$(git -C /opt/auto-code-env/.hermes/hermes-agent rev-parse HEAD)" = "$HERMES_COMMIT"; test "$(hermes --version 2>/dev/null | grep -Eo "v?[0-9]+(\.[0-9]+){2,3}" | head -1 | sed "s/^v//")" = "$HERMES_VERSION"' \
      || fail 'Hermes overlay is incomplete or unpinned'
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
  test "$(omni --version | sed -nE "s/.*([0-9]+\\.[0-9]+\\.[0-9]+).*/\\1/p")" = "$OMNI_VERSION"
  test "$(git -C /opt/dotfiles rev-parse HEAD)" = "$DOTFILES_COMMIT"
' || fail 'configured Omni or dotfiles version does not match versions.env'

# The entrypoint invokes this wrapper. Without a TTY it must be a no-op: image
# startup must never mutate a mounted home directory or attempt a dots sync.
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
docker run --rm --platform "$platform" --user root --mount "source=$dots_volume,target=/home/pilot" \
  --entrypoint /bin/bash "$image" -c 'chown pilot:pilot /home/pilot'
docker run --rm --platform "$platform" --user pilot --mount "source=$dots_volume,target=/home/pilot" \
  --entrypoint /bin/bash "$image" -c 'auto-code-env-dots; test ! -e "$HOME/.local/state/auto-code-env/dots.attempted"' \
  || fail 'noninteractive dots attempted a sync'

# Two TTY-backed attempts share a home. Exactly one may acquire the atomic lock;
# both must leave a completed state and no stale lock.
for _ in 1 2; do
  docker run --rm --platform "$platform" -t --user pilot --mount "source=$dots_volume,target=/home/pilot" \
    --entrypoint /bin/bash "$image" -c auto-code-env-dots &
done
wait
docker run --rm --platform "$platform" --user pilot --mount "source=$dots_volume,target=/home/pilot" \
  --entrypoint /bin/bash "$image" -c '
    test -f "$HOME/.local/state/auto-code-env/dots.attempted" &&
    test -f "$HOME/.local/state/auto-code-env/dots.succeeded" &&
    test -L "$HOME/.zshrc" &&
    flock -n "$HOME/.local/state/auto-code-env/dots.lock" true
  ' || fail 'concurrent interactive dots did not leave a clean completed state'

docker run --rm --platform "$platform" --user pilot --mount "source=$dots_volume,target=/home/pilot" \
  --entrypoint /usr/bin/zsh "$image" -ic '
    test "$OMNI_CONFIG" = "$HOME/.config/omni/settings.json"
    test -L "$HOME/.config/omni/settings.json"
  ' || fail 'interactive shell did not select the synced Omni config'

docker run --rm --platform "$platform" --user pilot \
  --mount "source=$dots_volume,target=/home/pilot" --entrypoint /bin/bash "$image" -c '
    lock="$HOME/.local/state/auto-code-env/dots.lock"
    bash -c '\''exec 9>"$1"; flock 9; while :; do :; done'\'' _ "$lock" & holder=$!
    sleep 1
    if flock -n "$lock" true; then kill -9 "$holder"; exit 1; fi
    kill -9 "$holder"
    wait "$holder" 2>/dev/null || true
    flock -n "$lock" true
  ' || fail 'dotfiles lock was not released after its holder died'

if [[ "$target" == dev-pilot || "$target" == dev-both ]]; then
  run '
    test "$(command -v gh)" = /opt/pilot/bin/gh
    test "$REAL_GH" = /usr/bin/gh
    test -x /usr/bin/gh
    test -x /usr/local/bin/pilot
    pilot version >/dev/null
  ' || fail 'Pilot PATH, real gh, backend, or version is broken'

  # Exercise the real entrypoint without launching credential-gated Pilot.
  docker run --rm --platform "$platform" --user root --mount "source=$dots_volume,target=/home/pilot" \
    --entrypoint /bin/bash "$image" -c '
      printf "%s\\n" "#!/bin/sh" "exit 0" > /usr/local/bin/pilot
      chmod 0755 /usr/local/bin/pilot
      exec /opt/pilot/bin/pilot-entrypoint --version
    ' || fail 'Pilot entrypoint could not initialize its writable-home layout'
  docker run --rm --platform "$platform" --user pilot --mount "source=$dots_volume,target=/home/pilot" \
    --entrypoint /bin/bash "$image" -c '
      for path in "$HOME/tmp" "$HOME/repos" "$HOME/.pilot/data" "$HOME/.cache" "$HOME/.local/share"; do test -d "$path"; done
    ' || fail 'Pilot writable-home layout is incomplete'

  if [[ "${PILOT_LIVE:-0}" == 1 ]]; then
    docker run --rm --platform "$platform" --user pilot --entrypoint /opt/pilot/bin/pilot-entrypoint "$image" \
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
  docker run --rm --platform "$platform" --user pilot \
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
