# OpenHands Desktop Worker

Reproducible Windows 11/WSL2 worker for the OpenHands control plane at
`https://orc.ai.h-cloud.lan`.

## Architecture

```text
OpenHands Canvas/control plane
https://orc.ai.h-cloud.lan
        |
        v
worker.local-domain -> 172.16.20.195:443
        |
        v
Windows / Hyper-V firewall
trusted source ranges only
        |
        v
nginx TLS
local-CA certificate
        |
        v
OpenHands unified backend ingress
127.0.0.1:8000
        |
        v
Agent Server
        |-- Claude Code ACP
        |-- Codex ACP
        `-- future agents
                |
                v
        unprivileged agent
                |
                v
        /home/agent/workspaces
```

nginx is the only LAN-facing service. The OpenHands unified backend binds only
to localhost. The selected Agent Canvas `1.16.0` contract requires
`LOCAL_BACKEND_API_KEY` in addition to TLS and firewall filtering. Any future
authentication-variable change requires a source-backed, explicit migration.

The authoritative current self-host path is the OpenHands Agent Canvas public
launcher. It starts the unified ingress on `127.0.0.1:8000` and manages its
internal Agent Server, automation backend, and static Canvas components. Do not
mix this contract with standalone Agent Server examples, which use different
ports and authentication variables.

## Goals

- Reproducible, source-controlled installation.
- Dedicated Ubuntu 26.04 LTS WSL2 distribution named `openhands-worker`.
- Persistent OpenHands backend for Claude Code and Codex ACP workers.
- Subscription authentication for Claude Code and Codex during the PoC.
- Agent state and workspaces isolated from normal Windows/WSL development.
- No credentials, private keys, or machine-specific secrets in Git.
- Replaceable runtime with incremental, executable verification.

## Non-goals

This runtime does not own the OpenHands control-plane deployment, orchestration
policy, backlog integration, cross-project memory, Kubernetes workers, or
production credentials. It does not add AI-specific files to application
repositories.

## Windows bootstrap

`install.ps1` must:

- require Windows 11 and administrator privileges where host changes need them;
- inspect installed WSL version, status, distributions, and configuration first;
- discover the exact Ubuntu 26.04 identifier with `wsl --list --online`;
- stop if Ubuntu 26.04 is unavailable rather than guess an identifier;
- create only the dedicated `openhands-worker` distribution using commands
  supported by the installed WSL version;
- never modify or destroy unrelated distributions;
- enable mirrored networking only when needed;
- merge `[wsl2] networkingMode=mirrored` into `.wslconfig` without replacing
  unrelated settings;
- back up `.wslconfig` before changing it;
- copy provisioning assets into the Linux filesystem before disabling Windows
  filesystem integration;
- add only the required inbound Hyper-V firewall rule for TCP/443;
- restrict that rule to explicitly approved source ranges;
- apply global WSL shutdown/restart only when required by a covered change.

`install.ps1` always uses the exact `Ubuntu-26.04` distribution identifier.
After Stage 1, it checks `wsl --list --quiet` first: an existing
`openhands-worker` is a no-op. Only when the target is absent does it read the
target machine's `wsl --help` and use named installation when an exact `--name`
option is advertised. A new target is created with
`wsl --install --distribution Ubuntu-26.04 --name openhands-worker --no-launch`.
The help output itself must advertise `--name`; quiet-list, install, and
post-install verification failures stop the installer. This stage does not
import a distribution, select an install location, or use a fallback naming
flow.

Stage 3 starts only `openhands-worker` noninteractively as `root`, verifies
`id -u` is `0` and `/etc/os-release` identifies Ubuntu `26.04`, then terminates
only that distribution on every verification path. It does not provision Linux
users, files, packages, configuration, or firewall rules.

Stage 4 copies `provision.sh` and `wsl.conf` as exact base64-encoded bytes into
the root-owned `/root/openhands-bootstrap` directory. The Windows installer
rejects missing, non-file, and reparse-point sources; verifies each transferred
SHA-256 before root executes the provisioner; and never relies on `/mnt` or
Windows interop after isolation is enabled. Each asset is split into ordered
base64 chunks of at most 8192 characters, always on a four-character boundary,
and sent through fixed-argument WSL calls. Those calls carry only the existing
single-line decoder plus base64 shell-program and data tokens, never multiline
shell programs or a whole large asset.

Transfer initialization uses fixed per-asset encoded and decoded staging files
beside the destination. It removes stale staging only when every collision is a
root-owned regular file with the expected mode; symlink, type, ownership, and
mode collisions fail untouched. Finalization decodes into the sibling temporary
file, verifies the exact SHA-256, applies root ownership and the destination
mode, then atomically renames it. Init, chunk, and finalize failures clean safe
staging before retry. The installer is intentionally serial: one installer
instance is the concurrency ceiling; add a remote `flock` only if concurrent
installers become a real requirement.

Stage 4 restarts only `openhands-worker`, verifies the default `agent`, systemd
PID 1, that the Windows drive is not mounted at `/mnt/c` (accepting only
mountpoint status 32 when that directory exists), empty `WSL_INTEROP`, absent
WSLInterop binfmt registration, and the four private agent directories, then
stops only that worker. Reruns reuse only safe root-owned bootstrap files.

The provisioner is root-only and refuses any `WSL_DISTRO_NAME` other than
`openhands-worker`. It idempotently creates the unprivileged `agent` user and
its private runtime directories, then installs `/etc/wsl.conf`.

Stage 5A supports x86_64 only. It installs exactly Node.js `24.20.0` under
`/opt/openhands/node-v24.20.0-linux-x64` and `uv`/`uvx` `0.12.7` under
`/usr/local/bin`. Downloads use HTTPS and are checked against Node's official
`SHASUMS256.txt` and the published uv asset checksum before extraction. Both
archives are fully staged and validated before either tool is committed. The
provisioner replaces inherited `PATH` with system-only directories before its
first command and uses absolute trusted commands for validation and commits.
Downloads, archive inspection, integrity digest generation, apt, and staged tool
validation run with clean allowlisted environments; curl disables user config,
requires HTTPS with TLS 1.2 or newer, and uses the system CA bundle explicitly.

The Node tree carries a root-owned `v2 sha256` marker containing a canonical
whole-tree digest. A clean, pipefail-protected GNU tar stream includes sorted
paths, directory and file modes, numeric ownership, symlink targets, and file
content while normalizing timestamps and excluding only the root marker.
Reruns recompute the installed digest against the separately staged release
without executing the installed tree. Any non-v2 marker is never trusted and
is replaced atomically only after that digest comparison succeeds; mismatched
trees retain their original marker. Replacement staging stays outside the
hashed Node tree. `/usr/local/bin/node` is a fixed symlink; the root-owned `npm`
and `npx` wrappers invoke the versioned Node binary and absolute CLI files,
independent of `PATH`. Missing entry points are repaired with registered
sibling temporary files and atomic renames; failures clean all registered
temporary paths. Release archives containing the reserved marker name are
rejected. Existing mismatches, unsafe ancestors, writable trusted directories,
and foreign files fail closed without replacement. The only added apt packages
are `ca-certificates`, `curl`, and `xz-utils`.

Stage 5B installs the pinned agent command-line stack as `agent`, never as
root. Its npm prefix is `/home/agent/.local`; its cache is private and
agent-owned. Its user config is `/dev/null`; its distinct global config is the
empty root-owned `/etc/openhands/npmrc`. npm runs with a clean environment, the
verified `/usr/local/bin/node` wrapper for lifecycle scripts, the pinned Node
binary and bundled npm CLI, explicit prefix/cache paths, and audit,
funding, and update notifications disabled. The provisioner fails on unsafe or
foreign-owned npm root paths, verifies each direct package's `package.json` name and
exact version using the pinned Node binary, confines every expected executable
symlink to its owning package, and only then runs `claude --version` and
`codex --version`. Canvas and ACP executables are validated without starting
services. `.claude` and `.codex` are never replaced or populated with secrets.

Canvas, both ACP bridges, and Codex install with `--ignore-scripts`. Claude
Code installs separately with npm 11's `--strict-allow-scripts` and only
`@anthropic-ai/claude-code` allowed, so transitive lifecycle scripts cannot
float into the install. Exact global `npm ls --depth=0 --json` state and the
complete global-bin set are verified on every run.

The provisioner intentionally does not recursively validate npm's transitive
package or cache trees: they are agent-owned mutable state, not source-locked
artifacts. The direct-package and executable contract above is the durable
validation boundary. Before and after npm runs, it checks only the fixed
prefix/bin/node_modules ancestor and scope directories for real agent-owned,
non-writable paths; canonical package and executable targets must remain
inside that direct boundary.

The direct global package set is exactly:

- `@openhands/agent-canvas@1.16.0`
- `@agentclientprotocol/claude-agent-acp@0.63.0`
- `@agentclientprotocol/codex-acp@1.1.7`
- `@anthropic-ai/claude-code@2.1.251`
- `@openai/codex@0.151.0`

These five direct packages are the pinning and validation ceiling. Their npm
transitive dependencies remain package-manager-managed; do not add deep pins
or manually alter the agent prefix without an explicit compatibility migration.
`@agentclientprotocol/codex-acp@1.1.7` is intentionally retained even though
the registry has moved on: the current OpenHands SDK compatibility set pins
that exact bridge version.
This stage still installs no services, nginx configuration, firewall rules, or
secrets.

Stage 6A installs Ubuntu's exact `rbw=1.13.2-7` package. Before running its
binary, the provisioner verifies the installed package status/version, the
package ownership of `/usr/bin/rbw`, and its root-owned executable mode. It
also atomically installs the root-owned `/usr/local/libexec/openhands-rbw-pinentry`.
That Python-stdlib Assuan helper serves credential bytes from
`$CREDENTIALS_DIRECTORY/rbw_master` only for the exact `Master Password` prompt,
percent-encoding every byte; missing credentials and every other prompt or
command fail closed. Credential bytes are not trimmed: Stage 6B must create
`rbw_master` without a trailing newline. This step neither configures or logs
into rbw nor creates a service or writes a secret.

## WSL configuration

Target:

```text
distribution: openhands-worker
base: Ubuntu 26.04 LTS
user: agent
init: systemd
```

Intended `/etc/wsl.conf`:

```ini
[boot]
systemd=true

