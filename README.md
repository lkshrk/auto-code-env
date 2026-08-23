# auto-code-env

Multi-architecture Linux development images. Every variant includes the same
language stack: Go, Python, Node/TypeScript, pnpm, Bun, uv, Claude Code, Codex,
Docker CLI/Buildx/Compose, `rbw`, and the common Omni tooling.

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
docker buildx bake --load \
  --set dev-full.secrets=id=GITHUB_TOKEN,env=GITHUB_TOKEN \
  --set dev-full.tags=auto-code-env:dev-full dev-full
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

## SSH and rbw

Every variant includes `rbw`, `rbw-agent`, `pinentry-curses`, and hardened SSH
client defaults: hashed known hosts, `accept-new` host-key policy, keepalives,
and agent forwarding disabled to downstream hosts. Private keys and rbw vault
credentials are never stored in an image layer.

On Docker Desktop, expose the key already loaded in the host SSH agent:

```sh
docker run --rm -it \
  --mount type=bind,src=/run/host-services/ssh-auth.sock,target=/run/host-services/ssh-auth.sock \
  -e SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock \
  ghcr.io/lkshrk/auto-code-env:dev-full-latest
```

On Linux, bind-mount `$SSH_AUTH_SOCK` instead; its socket must be accessible to
container UID 1000. This forwarded-agent mode expects the key to already be
loaded on the host.

For keys stored as Bitwarden SSH Key items, use rbw's native SSH agent. The
image already points `SSH_AUTH_SOCK` at its dedicated socket:

```sh
rbw unlock
ssh-add -L
```

Save only each public key locally so OpenSSH can select the matching identity
from rbw's agent:

```sh
install -d -m 0700 ~/.ssh/rbw
rbw get --field=public_key '<ssh-key-item>' > ~/.ssh/rbw/dev-host.pub
```

```sshconfig
Host dev-host
    HostName <workspace-address>
    Port 2222
    User dev
    IdentityAgent SSH_AUTH_SOCK
    IdentityFile ~/.ssh/rbw/dev-host.pub
    IdentitiesOnly yes
```

The public-key filename is arbitrary; use stable names based on the key or
host. No private key is written to disk.

For unattended Pilot or Hermes, mount a dedicated automation key at
`/run/secrets/ssh_key` and run `ssh-secret-run <command ...>`. It starts a
container-local agent for only that command. Do not use a personal key or rbw
master password for unattended workloads. The image starts neither agent
automatically; `rbw unlock` starts rbw's agent when needed.

## SSH server

Every variant includes a public-key-only SSH server for the `dev` user.
Host keys are generated at runtime, not baked into the image. Persist
`/var/lib/auto-code-env/sshd` to keep the server identity stable across
container replacement.

The canonical [`workspace.compose.yaml`](workspace.compose.yaml) runs sshd in the foreground,
persists `/home/dev` and the SSH host identity, mounts the Docker socket, and
reports healthy only after strict workspace initialization succeeds.

Set an immutable image reference, the VLAN bind address, and a public-key file
outside this repository:

```powershell
$env:AUTO_CODE_IMAGE = "ghcr.io/lkshrk/auto-code-env:dev-both-sha-<commit>"
$env:AUTO_CODE_SSH_BIND = "172.16.20.195"
$env:AUTO_CODE_AUTHORIZED_KEYS_FILE = "$env:USERPROFILE\.ssh\dev-host.pub"
docker compose -f workspace.compose.yaml up -d --wait
ssh -p 2222 dev@172.16.20.195
```

Allow TCP port 2222 from the VLAN subnet in Windows Firewall. The public key
is mounted as a Compose secret and is never stored in this repository.

Compose-managed keys are replaced on recreation, so removed keys are revoked.
Manual keys can be maintained separately:

```sh
auto-code-sshd authorize < ~/.ssh/id_ed25519.pub
```

Back up or restore the persistent home and SSH identity while the workspace is
stopped:

```sh
scripts/workspace-state.sh backup /secure/path/workspace.tar.gz
scripts/workspace-state.sh restore /secure/path/workspace.tar.gz
```

The archive contains credentials and must be stored on encrypted media.

Root login, passwords, keyboard-interactive authentication, X11 forwarding,
agent forwarding, and tunnels are disabled. TCP forwarding remains enabled for
normal remote-development port forwarding.

## Runtime contracts

All variants use the unprivileged `dev` user (UID/GID 1000), default to an
interactive shell, and have writable home `/home/dev`. `dev-pilot` and
`dev-both` provide the Pilot binary and `/opt/pilot/bin/pilot-entrypoint`.
`dev-hermes` and `dev-both` provide Hermes. Service deployments explicitly
run `/opt/pilot/bin/pilot-entrypoint` or `hermes gateway run`; the combined
image does not hide a process supervisor.
Projects live under the persistent `/home/dev/workspace` directory.

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
