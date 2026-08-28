#!/usr/bin/env bats

setup() {
  export FAKE_LOG="$BATS_TEST_TMPDIR/log"; : > "$FAKE_LOG"
  export PATH="$BATS_TEST_DIRNAME/helpers/fake-bin:$PATH"
  export DEVBOX="$BATS_TEST_DIRNAME/../scripts/devbox"
  export DEVBOX_ENV_FILE="$BATS_TEST_TMPDIR/env"; : > "$DEVBOX_ENV_FILE"; chmod 600 "$DEVBOX_ENV_FILE"
  export SSH_AUTH_SOCK="$BATS_TEST_TMPDIR/agent.sock"; : > "$SSH_AUTH_SOCK"
  unset DEVBOX_REGISTRY DEVBOX_RUNTIME
}

@test "up runs detached with named home volume and default full image" {
  run "$DEVBOX" up api
  [ "$status" -eq 0 ]
  line=$(grep '^docker run' "$FAKE_LOG")
  [[ "$line" == *"-d"* ]]
  [[ "$line" == *"--name devbox-api"* ]]
  [[ "$line" == *"-v devbox-api-home:/home/dev"* ]]
  [[ "$line" == *"--env-file $DEVBOX_ENV_FILE"* ]]
  [[ "$line" == *"ghcr.io/lkshrk/devbox/full:latest"* ]]
}

@test "up honours --image and extra -v" {
  run "$DEVBOX" up api --image go -v /tmp/x:/work
  [ "$status" -eq 0 ]
  line=$(grep '^docker run' "$FAKE_LOG")
  [[ "$line" == *"ghcr.io/lkshrk/devbox/go:latest"* ]]
  [[ "$line" == *"-v /tmp/x:/work"* ]]
}

@test "up passes -w through" {
  run "$DEVBOX" up api -w /work
  [ "$status" -eq 0 ]
  line=$(grep '^docker run' "$FAKE_LOG")
  [[ "$line" == *"-w /work"* ]]
}

@test "up refuses a world-readable env file" {
  chmod 644 "$DEVBOX_ENV_FILE"
  run "$DEVBOX" up api
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode 600"* ]]
}

@test "up refuses a missing env file" {
  rm "$DEVBOX_ENV_FILE"
  run "$DEVBOX" up api
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing"* ]]
}

@test "sh execs zsh login shell" {
  run "$DEVBOX" sh api
  [ "$status" -eq 0 ]
  grep -q '^docker exec -it devbox-api zsh -l$' "$FAKE_LOG"
}

@test "run is ephemeral and passes the command" {
  run "$DEVBOX" run --image ts -- claude -p hi
  [ "$status" -eq 0 ]
  line=$(grep '^docker run' "$FAKE_LOG")
  [[ "$line" == *"--rm"* ]]
  [[ "$line" == *"devbox/ts:latest claude -p hi"* ]]
  [[ "$line" != *"-home:/home/dev"* ]]
}

@test "run without a command is a usage error" {
  run "$DEVBOX" run --image ts
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "stop stops the container" {
  run "$DEVBOX" stop api
  [ "$status" -eq 0 ]
  grep -q '^docker stop devbox-api$' "$FAKE_LOG"
}

@test "ls lists devbox containers" {
  run "$DEVBOX" ls
  [ "$status" -eq 0 ]
  grep -q '^docker ps -a --filter name=\^devbox- ' "$FAKE_LOG"
}

@test "rm deletes container and volume after confirmation" {
  run bash -c "echo y | '$DEVBOX' rm api"
  [ "$status" -eq 0 ]
  grep -q '^docker rm -f devbox-api$' "$FAKE_LOG"
  grep -q '^docker volume rm devbox-api-home$' "$FAKE_LOG"
}

@test "rm without confirmation deletes nothing" {
  run bash -c "echo n | '$DEVBOX' rm api"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_LOG" ]
}

@test "DEVBOX_RUNTIME=podman uses podman" {
  DEVBOX_RUNTIME=podman run "$DEVBOX" stop api
  [ "$status" -eq 0 ]
  grep -q '^podman stop devbox-api$' "$FAKE_LOG"
  ! grep -q '^docker ' "$FAKE_LOG"
}

@test "DEVBOX_REGISTRY overrides the image registry" {
  DEVBOX_REGISTRY=example.com/db run "$DEVBOX" up api
  [ "$status" -eq 0 ]
  grep -q 'example.com/db/full:latest' "$FAKE_LOG"
}

@test "a flag missing its value is a usage error" {
  run "$DEVBOX" up api --image
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "up without a name is a usage error" {
  run "$DEVBOX" up
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "an unknown subcommand is a usage error" {
  run "$DEVBOX" bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}
