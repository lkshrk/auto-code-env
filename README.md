# auto-code-env

Linux development images for a complete local toolbox and the smaller Pilot
agent runtime. The images deliberately install the tool groups already owned by
the dotfiles repository; this repository does not duplicate their recipes.

## Images

| Bake target | Intended use |
| --- | --- |
| `dev-full` | General-purpose development environment. |
| `agent-pilot` | Pilot-compatible agent environment. |

Both targets publish multi-architecture manifests for `linux/amd64` and
`linux/arm64`.

## Local use

Build either target with Bake:

```sh
export GITHUB_TOKEN="$(gh auth token)"
export PLATFORM="${PLATFORM:-linux/amd64}"
docker buildx bake --load \
  --set dev-full.platform="$PLATFORM" \
  --set dev-full.secrets=id=GITHUB_TOKEN,env=GITHUB_TOKEN \
  --set dev-full.tags=auto-code-env:dev-full dev-full
docker buildx bake --load \
  --set agent-pilot.platform="$PLATFORM" \
  --set agent-pilot.secrets=id=GITHUB_TOKEN,env=GITHUB_TOKEN \
  --set agent-pilot.tags=auto-code-env:agent-pilot agent-pilot
```

`--load` loads one platform into the local Docker daemon. For a published
multi-architecture image, use `--push` and set
`<target>.platform=linux/amd64,linux/arm64`.

Run either loaded image:

```sh
docker run --rm -it auto-code-env:dev-full
docker run --rm -it --entrypoint zsh auto-code-env:agent-pilot
```

Run the smoke check against an image tag:

```sh
PLATFORM=linux/amd64 NESTED_DOCKER=1 test/smoke.sh dev-full auto-code-env:dev-full
```

On Docker Desktop, set `DOCKER_SOCKET` to the Unix socket reported by
`docker context inspect --format '{{(index .Endpoints "docker").Host}}'`.

## Tooling and dotfiles

The Dockerfile invokes `omni tools install --group … --force` for explicit
groups. Both images share `prereqs`, `core`, `shell`, `dev`, and
`test-tooling`. `dev-full` adds `dev-tooling`, `go`, `python`, `ts`, and
`infra`, then installs Claude Code, Codex, and Herdr individually.
`agent-pilot` adds `go`, `python`, and `ts`, then installs Claude Code and
Lazygit. The group definitions and
tool-version choices live in
[`lkshrk/dotfiles`](https://github.com/lkshrk/dotfiles), so updating a tool
means updating dotfiles then pinning its commit here. Omni group selection is
intentional: image targets do not depend on host detection or synthetic Omni
hosts.

Dotfiles sync runs only from an interactive container startup, once per home
directory. It syncs an explicit universal dot list, not a workstation host
profile. User state
remains under the container user's home directory and should be mounted or
persisted by the caller when needed. Baked tools live under
`/opt/auto-code-env`, so mounting `/home/pilot` never hides the toolchain.

## Pilot contract

`agent-pilot` runs as the shared `pilot` persona (UID/GID 1000), has a writable
home at `/home/pilot`, and keeps persistent runtime state there. Pilot adapters are under
`/opt/pilot/bin`; the `gh` shim delegates to `REAL_GH=/usr/bin/gh`. Consumers
must mount project work at the working directory and provide credentials at
runtime (for example, by a secret mount); credentials are never built into an
image layer. The image supplies the environment Pilot needs, not
project-specific dependencies or source.

## Docker from inside an image

The images contain the Docker CLI, Buildx, and Compose plugins, not a Docker
daemon. For local development, mount the host socket:

```sh
docker_socket=$(docker context inspect --format '{{(index .Endpoints "docker").Host}}')
docker_socket=${docker_socket#unix://}
docker run --rm -it \
  -v "$docker_socket:/var/run/docker.sock" \
  auto-code-env:dev-full docker info
```

The included Dev Container compositions mount `/var/run/docker.sock`. Docker
Desktop users must enable its default socket (or point that host path at the
socket reported above). The image's Docker wrapper uses the existing
passwordless `sudo` only when the mounted Unix socket rejects UID 1000; TCP
and already-accessible sockets run without elevation.

Socket access effectively grants root-equivalent control of the host Docker
daemon; use it only for trusted containers.

Kubernetes has no host Docker socket. Run a privileged DinD sidecar with an
isolated `emptyDir` Docker data directory and set
`DOCKER_HOST=tcp://localhost:2375`; see
[`examples/kubernetes/agent-pilot-dind.yaml`](examples/kubernetes/agent-pilot-dind.yaml).
The sidecar binds its unauthenticated API to the Pod's loopback interface only.

## Image size

Build dependencies use BuildKit cache mounts where possible. The resulting
images retain installed toolchains under `/opt/auto-code-env`, but package,
language, and installer caches are excluded from final layers. Docker is
client-only in the images; DinD storage belongs to the runtime volume.

## Publishing and deployment boundary

Pull requests run Dockerfile/Bake/shell checks and build plus smoke-test both
targets. Pushes to `main` publish `<target>-sha-<commit>` and
`<target>-latest`; version tags publish `<target>-sha-<commit>` and the
matching `<target>-<release>` tag. Publishing happens only after both targets
pass smoke tests on both architectures. The GitHub token is supplied to BuildKit as a secret, never as a
Docker build argument.

[`lkshrk/h-cloud`](https://github.com/lkshrk/h-cloud) owns deployment and image
promotion into the cluster. This repository publishes images only; changing
which image a workload runs is an h-cloud migration.
