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
`setup.ps1`, `update.ps1`, the shared `common.ps1` helpers, the in-distro
`openhands-overlay` tool, the standalone `apply-profile.py` applier, every
settings profile as `profile-<name>.json`, and a
combined `checksums.txt` covering all of them, and GHCR has immutable
`ghcr.io/lkshrk/openhands-worker:<version>` manifest with both architectures,
SBOM, and provenance.

An arm64 Linux build proves native Linux build compatibility only. It is not a
Windows-on-Arm WSL runtime proof. Publication gate: native amd64 CI and real Windows import
must both pass before release. Windows-on-Arm remains a separate runtime gate.

## One-command setup and update

`setup.ps1` and `update.ps1` drive everything the next two sections describe by
hand. Both read one operator-owned host configuration, download every release
asset they need, verify each one against `checksums.txt` from the same release
before it is used, and drive `openhands-overlay` inside the distribution. Both
require elevated PowerShell. Both dot-source `common.ps1`, so take all three
from the same release:
`https://github.com/lkshrk/auto-code-env/releases/download/openhands-worker-v<version>/setup.ps1`,
`https://github.com/lkshrk/auto-code-env/releases/download/openhands-worker-v<version>/update.ps1`,
and `common.ps1` beside them.

The configuration lives at `%ProgramData%\openhands-worker\worker.json` unless
`-Config` says otherwise. It is host-specific and never committed. `distro`
defaults to `openhands-worker`, `arch` is auto-detected, `release` may be a tag
or `latest`, and every other key is mandatory. `profile` is either a release
asset name, an HTTPS URL, or a local path; a release asset is downloaded and
verified like every other asset.

`profileCommon` is optional and names the shared profile release asset, default
`profile-common.json`. It is applied only when `checksums.txt` of the resolved
release lists it, so a host pinned to an older release that predates the shared
profile keeps working with its host profile alone. When it is present, both
setup and update stage it at `/etc/openhands/profile-common.json` and pass it to
`openhands-overlay settings` before the host profile, so the host profile wins on
every key it sets.

This is the towerr configuration:

```json
{
  "distro": "openhands-worker",
  "release": "latest",
  "remoteAddresses": ["10.254.0.10", "10.254.0.11", "10.254.0.99", "192.168.63.57"],
  "vault": { "url": "https://vlt.h-cloud.io", "email": "agent-worker@harke.me" },
  "items": {
    "crt": "2924548c-ec74-4fd3-9181-b303cd574dbb",
    "key": "a9e6c601-77b3-47b6-980d-493743b7d7da",
    "api": "b9ba25a8-0b4f-45ef-9236-2504c2ba807c",
    "pat": "28226043-0a70-4d54-bfb8-592086a319c0",
    "ca": "cf9ec766-c260-4e7d-abe0-3299745b57b4"
  },
  "origins": ["https://orc.ai.h-cloud.lan"],
  "profile": "profile-towerr.json",
  "profileCommon": "profile-common.json"
}
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\update.ps1 -Release latest
```

`setup.ps1` resolves the release, verifies the assets, refuses to touch an
existing distribution unless `-Replace` is passed, runs `install.ps1`,
`firewall.ps1`, and `keepalive.ps1`, then pushes the release `openhands-overlay`
and the settings profile into the distribution and runs `ca`, `secrets`,
`github`, `origin`, `enable`, `settings`, `verify`, and `status` in that order.
`enable` precedes `settings` because the profile is applied through the running
backend at `http://127.0.0.1:8000`. `-Replace` delegates to `update.ps1 -Force`.

`update.ps1` compares `/etc/openhands/release` with the target version and stops
at "already at" unless `-Force` is passed; a missing marker counts as older than
every release, and a newer installed version is refused without `-Force`. It
exports the agent state with `openhands-overlay state export`, imports the new
image as `openhands-worker-next`, waits for that distribution to finish booting,
and provisions that staging distribution. The wait polls
`systemctl is-system-running` in the staging distribution every two seconds for
up to 120 seconds and continues on `running` or `degraded`, because a freshly
imported distribution answers the first overlay call before systemd has finished
starting nginx and the backend.
completely. The old distribution is terminated only when the staging one is
ready to bind TCP/443, and it is unregistered only after the staging
distribution has passed `enable`, `settings`, and `verify`. The swap then
renames the staging distribution by writing the `DistributionName` value under
`HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss\{guid}`, which avoids
a multi-gigabyte export and re-import. Any failure before the unregister removes
`openhands-worker-next`, restarts the old distribution, and exits non-zero, so
the worker either updates or stays exactly as it was. Afterwards `keepalive.ps1`
and `firewall.ps1` re-run, and `enable` and `status` confirm the result. The
state archive of the last run is kept in `%TEMP%\openhands-worker`.

