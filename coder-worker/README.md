# Coder Desktop Worker

Turns a stock Ubuntu 26.04 WSL2 distribution on the Windows desktop into a
Docker host for Coder workspaces. The only thing it exposes is Docker's TCP
listener on 2376 with mutual TLS, reachable from the cluster node addresses
only. There is no image build: a Windows installer, one in-distro tool that
installs and operates the distribution, a trust-material generator, and a
committed non-secret host profile.

```text
coderd (namespace coder), docker provider, tcp://172.16.20.195:2376
  client certificate from Secret coder-docker-tls at /etc/coder/docker-tls
        |  mutual TLS; the client certificate is the only credential
        v
Windows desktop: Hyper-V firewall, inbound Block, 2376 from the node IPs only
        v
WSL2 "coder-worker": Ubuntu 26.04, systemd, mirrored networking
  dockerd tcp://0.0.0.0:2376, tls + tlsverify, never 2375
  workspace containers mount /etc/ssl/lan/lan-ca.pem and
  /etc/coder-worker/workspace.env read-only
```

## Install

Elevated PowerShell on the desktop, twice:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -HostProfile towerr
wsl.exe -d coder-worker -u root -- coder-worker-overlay secrets
```

The first reads `hosts/towerr.profile`, downloads every other artifact from the
release tag pinned in `$DefaultRelease`, verifies each against that release's
`checksums.txt`, reconciles `.wslconfig`, applies the firewall rule, registers
the distribution, installs Docker and registers the keepalive task. The firewall
rule goes on before the distribution exists, so 2376 is never briefly open to
the LAN. The second asks for the Vaultwarden master password, fetches the trust
material, verifies it and starts Docker. Nothing else is prompted for or typed.

`install.ps1` is the trust anchor: check its SHA-256 against the release page
before running it. `-ChecksumsSha256` pins `checksums.txt` too, for a fully
offline chain of custody. `-ReleaseTag` selects another release; `-OverlayPath`
or `-OverlayUri` with `-OverlaySha256`, and likewise `-Firewall*`,
`-Keepalive*`, `-Rootfs*`, supply an artifact by hand with a mandatory checksum;
`-SkipFirewall` and `-SkipKeepalive` skip a step deliberately, and skipping the
firewall leaves 2376 unrestricted. The parameter is `-HostProfile` because
`-Host` and `-Profile` shadow PowerShell automatic variables.

Windows 11, elevated PowerShell and WSL 2.7 or later are required. Every step
reconciles, so rerunning the installer is how you recover a half-finished
install or roll out a newer overlay: an already-registered distribution keeps
its data and its VHD, and only the overlay install, the firewall rule and the
keepalive task are reapplied. `.wslconfig` is global, so the installer never
sets `memory` or `processors`.

## Host profile

`hosts/<name>.profile` is a committed, non-secret `KEY=value` file. That grammar
was chosen because both PowerShell and POSIX sh parse it in a few lines and
`workspace.env` already uses it. The extension is `.profile`, not `.env`,
because this repository gitignores `*.env` as the shape secrets arrive in.

| Key | Required | Meaning |
|---|---|---|
| `DISTRO_NAME` | yes | WSL distribution name |
| `UBUNTU_DISTRIBUTION` | yes | Store flavour, `Ubuntu-26.04` |
| `VHD_LOCATION` | no | Put the VHD off the system drive |
| `VAULT_URL` | yes | Absolute HTTPS Vaultwarden URL |
| `VAULT_EMAIL` | yes | Vaultwarden account |
| `VAULT_FOLDER` | no | Folder the items live in |
| `VAULT_ITEM_CA` | yes | Item holding `ca.pem` |
| `VAULT_ITEM_SERVER_CERT` | yes | Item holding `server-cert.pem` |
| `VAULT_ITEM_SERVER_KEY` | yes | Item holding `server-key.pem` |
| `VAULT_ITEM_LAN_CA` | no | Item holding the LAN root CA |
| `VAULT_ITEM_WORKSPACE_ENV` | no | Item holding the workspace env file |
| `DOCKER_PORT` | yes | Must be 2376 |
| `FIREWALL_REMOTE_ADDRESSES` | yes | IPv4 hosts or /24-or-narrower ranges, comma separated |

Both parsers accept only these keys, reject a repeat, reject any key whose name
looks like a secret, and reject any value shaped like a credential: PEM
material, a token prefix, or 40 or more opaque characters. A profile can
therefore never open 2375 or set the firewall source to `Any`. Explicit flags
override it on both sides; `coder-worker-overlay install` writes it to
`/etc/coder-worker/profile`, where `secrets` and `verify` read it.

`VAULT_ITEM_LAN_CA` is optional: omit it and `lan-ca.pem` is never written,
while `verify` fails if a stale copy remains. The h-cloud Docker template
bind-mounts that path unconditionally, so dropping the item without removing the
bind mount there leaves Docker creating a directory at that path on the next
workspace start. `verify` refuses the directory rather than reading it as a
certificate; removing the mount is the operator's job in h-cloud.

## Trust material and rotation

One CA signs both halves. Generate it once, on a trusted machine, never in the
repository: `coder-worker/scripts/gen-docker-tls.sh --out ~/coder-worker-tls`.
ECDSA P-256, a ten-year CA, two-year leaves, server SANs `IP:172.16.20.195` and
`DNS:coder-worker.h-cloud.lan`, all overridable.

| File | Goes to |
|---|---|
| `ca.pem`, `server-cert.pem`, `server-key.pem` | one Vaultwarden item each, PEM in the notes, named by `VAULT_ITEM_*` |
| workspace env file | a Vaultwarden item, `NAME=value` lines in the notes |
| `ca.pem`, `client-cert.pem`, `client-key.pem` | the `coder-docker-tls` SOPS Secret, read by coderd |

`ca-key.pem` goes nowhere; keep it offline to reissue a leaf. Delete the output
directory once both halves are stored. Rotation is the same: replace the items
and the SOPS Secret, rerun `coder-worker-overlay secrets`, reconcile Flux.

Items are addressed by name. `secrets` lists the vault once, keeps entries whose
name and folder match exactly, and refuses unless exactly one matches each item,
so a renamed, deleted or duplicated item fails loudly. `rbw get` alone would
fall back to a partial name match, which is why resolution happens here and the
fetch is then done by the resolved UUID. `--ca-id` and its four siblings still
take UUIDs and skip resolution.

The workspace env item exists because a Docker workspace cannot read the cluster
Secret that gives Kubernetes workspaces `LITELLM_API` and a GitHub token. Its
notes are the file verbatim: `NAME` matching `^[A-Za-z_][A-Za-z0-9_]*$`, the
rest of the line taken raw after the first `=`. Any other line fails the whole
run, reported by line number and never by content. A rotated token must be
written to both this item and the SOPS Secret.

## Operating the distribution

Everything inside the distribution runs as root through
`/usr/local/sbin/coder-worker-overlay`: `install --profile FILE` (run by
`install.ps1`), `secrets [--no-enable]`, `verify`, `enable`, and `status`, which
is safe to run at any time and prints state but never a value.

`secrets` reads the master password once with `systemd-ask-password`, keeps it
only in a root-owned tmpfs file for the duration of one transient `systemd-run`
unit that exposes it to `rbw` as a credential, then locks `rbw`, stops its agent
and purges the local vault copy whether the fetch succeeded or not. Items are
staged beside their destinations and moved into place only once every one is
fetched and accepted, so a failure anywhere leaves the previous files untouched.
It then verifies and enables Docker unless `--no-enable`.

| Path | Owner | Mode |
|---|---|---|
| `/etc/docker/tls` | `root:root` | `0700` |
| `/etc/docker/tls/ca.pem` | `root:root` | `0644` |
| `/etc/docker/tls/server-cert.pem` | `root:root` | `0644` |
| `/etc/docker/tls/server-key.pem` | `root:root` | `0600` |
| `/etc/ssl/lan/lan-ca.pem` | `root:root` | `0644` |
| `/etc/coder-worker/workspace.env` | `1000:1000` | `0600` |

`1000:1000` is the container's `coder` user, which the distribution has no
account for. `verify` checks each path is a regular file with that owner and
mode, that every `workspace.env` line is a comment, blank or `NAME=value`, that
the server key matches its certificate, that the certificate was issued by
`ca.pem`, that `lan-ca.pem` is a file and not a bind-mount directory, that
`daemon.json` never names 2375, and that `dockerd --validate` accepts it.

## Security model

Mirrored networking puts `0.0.0.0:2376` on the host address, so the Hyper-V
firewall rule is the only network boundary. `tlsverify` is the only
authentication: any client holding a certificate signed by the CA reaches the
daemon, and a daemon socket is root on that host. Treat the client half of the
CA as a root credential for the desktop. Such a client can also start a
container that bind-mounts `workspace.env` and read it; the `0600` mode keeps
that file from other processes in the distribution, not from the daemon's
clients.

Until all three files under `/etc/docker/tls` exist, `docker.service` carries a
`ConditionPathExists` for each and systemd skips it, so the daemon fails closed
and 2376 never opens without mutual TLS configured. Everything in the
distribution runs as root; there is no `agent` user and no sudo.

The WSL Hyper-V firewall is one shared object, so both products drive
`worker/windows/firewall.ps1` under their own rule name, leaving
`openhands-worker-https` untouched; `-RemoteAddresses` accepts only IPv4 hosts
or /24-or-narrower ranges and `-Port` only 443 or 2376. That script and
`keepalive.ps1` are copied into this release rather than referenced from the
worker release, so one `checksums.txt` covers an install and the two version
streams stay independent. Keepalive runs at logon, so the host must log the
operator on for the backend to return after a reboot.

Ubuntu is asserted to be 26.04 `resolute`, the Docker apt signing key is
SHA-256 verified against a constant before it is trusted, and `docker-ce`,
`docker-ce-cli` (`5:29.8.0-1~ubuntu.26.04~resolute`), `containerd.io`
(`2.3.4-2~ubuntu.26.04~resolute`) and `rbw` (`1.13.2-7`) are pinned and held.
Nothing uses a `latest` tag.

## Releasing

Tag `coder-worker-v<version>`. The workflow refuses it unless `$DefaultRelease`
in `install.ps1` and `RELEASE_VERSION` in the overlay both equal the tag, so a
published `install.ps1` always points at the release containing it. Both are
bumped by hand in the tagged commit; CI rewrites nothing. The workflow runs
every test, then publishes `install.ps1`, the overlay, `firewall.ps1`,
`keepalive.ps1`, `gen-docker-tls.sh` and each host profile as
`host-<name>.profile`, with a `checksums.txt` it verifies before upload.

## Verification

```sh
nc -zv 172.16.20.195 2376                       # from outside the node list: must time out
openssl s_client -connect 172.16.20.195:2376 </dev/null   # from a pod: must fail
docker --tlsverify --tlscacert ca.pem --tlscert cert.pem --tlskey key.pem \
  -H tcp://172.16.20.195:2376 version           # from a pod with the client half: succeeds
