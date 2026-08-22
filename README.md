# auto-code-env

Multi-architecture Linux development images. Every variant includes the same
language stack: Go, Python, Node/TypeScript, pnpm, Bun, uv, Claude Code, Codex,
Docker CLI/Buildx/Compose, and the common Omni tooling.

| Bake target | Adds |
| --- | --- |
| `dev-full` | General development tools. |
| `dev-pilot` | Pilot runtime and adapters. |
| `dev-hermes` | Hermes runtime and adapters. |
| `dev-both` | Pilot and Hermes runtimes together. |

All four targets publish for `linux/amd64` and `linux/arm64`.

## Local use

Build and load one architecture-native image, then smoke it:

```sh
export GITHUB_TOKEN="$(gh auth token)"
docker buildx bake --load --set dev-full.tags=auto-code-env:dev-full dev-full
test/smoke.sh dev-full auto-code-env:dev-full
docker run --rm -it auto-code-env:dev-full
```

Build a non-native platform with a Buildx builder that supports it; use the
same `--set <target>.platform=linux/<arch>` override as CI.

## Tooling and dotfiles

The Dockerfile uses explicit `omni tools install --group … --force` commands,
not host-selected Omni profiles. Dotfiles and exact tool recipes live in
[`lkshrk/dotfiles`](https://github.com/lkshrk/dotfiles); this repository pins
the commit used during the image build.

Dotfiles sync happens only for an interactive startup and only once per home
directory. Mount or persist the user's home when that state should survive a
container replacement. Credentials are supplied at runtime, never baked into
an image layer; GitHub credentials reach build steps only through BuildKit's
`GITHUB_TOKEN` secret mount.

## Runtime contracts

All variants use the unprivileged `pilot` user (UID/GID 1000), default to an
interactive shell, and have writable home `/home/pilot`. `dev-pilot` and
`dev-both` provide Pilot adapters under
`/opt/pilot/bin`, with the `gh` shim delegating to `REAL_GH=/usr/bin/gh`.
`dev-hermes` and `dev-both` provide Hermes. Service deployments explicitly
run `/opt/pilot/bin/pilot-entrypoint` or `hermes gateway run`; the combined
image does not hide a process supervisor.
Project source and project-specific dependencies remain caller-owned mounts.

## Dev Containers

Minimal examples live under [`compositions/`](compositions). Pick the variant
that supplies the runtime your project needs; Docker socket mounts and other
host integrations are intentionally caller-specific.

## Publishing and deployment

Pull requests run two native architecture jobs (`amd64`, `arm64`), each
checking the Dockerfile/Bake/shell files and building plus smoking all four
variants. Releases first push unique run-qualified, architecture-specific
candidates. Only after every candidate smoke test passes are candidates
promoted to multi-architecture `<target>-sha-<commit>` and `<target>-latest`
manifests on `main`; tag events publish only `<target>-<release>` so the
commit tag has one owner.

[`lkshrk/h-cloud`](https://github.com/lkshrk/h-cloud) owns deployments and any
workload image migration. This repository publishes images only.