`update.ps1 -Schedule` registers a hidden weekly scheduled task for the current
user that runs `update.ps1 -Release latest` against the same `worker.json`, and
exits without updating. The task runs with the highest available privileges
because the update needs the same elevation an interactive run needs.

Security notes. The Vaultwarden master password is read once with `Read-Host
-AsSecureString` (or supplied as a `-VaultPassword` SecureString) and stored
DPAPI-protected as an `Export-Clixml` `PSCredential` at
`%LOCALAPPDATA%\openhands-worker\vault.cred`, so only the same Windows user on
the same machine can decrypt it. It reaches the distribution only on stdin of
`wsl.exe ... openhands-overlay <command> --password-stdin`, written as exact
bytes through a redirected `System.Diagnostics.Process` stream; it is never a
command-line argument and never written unencrypted. The state archive is moved
the same way: `state export` is captured from a redirected stdout stream to a
file and `state import` is fed from a file stream, so no PowerShell pipeline
re-encodes the bytes. Every asset, including the settings profile and the
`.wsl` image, is checked against `checksums.txt` before it is used, and a
mismatch aborts before any state changes.

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
action to block and allows the requested port from those sources only, so port
8000 and everything else stay unreachable. An existing Hyper-V rule that already
matches is left alone; a differing one is removed and recreated, because
`Set-NetFirewallHyperVRule` is denied on current Windows builds:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\firewall.ps1 -RemoteAddresses 10.0.0.10,10.0.0.11
```

`-Port` accepts only 443 or 2376; any other port throws before a single
firewall call is made. `-RuleName` and `-RuleDisplayName` default to
`openhands-worker-https` and `OpenHands worker HTTPS`, so the invocation above
is unchanged. The WSL Hyper-V firewall is shared by every distribution on the
host, so a second product on the same host passes its own rule name and never
reuses the worker's. Create, update, and delete touch only the rule with the
given name; setting the Hyper-V default inbound action to block is idempotent
and safe to repeat. `coder-worker` uses this to own TCP/2376:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\firewall.ps1 `
  -RuleName coder-worker-docker -RuleDisplayName "Coder worker Docker" `
  -Port 2376 -RemoteAddresses 10.0.0.10,10.0.0.11
```

Keepalive, elevated PowerShell. WSL idle-stops a distribution about ten seconds
after the last `wsl.exe` session ends, taking nginx and the backend with it.
`keepalive.ps1` from the same release,
`https://github.com/lkshrk/auto-code-env/releases/download/openhands-worker-v<version>/keepalive.ps1`,
registers a scheduled task for the current user that runs
`wsl.exe -d openhands-worker --user root --exec /bin/sleep infinity` inside a
hidden PowerShell host at logon, with no execution time limit, and starts it
immediately. No console window exists to close. Re-running the script stops the
previous instance first, so a replaced distro is held by a fresh session. The host must log the
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

The `rbw` credential pinentry that `provision.sh` writes to
`/usr/local/libexec/openhands-rbw-pinentry` is duplicated by `coder-worker`,
which writes the same program under its own name. Both installers ship as
standalone release assets, so neither can depend on a shared file; change the
program in both places.

`openhands-overlay` ships inside the image and as a release asset,
`https://github.com/lkshrk/auto-code-env/releases/download/openhands-worker-v<version>/openhands-overlay`,
so an installed distro can take a newer tool without re-import: download as
root, compare with `checksums.txt`, then `install -o root -g root -m 0755` to
`/usr/local/sbin/openhands-overlay`. `settings` runs the applier from the image,
so take `apply-profile.py` from the same release into
`/usr/local/lib/openhands/apply-profile.py` whenever the distro predates it.

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

