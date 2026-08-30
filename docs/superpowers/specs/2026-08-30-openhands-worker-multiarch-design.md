# OpenHands Worker Multi-Architecture Design

## Goal

Build one Ubuntu 26.04 worker filesystem definition and publish it in the two
formats required by the supported runtimes:

- one multi-platform OCI image for Docker and Kubernetes;
- one architecture-specific `.wsl` root filesystem for each supported Windows
  architecture.

The supported platforms are exactly `linux/amd64` and `linux/arm64`.

## Artifact model

The build graph has one provisioned filesystem and two thin final targets:

```text
ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b
                              |
                      provisioned-worker
                       /               \
                    oci                 wsl
             Docker/Kubernetes      custom WSL rootfs
```

The OCI release is published as:

```text
ghcr.io/lkshrk/openhands-worker:<version>
```

Its manifest contains `linux/amd64` and `linux/arm64` children. WSL artifacts
are separate files because a WSL rootfs is architecture-specific:

```text
openhands-worker-<version>-amd64.wsl
openhands-worker-<version>-arm64.wsl
checksums.txt
```

Release tags use `openhands-worker-v<version>`. Mutable `latest` tags are not
published.

## Shared filesystem

Both targets contain:

- Ubuntu 26.04;
- unprivileged `agent` user without sudo;
- `/home/agent/.openhands`, `.claude`, `.codex`, and `workspaces` with mode
  `0700` and `agent:agent` ownership;
- pinned Node.js, uv/uvx, Agent Canvas, Claude Code, Codex, and ACP packages;
- pinned Agent Canvas dependencies warmed into the agent uv cache;
- nginx and the root-owned runtime launch assets;
- no private certificate, private key, API key, GitHub credential, Claude
  credential, Codex credential, Vaultwarden credential, or rbw session.

Existing version pins remain authoritative. Agent Canvas `1.16.0` carries
Agent Server `1.44.0` and Automation `1.9.0`; the build must warm those exact
PyPI environments rather than resolving a later release at runtime.

## Architecture mapping

The provisioner maps the target machine architecture once and uses the result
for every downloaded binary:

| `uname -m` | OCI platform | Node archive | uv target | Omni/release suffix |
|---|---|---|---|---|
| `x86_64`, `amd64` | `linux/amd64` | `linux-x64` | `x86_64-unknown-linux-gnu` | `x86_64` / `amd64` |
| `aarch64`, `arm64` | `linux/arm64` | `linux-arm64` | `aarch64-unknown-linux-gnu` | `arm64` |

Every other architecture fails before downloading or modifying the toolchain.
Checksums remain mandatory for every downloaded release artifact.

## OCI runtime

The OCI target runs a root-owned entrypoint because nginx must bind TCP/443.
The entrypoint launches Agent Canvas as `agent`, launches nginx as its normal
root master/unprivileged worker model, forwards termination signals, and exits
when either child exits. It never grants `agent` sudo.

Required runtime inputs:

```text
/etc/nginx/tls/tls.crt
/etc/nginx/tls/tls.key
LOCAL_BACKEND_API_KEY or LOCAL_BACKEND_API_KEY_FILE
```

The file form is preferred for Docker/Kubernetes secrets. The entrypoint reads
the file without printing it and exports the value only to the Agent Canvas
child. Missing or empty credentials and missing TLS files fail before either
service starts.

Agent Canvas runs as:

```text
/home/agent/.local/bin/agent-canvas --public
```

Its unified ingress remains on `127.0.0.1:8000`. nginx is the only service
listening on a non-loopback address and exposes TCP/443. The image declares
only port 443.

## WSL runtime

The WSL target adds:

- `/etc/wsl.conf` with systemd enabled, automount disabled, interoperability
  disabled, Windows PATH append disabled, and default user `agent`;
- `/etc/wsl-distribution.conf` with default distribution name
  `openhands-worker` and default UID 1000;
- separate systemd units for Agent Canvas and nginx.

The Agent Canvas unit runs as `agent` and reads
`local_backend_api_key` through a systemd credential. nginx uses the same TLS
paths as the OCI runtime. Both units are installed but not enabled during image
build: certificate and credential provisioning is a host-specific activation
step.

## Windows bootstrap

Windows continues to own only host integration:

- Windows 11 and WSL prerequisite validation;
- mirrored networking configuration;
- Windows/Hyper-V firewall configuration;
- importing the already-built `.wsl` artifact;
- architecture selection;
- artifact SHA-256 verification;
- certificate and secret activation;
- final end-to-end verification.

Creating a new distribution no longer runs apt/npm/download provisioning on
the Windows host. The installer accepts either a local `.wsl` path or an HTTPS
artifact URI and requires the expected SHA-256 before installation. It never
modifies an unrelated existing distribution.

## CI and release

Pull requests run:

- shell and PowerShell unit tests;
- ShellCheck;
- an amd64 OCI build and image smoke test;
- an arm64 build under BuildKit emulation;
- static checks that no secret or TLS private-key material entered the build
  context or layers.

Release tags build both architectures, publish the OCI manifest by immutable
version tag, export each WSL filesystem, create `checksums.txt`, and attach the
WSL artifacts to the GitHub release. OCI builds publish BuildKit provenance and
SBOM attestations.

Architecture-specific smoke tests verify Node, npm, uv, uvx, Agent Canvas,
Claude Code, Codex, both ACP bridges, `agent` ownership, nginx configuration,
and absence of embedded TLS/private credential files.

## Persistence and updates

Persistent state remains outside replacement artifacts:

- `~/.openhands`, `~/.claude`, and `~/.codex` are authentication/runtime state;
- `~/workspaces` is disposable workspace state;
- Docker/Kubernetes mount these paths explicitly;
- WSL replacement must back up and restore persistent state before an image
  migration is introduced.

This design implements clean installs. Automated in-place WSL image replacement
is out of scope until a tested state migration exists. Tool updates produce a
new versioned artifact; services do not run package-manager reconciliation on
boot.

## Omni boundary

The artifact interface does not depend on which converger populates the shared
filesystem. The current verified provisioner remains the build implementation
until an Omni release with correct exact-pin installed-state handling exists.
That later change replaces provisioner internals, not the OCI/WSL artifact
contract, runtime launchers, or Windows import flow. Personal dotfiles are never
an image input.
