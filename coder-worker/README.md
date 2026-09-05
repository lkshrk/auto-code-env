# Coder Desktop Worker

Turns a stock Ubuntu 26.04 WSL2 distribution on the Windows desktop into a
Docker host for Coder workspaces. The only thing it exposes is Docker's TCP
listener on 2376 with mutual TLS, reachable from the cluster node addresses
only.

There is no image build here. The distribution is stock Ubuntu plus one pinned,
checksummed setup script; the product is that script, the in-distro overlay
tool, the Windows installer, and the trust-material generator.

## Runtime contract

```text
coderd pod (namespace coder)
  terraform provider "docker"
    host      = tcp://172.16.20.195:2376
    cert_path = /etc/coder/docker-tls      Secret coder-docker-tls, SOPS, mode 0444
        |
        |  mutual TLS; the client certificate is the only credential
        v
Windows desktop 172.16.20.195
  Hyper-V firewall: inbound default Block, TCP/2376 allowed from the node IPs
        |
        v
WSL2 distribution "coder-worker": Ubuntu 26.04, systemd, mirrored networking
  dockerd  tcp://0.0.0.0:2376  tls + tlsverify        never 2375
        |
        +-- coder-<owner>-<workspace>        codercom/enterprise-base:ubuntu
        +-- coder-<owner>-<workspace>-dind   docker:27-dind, privileged, optional
        `-- /etc/ssl/lan/lan-ca.pem          bind-mounted read-only into workspaces

workspace agent -> https://coder.h-cloud.io   outbound only, DERP relay in coderd
```

Mirrored networking puts `0.0.0.0:2376` on the host address, so the Hyper-V
firewall rule is the only network boundary. `tlsverify` is the only
authentication: any client holding a certificate signed by the CA reaches the
daemon, and a daemon socket is root on that host. Treat the client half of the
CA as a root credential for the desktop.

Everything runs as root inside the distribution. There is no `agent` user and no
sudo; the distribution exists to run dockerd and nothing else.

## Install

Elevated PowerShell on the desktop. `install.ps1` takes the setup script and
the overlay tool as two separately checksummed artifacts, because both have to
reach the distribution before anything is configured:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -SetupScriptPath .\setup.sh -SetupScriptSha256 <64-hex-sha256> `
  -OverlayPath .\coder-worker-overlay -OverlaySha256 <64-hex-sha256>
```

`-SetupScriptUri` and `-OverlayUri` take the same artifacts over absolute HTTPS
instead. Exactly one source per artifact, and the SHA-256 is mandatory in both
modes. Compute them from the repository copies:

```sh
sha256sum coder-worker/wsl/setup.sh coder-worker/wsl/coder-worker-overlay
```

The installer requires Windows 11, elevated PowerShell, and WSL 2.7 or later.
It merges `networkingMode=mirrored` and `dnsTunneling=true` into `.wslconfig`,
backing up the existing file only when it changes, then runs
`wsl --install Ubuntu-26.04 --name coder-worker --no-launch`. Naming a store
distribution needs WSL 2.4.4 or later, which the 2.7 floor already guarantees.
`wsl --manage <distro> --set-sparse true` follows so the VHD gives space back
after a prune.

`-Location <directory>` puts the VHD outside the system drive. `-DistroName`
and `-UbuntuDistribution` override the defaults `coder-worker` and
`Ubuntu-26.04`.

If the store flavour is unavailable on the host, pass a root filesystem instead
and the installer imports it. `-Location` is mandatory in that mode:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 `
  -RootfsUri https://cloud-images.ubuntu.com/wsl/.../ubuntu-26.04-wsl-amd64.wsl `
  -RootfsSha256 <64-hex-sha256> -Location D:\wsl\coder-worker `
  -SetupScriptPath .\setup.sh -SetupScriptSha256 <64-hex-sha256> `
  -OverlayPath .\coder-worker-overlay -OverlaySha256 <64-hex-sha256>
```

Both artifacts are staged into `/root/coder-worker` and their SHA-256 is
re-checked inside the distribution before anything runs. `setup.sh` then runs
twice with a `wsl --terminate` after each pass: the first pass writes
`/etc/wsl.conf` and installs packages, the terminate lets systemd come up under
the new configuration, and the second pass enables the Docker units. Both passes
are no-ops once their state is already correct.

An existing distribution is a no-op. If `coder-worker` is registered, the
installer does not download, import, or reconfigure it. Host `.wslconfig`
reconciliation still runs first and may call `wsl --shutdown`.

`.wslconfig` is global: `memory` and `processors` bound every distribution on
the host, including `openhands-worker`. The installer therefore never sets them.
Choose them by hand if workspaces need a cap:

```ini
[wsl2]
memory=24GB
processors=8
```

## Firewall

`coder-worker` does not ship its own firewall script. The WSL Hyper-V firewall
is one shared object, so both products drive `worker/windows/firewall.ps1`, each
with its own rule name. A wrapper would only add a second file that has to find
the first one on an operator's disk, where the two scripts are separate release
assets.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\firewall.ps1 `
  -RuleName coder-worker-docker -RuleDisplayName "Coder worker Docker" `
  -Port 2376 -RemoteAddresses <node IPs, comma separated>
```