[automount]
enabled=false

[interop]
enabled=false
appendWindowsPath=false

[user]
default=agent
```

Provisioning assets must be copied into the WSL filesystem before this file is
activated. Normal runtime operation must not depend on `/mnt/c`, Windows
executables, the Windows user's home directory, or Windows credentials.

## Linux user and filesystem

All OpenHands and ACP workloads run as unprivileged user `agent`. Provisioning,
nginx, certificate files, and system configuration remain root-owned. Do not
grant `agent` sudo or Linux capabilities in this architecture. Any exception is
an out-of-baseline architecture migration requiring a demonstrated need,
separate security review, and explicit approval.

```text
/home/agent/
|-- .openhands/   persistent runtime state
|-- .claude/      persistent Claude authentication state
|-- .codex/       persistent Codex authentication state
`-- workspaces/   disposable/recreatable repositories and worktrees
```

Do not expose personal SSH/GitHub credentials, Kubernetes administrator
credentials, cloud administrator credentials, production credentials, or
production database credentials.

## OpenHands installation contract

Current upstream contract, verified 2026-08-29 at OpenHands commit
`f26d734a848297d8dcf460b0bb739174e76511f0`:

- OpenHands self-hosting documentation names Node.js 22.x and `uv` as
  prerequisites. The pinned npm packages allow Node.js `>=22.12`; this project
  selects current Node.js 24 LTS `24.20.0`.
