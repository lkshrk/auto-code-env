# OpenHands Desktop Worker

Reproducible Ubuntu 26.04 worker for OpenHands Canvas. One source build produces
one multi-architecture OCI image and one WSL artifact per architecture.

```text
source tree + pinned tool definitions
              |
              +-- OCI image: ghcr.io/lkshrk/openhands-worker:<version>
              |      linux/amd64 + linux/arm64
              |
              `-- WSL artifacts:
                     openhands-worker-<version>-amd64.wsl
                     openhands-worker-<version>-arm64.wsl
```

The OCI image is for Docker and Kubernetes. Each `.wsl` file is a
gzip-compressed tar root filesystem, following
[Microsoft's custom distribution format](https://learn.microsoft.com/windows/wsl/build-custom-distro);
it is not an OCI image.

## Runtime contract

```text
OpenHands Canvas/control plane
https://orc.ai.h-cloud.lan
        |
        v
worker.local-domain -> 172.16.20.195:443
        |
        v
nginx TLS -> 127.0.0.1:8000 Agent Canvas public ingress
        |
        v
Claude Code ACP / Codex ACP / future agents
        |
        v
agent:/home/agent/workspaces
```

nginx is only LAN-facing process. It listens on TCP/443 and proxies WebSocket
and HTTPS traffic to `127.0.0.1:8000`; port 8000 is never exposed directly.
`LOCAL_BACKEND_API_KEY` remains mandatory.

All workloads run as unprivileged `agent` (UID/GID 1000), without sudo. Its
persistent authentication/runtime directories are `.openhands`, `.claude`,
and `.codex`; `workspaces` is disposable. Never put personal, production,
Kubernetes-admin, cloud-admin, or private SSH credentials in this image or
those directories.

## Build and release

`worker/docker-bake.hcl` builds these targets:

| Target | Output |
|---|---|
| `image` | one multi-architecture OCI image: amd64 and arm64 |
| `wsl-amd64` | an amd64 WSL tar/rootfs |
| `wsl-arm64` | an arm64 WSL tar/rootfs |

Build a WSL artifact locally:

```sh
worker/build-wsl.sh 1.2.3 amd64 dist
(cd dist && sha256sum -c openhands-worker-1.2.3-amd64.wsl.sha256)
```

Only `openhands-worker-v*` tags release artifacts. Native GitHub runners build
amd64 and arm64 separately; no QEMU emulation is accepted. The release has the
two `.wsl` files, the matching `install.ps1`, `firewall.ps1`, `keepalive.ps1`,
the in-distro `openhands-overlay` tool, and a combined `checksums.txt` covering
all six, and GHCR has immutable
`ghcr.io/lkshrk/openhands-worker:<version>` manifest with both architectures,
SBOM, and provenance.

An arm64 Linux build proves native Linux build compatibility only. It is not a
Windows-on-Arm WSL runtime proof. Publication gate: native amd64 CI and real Windows import
must both pass before release. Windows-on-Arm remains a separate runtime gate.

## Windows import and host overlay

Take the installer from the same release as the image, never from an older
local copy:
`https://github.com/lkshrk/auto-code-env/releases/download/openhands-worker-v<version>/install.ps1`.
Verify its SHA-256 against `checksums.txt` before running it.

Run elevated PowerShell. Select exactly one artifact source plus its mandatory
SHA-256 from release `checksums.txt`:

```powershell
# Local release asset
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -ImagePath C:\Downloads\openhands-worker-1.2.3-amd64.wsl `
  -ImageSha256 <64-hex-sha256>

# Direct HTTPS release asset
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -ImageUri https://github.example/release/openhands-worker-1.2.3-amd64.wsl `
  -ImageSha256 <64-hex-sha256>