Unattended runs replace the interactive prompt. `secrets`, `github`, `ca`, and
`settings` accept `--password-stdin`, which reads the Vaultwarden master
password as one line from stdin. Nothing else changes: the password still lives
only in the root-owned tmpfs file for the duration of the transient unit, and an
empty password is refused.

```powershell
$password | wsl.exe -d openhands-worker -u root -- openhands-overlay settings --file /etc/openhands/towerr.json --password-stdin
```

`openhands-overlay settings --file <profile>.json` applies a declarative
per-backend profile to the local Agent Canvas backend through the ingress at
`http://127.0.0.1:8000`, authenticating with the
`/etc/credstore/local_backend_api_key` value in the `X-Session-API-Key` header.
Repository profiles live in `openhands/profiles/`, documented by
`openhands/profiles/README.md`. `openhands/profiles/common.json` holds what every
host shares, `openhands/profiles/towerr.json` holds what is specific to one
host, and `openhands/profiles/orc.json` is the non-worker orc backend. Every section is optional:

| Section | Effect |
|---|---|
| `llm` | `model`, `base_url`, `api_key_item` through `PATCH /api/settings` |
| `agent` | `kind`, `acp_server`, `acp_command`, `acp_model` through the same PATCH |
| `secrets` | one `PUT /api/settings/secrets` per named secret |
| `skills` | `POST /api/skills/install` for a skill that is not installed yet |
| `mcp_servers` | `POST /api/settings/mcp/<key>` for a new server, `PATCH /api/settings/mcp/<key>` for one that drifted |
| `git_sync` | `PUT /api/automation/v1/git-sync/config` |
| `agents` | a root `apm.yml` for omni plus `omni agents sync` |

### Profile layering

`--file` may be repeated, and the files are layered left to right:

```sh
openhands-overlay settings --file /etc/openhands/profile-common.json --file /etc/openhands/profile.json
```

`llm`, `agent`, `git_sync`, and `agents` merge per key, so a later file overrides
only the keys it sets and inherits the rest. `secrets` merges by secret name,
`mcp_servers` by server key, and `skills` by `repo_path`; in all three a later
file replaces the entry that shares a key and adds the ones that do not. Every
file is validated on its own before the merge, and cross-section references are
checked on the merged result, so an `mcp_servers` header that names a secret
declared in an earlier file resolves while one that names an undeclared secret is
refused.

The release publishes each `openhands/profiles/*.json` as `profile-<name>.json`,
so `common.json` ships as `profile-common.json` and `towerr.json` as
`profile-towerr.json`.

### Standalone applier

`openhands-overlay settings` owns only the vault side of a profile apply. It
resolves each referenced secret into a root-owned tmpfs directory, then runs
`/usr/local/lib/openhands/apply-profile.py`, which does the merging, validation,
and every backend call. The applier is python3 standard library only and holds no
worker assumptions, so a backend that is not a worker can run the same code
against the same repository profiles:

```sh
apply-profile.py --api http://openhands:8000 --api-key-file /run/secrets/session-api-key \
  --secrets-dir /run/secrets/profile --state-dir /tmp/state --skip agents \
  profile-common.json profile-orc.json
```

`--secrets-dir` holds one file per referenced secret name, so the source of the
material is pluggable: the worker fills it from Vaultwarden, another deployment
projects it from its own secret store. The vault item UUID in a profile is
meaningful only to the worker. `llm.api_key_item` resolves to `LLM_API_KEY` and
`git_sync.token_item` to `GIT_SYNC_TOKEN`; every `secrets` entry resolves to its
own name. A missing file fails before the first backend call, so a half-applied
profile is not possible. `--state-dir` holds the git-sync token digest and
defaults to `/var/lib/openhands/overlay`. `--skip <section>` drops a section from
the merged profile and is repeatable; `agents` is the worker-only section, since
omni runs outside the applier. `--print secret-items` and
`--print agents-manifest` report what the overlay needs without contacting the
backend.

`apply-profile.py` ships inside the image at
`/usr/local/lib/openhands/apply-profile.py` and as a release asset,
`https://github.com/lkshrk/auto-code-env/releases/download/openhands-worker-v<version>/apply-profile.py`,
checksummed in `checksums.txt` like every other asset.

### mcp_servers