- Required launcher semantics are
  `npx @openhands/agent-canvas@1.16.0 --public`; public mode provides unified
  ingress on `127.0.0.1:8000` and must not be omitted.
- Public mode requires `LOCAL_BACKEND_API_KEY` and clients use
  `X-Session-API-Key`. The UI must prompt for the key rather than embed it.
- The Canvas launcher manages internal Python Agent Server and automation
  components; do not assume all components belong in one Python virtualenv.
- That commit's compatibility set identifies Agent Server `1.44.1`, Agent
  Canvas `1.16.0`, and automation `1.9.1`.

Pin Agent Canvas and ACP bridge packages with their native package mechanisms.
Record and verify launcher-managed Agent Server and automation versions; do not
override them independently unless upstream exposes and documents a compatible
override. The repository must document selected pins and the intentional update
command. Never use an unversioned arbitrary-latest install in the persistent
service.

Primary sources:

- [OpenHands self-hosting](https://github.com/OpenHands/OpenHands/blob/f26d734a848297d8dcf460b0bb739174e76511f0/docs/SELF_HOSTING.md)
- [OpenHands component defaults](https://github.com/OpenHands/OpenHands/blob/f26d734a848297d8dcf460b0bb739174e76511f0/config/defaults.json)
- [OpenHands ACP agents](https://github.com/OpenHands/docs/blob/5a75b32c7f1e93811e8ccf440ad577307cc35bd6/openhands/usage/agent-canvas/acp-agents.mdx)

## ACP workers and authentication

Initial workers:

- Claude Code through `@agentclientprotocol/claude-agent-acp@0.63.0` and
  `@anthropic-ai/claude-code@2.1.251`;
- Codex through `@agentclientprotocol/codex-acp@1.1.7` and
  `@openai/codex@0.151.0`.

Agent Canvas is installed as `@openhands/agent-canvas@1.16.0`. Provisioning
verifies all direct pins and their executable links before CLI smoke checks;
service launch remains a later stage.

PoC authentication uses existing subscriptions:

- Claude Code persists login state under `~/.claude/`;
- Codex persists login state under `~/.codex/`.

Do not automatically replace subscription authentication with PAYG provider API
keys. OpenHands-native agents may later use the existing LLM gateway; keep that
evaluation separate from native Claude Code/Codex ACP workers.

The bundled editor is served under `/vscode` on the same browser origin as
Canvas. Upstream warns that editor extensions or compromised same-origin assets
can read backend session keys from Canvas local storage. Until upstream provides
a verified isolation or disable mechanism, use a dedicated trusted browser
profile, install no untrusted editor extensions, register only this worker, and
rotate its backend key after suspected compromise.

## TLS and backend secrets

`worker.local-domain` resolves to reserved address `172.16.20.195`.

nginx terminates HTTPS/WSS on TCP/443 and proxies only to
`127.0.0.1:8000`. Certificate and key material come from the existing local CA
and remain outside Git. Store installed material under `/etc/nginx/tls/` with
root ownership and restrictive permissions.

The certificate delivery mechanism is intentionally undecided until operator
input is available.

Backend secrets live in a root-owned runtime environment or credential file
with restrictive permissions. The systemd unit references that file and never
contains plaintext secrets. Provisioning and verification must not print secret
values.

## Firewall and networking

The Windows host has a dedicated Hyper-V adapter on VLAN10 with reserved IPv4
address `172.16.20.195`. WSL uses mirrored networking.

Only nginx TCP/443 may accept LAN traffic. The Hyper-V firewall rule must use
the discovered WSL VM creator identity and explicit approved source ranges.
Port 8000 remains localhost-only and receives no Windows/Hyper-V inbound rule.

Exact trusted source ranges are intentionally undecided. Ask before creating
the firewall rule.

Outbound policy requires a separate evidence pass. Inspect actual destinations
needed by GitHub, package registries, Claude Code, Codex, OpenHands, the LLM
gateway, and development dependencies before proposing enforcement. Do not
apply broad outbound blocking speculatively.

Primary Microsoft sources:

- [WSL basic commands](https://learn.microsoft.com/en-us/windows/wsl/basic-commands)
- [Advanced WSL configuration](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)
- [WSL networking](https://learn.microsoft.com/en-us/windows/wsl/networking)
- [Hyper-V firewall rules](https://learn.microsoft.com/en-us/powershell/module/netsecurity/new-netfirewallhypervrule)

## GitHub

Use the available non-personal automation account with least privilege. Initial
Omni PoC access is limited to required repositories. Choose fine-grained PAT or
dedicated SSH credentials interactively at the GitHub authentication step; do
not import personal credentials silently.

## Repository structure

```text
runtimes/wsl/
|-- README.md
|-- install.ps1
|-- provision.sh
|-- wsl.conf
|-- tests/
|   |-- install.Tests.ps1
|   `-- provision.Tests.sh
```

Only implemented and verified assets belong in this tree. Add each remaining
file only when its logical step is ready to implement and verify.

## Verification contract

Verification is incremental and behavioral. A configuration file existing is
not proof that its behavior works.

Eventually verify:

- Windows 11, supported WSL version, and exact Ubuntu 26.04 identifier;
- dedicated Ubuntu 26.04 distribution and `agent` default user;
- systemd operation;
- Windows automount and interoperability disabled;
- installed OpenHands/Canvas/automation/ACP versions;
- unified backend listening only on `127.0.0.1:8000`;
- mandatory backend API authentication rejects unauthenticated requests;
- public-mode UI prompts for the backend key and does not embed it;
- nginx certificate, HTTPS, and WebSocket proxying;
- LAN HTTPS reachability through TCP/443 only;
- trusted-source Hyper-V firewall restriction;
- Claude Code installation, subscription authentication, and ACP execution;
- Codex installation, subscription authentication, and ACP execution;
- workspace ownership and permissions;
- scoped GitHub access after authentication.

## Staged setup

For each logical step:

1. inspect repository and target-machine state;
2. verify current official upstream behavior;
3. explain one next change and required operator input;
4. implement only that change;
5. execute its verification;
6. report evidence before continuing.

Keep the runtime minimal. Prefer supported OpenHands, WSL, Git, Claude Code,
Codex, nginx, and systemd behavior over custom infrastructure. Do not add custom
orchestration, workspace management, memory systems, or agent protocols without
a demonstrated limitation.