```

`ImagePath` must be a regular non-reparse file. `ImageUri` must be absolute
HTTPS. `ImageSha256` is mandatory in both modes. Installer architecture
detection accepts only `amd64` or `arm64` and requires filename suffix
`-amd64.wsl` or `-arm64.wsl` to match Windows architecture.

The installer requires Windows 11, elevated PowerShell, and WSL 2.7+. It
merges `networkingMode=mirrored` and `dnsTunneling=true` into `.wslconfig`,
backing up existing config only when it changes. It imports artifact with
`wsl --install --from-file`, then verifies root access and Ubuntu 26.04.

host mirrored-networking reconciliation runs before distro lookup; it may update
`.wslconfig` and run `wsl --shutdown`. Then, after host mirrored-networking reconciliation,
an existing distro is a no-op: if `openhands-worker` is registered, installer
does not download, import, reprovision, or modify it. It does not migrate an
existing distribution automatically. Upgrade means export state if needed,
choose explicit replacement/import plan, and test it first; rollback means
importing previously verified artifact under explicit safe name. No automatic
WSL state migration exists.

After import, the host overlay is driven by two shipped tools. Values are
host-specific; the tools are not.

Firewall, elevated PowerShell. Take `firewall.ps1` from the same release,
`https://github.com/lkshrk/auto-code-env/releases/download/openhands-worker-v<version>/firewall.ps1`,
verify it against `checksums.txt`, then pass the exact trusted sources.
`-RemoteAddresses` is mandatory and accepts only IPv4 hosts or ranges of /24
or narrower; `Any` is refused. The script sets the WSL Hyper-V default inbound
action to block and allows TCP/443 from those sources only, so port 8000 and
everything else stay unreachable. An existing Hyper-V rule that already
matches is left alone; a differing one is removed and recreated, because
`Set-NetFirewallHyperVRule` is denied on current Windows builds:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\firewall.ps1 -RemoteAddresses 10.0.0.10,10.0.0.11
```

Keepalive, elevated PowerShell. WSL idle-stops a distribution about ten seconds
after the last `wsl.exe` session ends, taking nginx and the backend with it.
`keepalive.ps1` from the same release,
`https://github.com/lkshrk/auto-code-env/releases/download/openhands-worker-v<version>/keepalive.ps1`,
registers a hidden scheduled task for the current user that runs
`wsl.exe -d openhands-worker --user root --exec /bin/sleep infinity` at logon
with no execution time limit and starts it immediately. The host must log the
operator on (or auto-logon) for the worker to come back after a reboot.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\keepalive.ps1
```

Secrets, inside the distribution as root. `openhands-overlay secrets` reads the
Vaultwarden master password once with `systemd-ask-password`, keeps it only in
a root-owned tmpfs file for the duration of one transient `systemd-run` unit
that exposes it to the image's `rbw` pinentry as a credential, fetches the
three items by immutable UUID, and writes them with the required ownership and
modes. It then locks `rbw`, stops its agent, and purges the local vault copy.
Vault items: certificate PEM and private-key PEM in the item notes, API key as
the item password.

```powershell
wsl.exe -d openhands-worker -u root -- openhands-overlay secrets --vault-url https://vault.example --email worker@example --crt-id <uuid> --key-id <uuid> --api-id <uuid>
wsl.exe -d openhands-worker -u root -- openhands-overlay enable
```

`openhands-overlay` ships inside the image and as a release asset,
`https://github.com/lkshrk/auto-code-env/releases/download/openhands-worker-v<version>/openhands-overlay`,
so an installed distro can take a newer tool without re-import: download as
root, compare with `checksums.txt`, then `install -o root -g root -m 0755` to
`/usr/local/sbin/openhands-overlay`.

Agent Canvas connects to a remote backend from the browser, so the worker must
allow the Canvas page origin for CORS. `openhands-overlay origin
https://canvas.example` writes `OH_ALLOW_CORS_ORIGINS_0` (and `_1`, `_2`, ...
for additional origins) into a persistent service drop-in and restarts the
service if it is running. Origins are `https://host[:port]` only.

```powershell
wsl.exe -d openhands-worker -u root -- openhands-overlay origin https://canvas.example
```

GitHub access for the agent uses a dedicated token stored in the same vault.
`openhands-overlay github --pat-id <uuid>` fetches it in the same transient
vault session, writes `/home/agent/.git-credentials` as `agent:agent 0600` in
`https://x-access-token:<token>@github.com` form, and sets
`credential.helper store` for `agent`. Git, `gh`, Claude Code, and Codex use it;
no token reaches the environment or the image. `--vault-url` and `--email` are
only needed if `secrets` has not configured `rbw` yet.

```powershell
wsl.exe -d openhands-worker -u root -- openhands-overlay github --pat-id <uuid>
```

Every image carries `/etc/openhands/release` with `openhands-worker <version>`
(`ci-<sha>` for validation builds, `dev` for untagged local builds), stamped
through the `OPENHANDS_WORKER_VERSION` build argument. `openhands-overlay
status` prints it; the release workflow verifies it inside the `.wsl` artifact.

`openhands-overlay verify` checks files, ownership, modes, that the private
key matches the certificate, and `nginx -t`. `openhands-overlay enable`
refuses to start anything until `verify` passes, then enables nginx and
`agent-canvas.service` and prints the listening sockets. Expected: nginx on
`:443`, backend on `127.0.0.1:8000` only.

Operator-owned facts the tools enforce:

- Windows/Hyper-V firewall: only TCP/443, only explicitly trusted VLAN/source
  ranges. Existing target is `172.16.20.195` on VLAN10; do not create broad
  rule or expose port 8000.
- DNS/domain: `worker.local-domain` must resolve to host address.
- TLS: install existing-local-CA certificate and private key as `/etc/nginx/tls/tls.crt`
  and `/etc/nginx/tls/tls.key`; `tls.crt`: `root:root`, mode `0644`; `tls.key`: `root:root`, mode `0600`. Never commit either.