Use the same node-IP list as the worker's TCP/443 rule. `-RemoteAddresses`
accepts only IPv4 hosts or ranges of /24 or narrower; `Any` is refused. `-Port`
accepts only 443 or 2376. Create, update, and delete touch only the rule with
the given name, so adding this rule leaves `openhands-worker-https` untouched.

## Keepalive

WSL idle-stops a distribution about ten seconds after the last `wsl.exe` session
ends, which would take dockerd down between workspace builds.
`worker/windows/keepalive.ps1` is already parameterized:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\keepalive.ps1 `
  -DistroName coder-worker -TaskName coder-worker-keepalive
```

The task runs at logon of the current user, so the host must log the operator on
(or auto-logon) for the backend to come back after a reboot.

## Trust material

One CA signs both halves. Generate it once, on a trusted machine, never in the
repository:

```sh
coder-worker/scripts/gen-docker-tls.sh --out ~/coder-worker-tls
```

ECDSA P-256, a ten-year CA, two-year leaves, server SANs
`IP:172.16.20.195` and `DNS:coder-worker.h-cloud.lan`. `--server-ip`,
`--server-dns`, `--ca-cn`, `--server-cn`, and `--client-cn` override the
defaults. The output directory must be new or empty and outside this repository;
the script refuses otherwise.

| File | Goes to | Consumed by |
|---|---|---|
| `ca.pem` | Vaultwarden item, PEM in the notes | `coder-worker-overlay secrets --ca-id` |
| `server-cert.pem` | Vaultwarden item, PEM in the notes | `--crt-id` |
| `server-key.pem` | Vaultwarden item, PEM in the notes | `--key-id` |
| `ca.pem` | `coder-docker-tls` SOPS Secret, key `ca.pem` | coderd |
| `client-cert.pem` | `coder-docker-tls` SOPS Secret, key `cert.pem` | coderd |
| `client-key.pem` | `coder-docker-tls` SOPS Secret, key `key.pem` | coderd |

`ca-key.pem` goes nowhere. Keep it offline; it is only needed to reissue a
leaf. Delete the output directory once both halves are stored. The LAN root CA
is the item the worker already uses, referenced by `--lan-ca-id`.

Rotation is the same sequence: regenerate, replace the Vaultwarden items and the
SOPS secret, run `secrets` and `enable` again, reconcile Flux.

## Secrets and enable

Inside the distribution as root. `coder-worker-overlay secrets` reads the
Vaultwarden master password once with `systemd-ask-password`, keeps it only in a
root-owned tmpfs file for the duration of one transient `systemd-run` unit that
exposes it to `rbw` as a credential, fetches the four items by immutable UUID,
and writes them with the required ownership and modes. It then locks `rbw`,
stops its agent, and purges the local vault copy.

```powershell
wsl.exe -d coder-worker -u root -- coder-worker-overlay secrets `
  --vault-url https://vault.example --email worker@example `
  --ca-id <uuid> --crt-id <uuid> --key-id <uuid> --lan-ca-id <uuid>