```

```powershell
Get-NetFirewallHyperVRule | Where-Object DisplayName -match 'worker'
wsl.exe -d coder-worker -u root -- coder-worker-overlay status
```

`status` must show 2376 and nothing on 2375, and the rule list both
`openhands-worker-https` and `coder-worker-docker` with their own port and
source sets. A file check is not a runtime proof: complete a real workspace
build before calling the backend done.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `no vault item is named "..."` | The item was renamed, or `VAULT_FOLDER` does not match |
| `N vault items are named "..."` | Duplicates in that folder; delete one or pass `--ca-id` and friends |
| `missing profile /etc/coder-worker/profile` | The distribution predates the profile; reinstall on a fresh one, or pass `--profile` |
| `... exists but no LAN root CA is configured` | `VAULT_ITEM_LAN_CA` was dropped; remove the stale `lan-ca.pem` |
| `refusing to replace non-regular file .../lan-ca.pem` | Docker created a bind-mount directory; remove it, then rerun `secrets` |
| `docker did not become ready` | `verify` passed but the unit did not start; check `journalctl -u docker` |
| Workspace start fails while the desktop is off | Expected. Import and push never contact the desktop; start, stop and delete do. `coder delete --orphan` removes the record |

## Tests

```sh
bash coder-worker/tests/profile.Tests.sh
bash coder-worker/tests/install.Tests.sh
bash coder-worker/tests/overlay.Tests.sh
bash coder-worker/tests/gen-docker-tls.Tests.sh
pwsh -NoProfile -File coder-worker/tests/install.Tests.ps1
shellcheck coder-worker/scripts/gen-docker-tls.sh coder-worker/wsl/coder-worker-overlay \
  coder-worker/tests/*.sh
```

The shell suites run inside an Ubuntu 26.04 container and need Docker. The
install suite runs the overlay five times against stubbed apt, systemd and
Docker to prove the second run changes no byte and that a signing key failing
its pinned checksum aborts. The overlay suite runs `install` first, so it
exercises the real `daemon.json` rather than a copy.