Each key is one MCP server on the OpenHands agent. A remote server sets `url` and
may set `headers`; a stdio server sets `command` and may set `args`. The two
shapes are mutually exclusive. A header value is either a literal string or
`{"secret": "NAME"}`, which resolves to the Canvas secret of that name, so the
material stays in the vault and reaches the header without ever being written
into a profile:

```json
{
  "secrets": { "LITELLM_API": { "item": "e11c580d-59d0-4b50-a932-bcde5c4e1b57" } },
  "mcp_servers": {
    "litellm-tools": {
      "url": "https://api.ai.h-cloud.lan/mcp/",
      "headers": { "x-litellm-api-key": { "secret": "LITELLM_API" } }
    },
    "openaiDeveloperDocs": { "url": "https://developers.openai.com/mcp" }
  }
}
```

The overlay reads `agent_settings.mcp_config` from `GET /api/settings` with
`X-Expose-Secrets: plaintext` and writes only the difference: a server the
backend does not know is created with `POST /api/settings/mcp/<key>`, one whose
url, transport, headers, command, or args drifted is corrected with a sparse
`PATCH /api/settings/mcp/<key>`, and one that already matches is left alone.
Servers the backend holds but the profile does not name are never touched.

### agents

The `agents` section names the APM package that owns the agent's plugins, and
which harnesses they deploy to:

```json
{
  "agents": {
    "repo": "lkshrk/dotfiles",
    "ref": "main",
    "path": "apm/ai-plugins",
    "targets": ["claude", "codex"]
  }
}
```

`repo` is an `owner/name` shorthand or an absolute HTTPS git URL, `path` a
relative path inside it, and `targets` a non-empty list of harness names. The
overlay renders those four values into the omni root manifest at
`/home/agent/.config/omni/apm.yml`, which depends on the shared package and
declares the targets:

```yaml
name: openhands-worker
version: 1.0.0
dependencies:
  apm:
  - git: lkshrk/dotfiles
    path: apm/ai-plugins
    ref: main
targets:
- claude
- codex
```

This is the same layout the user's Macs run, so the worker and the workstations
converge on one shared package. The shared `ai-plugins` package declares no
targets of its own; the root manifest owns that choice.

The overlay then runs `omni agents sync` in `/home/agent`. Both steps run as the
`agent` user through `runuser`, with `HOME=/home/agent` and
`/home/agent/.local/bin` on `PATH`, so nothing the agent later runs is
root-owned. The manifest is rewritten only when its content differs, and the
apply prints `agents applied: synced` or `agents unchanged` plus the number of
targets. `omni agents sync` is the reconciliation and runs either way; it is
idempotent through omni's own lock and needs no confirmation flag.

`omni agents sync` shells out to `apm`, so it fails with
`apm executable not found` unless `apm` is on the agent's `PATH`. The image
therefore pins `apm-cli` to `0.29.0`, installed with `uv tool install` into
`/home/agent/.local/share/uv/tools` with its entry point at
`/home/agent/.local/bin/apm`; the smoke stage asserts that version. Without the
pin omni would resolve some other version through its own provider.

`omni agents sync` installs the global APM workspace under `/home/agent/.apm`
(`apm.yml`, `apm_modules/`, `apm.lock.yaml`), records its template state under
`/home/agent/.local/state/omni`, and deploys the resolved primitives into
`/home/agent/.claude` (skills, agents, commands, hooks, `settings.json`) and
`/home/agent/.codex` (agents, hooks, `config.toml`). Those two directories are
already part of `state export`, so a distribution swap carries them across and
the next sync reconciles whatever changed upstream.

### How the pieces connect

`apm/ai-plugins/apm.yml` in the dotfiles repository is the single source of truth
for agent plugins, MCP servers, and LSP servers. `omni agents sync` deploys them
into `/home/agent/.claude` and `/home/agent/.codex`, where the ACP subprocesses
(Claude Code and Codex) read them. Its remote MCP entries reference credentials
by environment variable, for example `${env:LITELLM_API}`.

`LITELLM_API` is declared once in `openhands/profiles/common.json` and applied as
a Canvas secret. Canvas secrets are exported into the environment of the ACP
subprocesses, which is what resolves `${env:LITELLM_API}` for the plugins omni
deployed. The same secret is resolved a second time, in the overlay, into the
`x-litellm-api-key` header of the `litellm-tools` entry in `mcp_servers`, which
is what gives the OpenHands agent itself the same LiteLLM tools. One vault item
therefore reaches both consumers, and neither the profile nor the dotfiles
repository ever holds the key.