wsl.exe -d coder-worker -u root -- coder-worker-overlay verify
wsl.exe -d coder-worker -u root -- coder-worker-overlay enable
```

| Path | Owner | Mode |
|---|---|---|
| `/etc/docker/tls` | `root:root` | `0700` |
| `/etc/docker/tls/ca.pem` | `root:root` | `0644` |
| `/etc/docker/tls/server-cert.pem` | `root:root` | `0644` |
| `/etc/docker/tls/server-key.pem` | `root:root` | `0600` |
| `/etc/ssl/lan/lan-ca.pem` | `root:root` | `0644` |

`verify` checks that each path is a regular file with that owner and mode, that
the server key matches the server certificate, that the certificate was issued
by `ca.pem`, that `/etc/ssl/lan/lan-ca.pem` is a file and not the directory
Docker creates for a bind mount whose source is missing, that `daemon.json`
never names port 2375, and that `dockerd --validate` accepts it.

`enable` refuses to start anything until `verify` passes, then enables
`docker.socket` and `docker.service`, pulls the workspace images listed in
`/etc/coder-worker/images`, prints the listening sockets, and fails if anything
answers on 2375 or nothing answers on 2376.

`status` prints the release marker, unit state, the trust material with its
modes, the server certificate expiry, and the listening sockets. It is the one
subcommand that is safe to run at any time.

Until all three files under `/etc/docker/tls` exist, `docker.service` carries a
`ConditionPathExists` for each of them and systemd skips it. The daemon fails
closed: it never starts, so 2376 never opens without mutual TLS configured.

## What setup.sh pins

| Component | Pin |
|---|---|
| Ubuntu | `26.04`, codename `resolute`, asserted from `/etc/os-release` |
| Docker apt signing key | SHA-256 verified against a constant before it is trusted |
| `docker-ce`, `docker-ce-cli` | `5:29.8.0-1~ubuntu.26.04~resolute` |
| `containerd.io` | `2.3.4-2~ubuntu.26.04~resolute` |
| `rbw` | `1.13.2-7` |

All four packages are held with `apt-mark hold` after install. Updating any of
them is a source change: edit the constant in `setup.sh`, recompute its SHA-256,
and rerun the installer against a fresh distribution.

`daemon.json` sets `hosts` to `fd://` and `tcp://0.0.0.0:2376`, `tls` and
`tlsverify` to true, the three TLS paths, `log-driver: local` with rotation, and
a `172.28.0.0/14` address pool that avoids both the LAN and the cluster pod
CIDR. A drop-in clears `-H fd://` from the unit `ExecStart` so `daemon.json`
owns the listeners; without it dockerd refuses to start with hosts configured in
both places.

Two files are copied rather than shared with `worker/`: the `rbw` credential
pinentry helper, which `worker/provision.sh` writes into its image, and the
`.wslconfig` reconciliation in `install.ps1`. Both installers ship as standalone
release assets that an operator downloads one file at a time, so a shared module
would have to be downloaded too. Change either one in both places.

## Verification

After the firewall change and again after `enable`:

```sh
# from a cluster pod, the worker's existing path still works
nc -zv 172.16.20.195 443

# from a LAN host outside the node list, this must time out
nc -zv 172.16.20.195 2376

# from a cluster pod: no client certificate and a foreign one both fail
openssl s_client -connect 172.16.20.195:2376 </dev/null
openssl s_client -connect 172.16.20.195:2376 -cert other.pem -key other-key.pem </dev/null

# from a cluster pod with the real client half, this succeeds
docker --tlsverify --tlscacert ca.pem --tlscert cert.pem --tlskey key.pem \
  -H tcp://172.16.20.195:2376 version
```

```powershell
Get-NetFirewallHyperVRule | Where-Object DisplayName -match 'worker'
Get-NetTCPConnection -LocalPort 2376
```

```sh
wsl.exe -d coder-worker -u root -- ss -ltn
```

`ss -ltn` must show 2376 and nothing on 2375. `Get-NetFirewallHyperVRule` must
list both `openhands-worker-https` and `coder-worker-docker`, each with its own
port and source set. During a build, `Get-NetTCPConnection -LocalPort 2376`
shows a cluster node address as the remote peer.

A file check is not a runtime proof. Complete a real workspace build before
calling the backend done.

## Offline desktop

Template import and push never contact the desktop, because the Terraform
provider is configured with `disable_docker_daemon_check = true`. Workspace
start, stop, and delete do, and fail with a provider error while the distro or
the host is down. `coder delete --orphan` removes the workspace record when the
containers cannot be reached. A Windows reboot without auto-logon leaves the
backend offline until the operator logs in, the same limitation the worker has.

## Tests

```sh
bash coder-worker/tests/setup.Tests.sh
bash coder-worker/tests/overlay.Tests.sh
bash coder-worker/tests/gen-docker-tls.Tests.sh
pwsh -NoProfile -File coder-worker/tests/install.Tests.ps1
shellcheck coder-worker/wsl/setup.sh coder-worker/wsl/coder-worker-overlay \
  coder-worker/scripts/gen-docker-tls.sh coder-worker/tests/*.sh
```

The three shell suites run inside an Ubuntu 26.04 container and need Docker. The
setup suite runs `setup.sh` five times against stubbed apt, systemd, and Docker
to prove that the second run changes no byte, that Docker is enabled only once
systemd is up, and that a signing key failing its pinned checksum aborts the
run. The overlay suite runs `setup.sh` first, so it exercises the real
`daemon.json` rather than a copy of it.