- Secret: install backend key at `/etc/credstore/local_backend_api_key`,
  `root:root`, mode `0600`. `agent-canvas.service` uses
  `LoadCredential=local_backend_api_key`, so systemd exposes it only through
  `$CREDENTIALS_DIRECTORY/local_backend_api_key`, not environment or unit plaintext.
- rbw/Vaultwarden login, Claude Code login, Codex login, and scoped GitHub
  credentials happen after import as `agent`; use dedicated least-privilege
  credentials only.

Start WSL once after overlay. WSL has systemd enabled, automount disabled,
interop disabled, and default user `agent`. Enable/start `agent-canvas.service`
and nginx only after certificate/key and `local_backend_api_key` are present;
service fails closed when credential is missing or empty. `rbw` is present but
not configured or logged in by image build.

WSL owns its shared kernel and may not expose a loadable module context to a
distribution. The WSL target therefore adds
`ConditionVirtualization=!wsl` to `systemd-modules-load.service`: module loading
is skipped only when systemd detects WSL and remains enabled elsewhere.

WSL init creates each login through `/bin/login -f` and then waits for
`user@<uid>.service`; without `pam_systemd` and a D-Bus system bus that unit
never starts and every command prints `Failed to start the systemd user
session`. The WSL target therefore installs `libpam-systemd` and
`dbus-user-session`. Neither adds a network listener.

## Docker and Kubernetes use

Use OCI tag matching host architecture; Docker/Kubernetes select matching
manifest automatically. Container entrypoint requires either
`LOCAL_BACKEND_API_KEY` or readable `LOCAL_BACKEND_API_KEY_FILE`, plus:

```text
/etc/nginx/tls/tls.crt
/etc/nginx/tls/tls.key
```

Expose only container port 443. Agent Canvas still binds localhost port 8000
inside container/pod; nginx is its only public ingress. Use persistent mounts
instead of baking state into image:

```text
/home/agent/.openhands
/home/agent/.claude
/home/agent/.codex
/home/agent/workspaces
```

Inject TLS and API-key files through platform secret mechanisms. Kubernetes
policy, ingress, NetworkPolicy, and persistent-volume ownership remain
deployment-specific; image does not claim to configure them.

## Tool convergence and updates

`provision.sh` bootstraps exact Node `24.20.0`, uv/uvx `0.12.7`, and Omni `0.10.4`
with vendor checksum verification. Omni desired state is
`worker/omni/settings.json`, copied root-owned to
`/etc/openhands/omni/settings.json`.

Omni owns package installation only:

```text
root group:  openhands-system
agent groups: openhands-agent-no-scripts, openhands-agent-claude
```

Root state/cache live under `/var/lib/openhands/omni` and
`/var/cache/openhands/omni`. Agent state/cache live under
`/home/agent/.local/state/omni` and `/home/agent/.cache/omni`. Provisioner
runs root group as root and npm groups as `agent`, with fixed
`/home/agent/.local` npm prefix. Omni does not own secrets, TLS, systemd
credentials, firewall, DNS, WSL networking, or agent authentication.

Tool updates are source changes: update pin in `omni/settings.json` and any
bootstrap version/checksum in `provision.sh`, run native amd64+arm64 validation,
then release new immutable worker version. Do not run arbitrary `latest` or
mutate released runtime in place.

Current direct npm pins:

- `@openhands/agent-canvas@1.16.0`
- `@agentclientprotocol/claude-agent-acp@0.63.0`
- `@agentclientprotocol/codex-acp@1.1.7`
- `@anthropic-ai/claude-code@2.1.251`
- `@openai/codex@0.151.0`

`worker/patches/patch-agent-canvas-automation.mjs` is temporary workaround for
OpenHands issue #16217. Remove it only when PR #16635 ships in compatible Agent
Canvas release, then validate Canvas automation without patch before removing
it from build.

## Verification and limits

Run repository checks before release:

```sh
bash worker/tests/provision.Tests.sh
bash worker/tests/runtime.Tests.sh
bash worker/tests/image.Tests.sh
pwsh -NoProfile -File worker/tests/install.Tests.ps1
```

Then run ShellCheck, `node --check` for runtime patches, `actionlint`, YAML and
JSON parsing, `git diff --check`, native OCI smoke builds, and both WSL tar
inspections. Successful file/config check is not runtime proof: complete real
Windows import and verify systemd, WSL isolation, TLS reachability,
localhost-only backend, credential-required service start, firewall scope,
Claude/Codex auth, ACP execution, and workspace permissions.

Outbound restrictions are intentionally not implemented. First measure required
GitHub, package-registry, Claude, Codex, OpenHands, LLM-gateway, and development
traffic; mirrored WSL networking makes broad speculative blocking unsafe.