`GH_TOKEN` follows the same route for a different purpose. It is declared in the
host profile, resolved from the worker's GitHub PAT vault item, and reaches the
ACP subprocess environment, so `gh` and direct GitHub API calls work inside a
conversation. Git over HTTPS does not need it; that already works through the
credential store `openhands-overlay github` installs.

Every `*_item` value is a Vaultwarden item UUID. All of them are fetched inside
one transient vault session, staged in a root-only tmpfs directory, used, and
deleted. Unknown keys and non-UUID item ids are refused, so a profile carrying a
`TODO` placeholder documents its shape without applying anything. The tool reads
current state before each write and skips any value that already matches, so a
second run changes nothing. Secret values are never printed; each section prints
one line.

The LAN gateway `api.ai.h-cloud.lan` presents a certificate issued by the LAN
CA, so the worker must trust that CA before `llm.base_url` is reachable.
`openhands-overlay ca --item <uuid>` fetches the PEM certificate from the vault
item's notes, installs it as
`/usr/local/share/ca-certificates/openhands-lan-ca.crt` (`root:root`, mode
`0644`), and runs `update-ca-certificates`.

`openhands-overlay state export` writes a gzip tar of `/home/agent/.openhands`,
`.claude`, `.codex`, `.git-credentials`, `.gitconfig`, and
`/var/lib/openhands/overlay` to stdout with `--numeric-owner` and nothing else;
progress goes to stderr. `/home/agent/.claude` and `.codex` carry what
`omni agents sync` deployed, and `/var/lib/openhands/overlay` carries the
git-sync token digest, so a replacement distribution does not rewrite a token
that has not changed.
`openhands-overlay state import` reads that tar from stdin, extracts it under
`/`, restores `agent:agent` ownership with the `0700` directory and `0600`
credential modes under `/home/agent`, and restores `root:root` with `0700` on
`/var/lib/openhands/overlay` and `0600` on the token digest. That is the supported way to move agent authentication onto a
replacement distribution.

```powershell
wsl.exe -d openhands-worker -u root -- openhands-overlay state export > worker-state.tar.gz
wsl.exe -d openhands-worker -u root -- openhands-overlay state import < worker-state.tar.gz
```

Every image carries `/etc/openhands/release` with `openhands-worker <version>`
(`ci-<sha>` for validation builds, `dev` for untagged local builds), stamped
through the `OPENHANDS_WORKER_VERSION` build argument. `openhands-overlay
status` prints it; the release workflow verifies it inside the `.wsl` artifact.

Automation runs leave their workspace under
`~/.openhands/agent-canvas/workspaces/automation-runs/<run>`; the shipped
`openhands-automation` never deletes them in local mode (upstream issue
OpenHands/automation#422). The WSL image ships `openhands-run-prune.timer`,
enabled by `openhands-overlay enable`, which removes run directories older than
24 hours every hour as `agent`. Drop it once the image carries an
`openhands-automation` with `AUTOMATION_WORKSPACE_RETENTION_SECONDS`.

Before proposing outbound restrictions, measure what the worker actually
talks to: `openhands-overlay egress --minutes 30` samples established TCP
connections from `/proc/net/tcp` every few seconds and prints one line per
destination and port with a sample count, reverse name, and `lan` or
`internet` scope. Loopback and link-local are excluded. Run it while real
Claude Code and Codex tasks execute so the allowlist comes from observed
traffic.

`openhands-overlay verify` checks files, ownership, modes, that the private
key matches the certificate, and `nginx -t`. `openhands-overlay enable`
refuses to start anything until `verify` passes, then enables nginx and
`agent-canvas.service` and prints the listening sockets. Expected: nginx on
`:443`, backend on `127.0.0.1:8000` only.

Operator-owned facts the tools enforce:

- Windows/Hyper-V firewall: only TCP/443 for this worker, only explicitly
  trusted VLAN/source ranges. Existing target is `172.16.20.195` on VLAN10; do
  not create broad rule or expose port 8000.
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
