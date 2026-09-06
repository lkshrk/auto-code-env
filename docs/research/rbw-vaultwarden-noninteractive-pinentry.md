# Noninteractive Vaultwarden retrieval for an OpenHands WSL worker

Research snapshot: 2026-08-29. Target: Ubuntu 26.04 LTS on WSL, systemd enabled, Windows drive automount and Linux-to-Windows interop disabled, locked-password unprivileged account `agent`, no persistent `.env`, and Canvas still requiring `LOCAL_BACKEND_API_KEY` in the launched process environment.

## Decision summary

Use `rbw` with a small, fail-closed Assuan pinentry that reads an **encrypted systemd credential**. Do not use `rbw-pinentry-keyring` for unattended boot: it can D-Bus-activate GNOME Keyring, but GNOME Keyring still needs a login-keyring unlock password; WSL starts user sessions with `login -f`, and a locked-password account supplies no PAM authentication token. The available primary sources do not prove any unattended GNOME-keyring unlock path for this configuration.

Two deployment levels:

1. **Minimal PoC:** a lingering `agent` user service, `LoadCredentialEncrypted=` with a user-scoped master-password credential, the custom pinentry, and a launcher that exports only the fetched Canvas key immediately before `exec`. This is simple but does **not** isolate the Vaultwarden master password from other code running as `agent`.
2. **Recommended unattended design:** a root-owned system service loads a system-scoped encrypted master-password credential, runs `rbw` under a root-only profile, retrieves exactly one item by UUID, stops `rbw-agent`, drops permanently to `agent`, clears the inherited environment, and `execve()`s the worker with only `LOCAL_BACKEND_API_KEY` added. This keeps the master password, rbw cache, refresh token, and the rest of the vault outside the worker UID. Root and Windows/WSL host administrators remain trusted.

`LOCAL_BACKEND_API_KEY` in the Canvas process environment is a **delivery copy**, not the source of truth. Vaultwarden remains the source of truth; the worker service obtains a fresh value on each successful start and never writes an `.env` file. Environment exposure cannot be eliminated while Canvas requires this interface: systemd explicitly warns that environment variables propagate down the process tree and are unsuitable for secrets ([systemd 259.5 source](https://github.com/systemd/systemd/blob/b3d8fc43e9cb531d958c17ef2cd93b374bc14e8a/man/systemd.exec.xml#L2813-L2820)).

## Version and evidence baseline

| Component / fact | Primary evidence | Consequence |
|---|---|---|
| Upstream `rbw` latest is **1.15.0** (2025-12-31); it is unofficial and feature-complete/maintenance-oriented. | [1.15.0 release](https://github.com/doy/rbw/releases/tag/1.15.0), [immutable README](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/README.md#L1-L17) | Pin an exact rbw version and test it against the deployed Vaultwarden release. |
| Ubuntu 26.04 ships `rbw` **1.13.2-7**, and its binary package contains only `rbw` and `rbw-agent`; it does not install `rbw-pinentry-keyring`. | [Ubuntu package](https://packages.ubuntu.com/resolute/amd64/utils/rbw), [file list](https://packages.ubuntu.com/resolute/amd64/rbw/filelist) | Installing `apt install rbw` is not enough to obtain the helper. The recommended design does not need it. |
| Ubuntu 26.04 updates currently provide systemd **259.5-0ubuntu3.4**. | [Ubuntu package index](https://packages.ubuntu.com/search?keywords=systemd&lang=en&suite=resolute-updates) | `LoadCredentialEncrypted=`, user-scoped credentials, and `systemd-creds --user` are available. |
| Ubuntu 26.04 provides GNOME Keyring **50.0-1** and libsecret **0.21.7-2build1**. | [GNOME Keyring package](https://packages.ubuntu.com/resolute/arm64/gnome/gnome-keyring), [libsecret source package](https://packages.ubuntu.com/source/resolute/libsecret) | The analysis below is tied to those source releases. |
| Vaultwarden latest is **1.37.2** (2026-08-22) and says this release is required for clients 2026.8.0+. Vaultwarden implements a nearly complete Bitwarden Client API and claims compatibility with official clients, not specifically rbw. | [1.37.2 immutable release](https://github.com/dani-garcia/vaultwarden/releases/tag/1.37.2), [immutable README](https://github.com/dani-garcia/vaultwarden/blob/46d71107f5094460dd5ecbe1dbac6e6c71e5189a/README.md#L1-L38) | Treat rbw/Vaultwarden compatibility as an integration test, not a contractual guarantee. An open rbw issue shows Vaultwarden email-2FA incompatibility in a real 1.15.0/1.35.2 pairing ([rbw #316](https://github.com/doy/rbw/issues/316)). |
| Official Bitwarden CLI latest is **2026.8.0**. | [official release](https://github.com/bitwarden/clients/releases/tag/cli-v2026.8.0) | Use only as a comparison/fallback; it has a different session-key exposure model. |
| WSL supports systemd, but systemd services do **not** keep the WSL instance alive. | [Microsoft systemd documentation](https://learn.microsoft.com/en-us/windows/wsl/systemd#how-does-enabling-systemd-affect-wsl-architecture) | A Windows-side trigger or another WSL invocation must start the distribution; Linux service enablement alone is not a host boot trigger. |

## What rbw pinentry actually permits

`rbw` has no master-password environment or password-file setting. Its `pinentry` configuration is one executable pathname. `rbw` calls `Command::new(pinentry)`—the configured string is **not shell-parsed and cannot include arguments**—then appends `--timeout 0`, optional `--ttyname`/`--display`, and sometimes `--no-global-grab` ([source](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/src/pinentry.rs#L7-L45)). Therefore, noninteractive use is supported indirectly: point `pinentry` at an executable that speaks the subset of Assuan that rbw emits.

For each request rbw writes, in order:

```text
SETTITLE rbw
SETPROMPT <prompt>
SETDESC <description>
[SETERROR <previous failure>]
GETPIN
<EOF>
```

It expects an initial `OK`, one `OK` for each setup command, then `D <encoded-secret>` and `OK`; it also skips `S` status lines and recognizes error code `83886179` as cancellation ([writer](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/src/pinentry.rs#L45-L97), [reader](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/src/pinentry.rs#L100-L179)). Assuan requires `%`, CR, and LF in `D` responses to be escaped as `%25`, `%0D`, and `%0A` ([Libassuan manual](https://www.gnupg.org/documentation/manuals/assuan/Server-responses.html)). Encoding every secret byte as `%HH` is simpler and accepted by rbw's decoder.

The prompt is security-relevant:

- Login and local-vault unlock use the exact prompt `Master Password` ([login](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/src/bin/rbw-agent/actions.rs#L95-L116), [unlock](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/src/bin/rbw-agent/actions.rs#L405-L428)).
- Device registration asks for API client ID and secret, and 2FA asks provider-specific prompts ([registration](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/src/bin/rbw-agent/actions.rs#L20-L50), [2FA](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/src/bin/rbw-agent/actions.rs#L241-L259)).

A safe noninteractive pinentry must return the credential **only** when `SETPROMPT` is exactly `Master Password`; every registration, 2FA, or unknown prompt must return an error. Initial enrollment and any later reauthentication requiring 2FA remain explicit operator actions.

## Exact `rbw-pinentry-keyring` behavior

At rbw 1.15.0, the 104-line Bash helper behaves as follows ([immutable script](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/bin/rbw-pinentry-keyring)):

- It maps the default profile to `rbw` and `RBW_PROFILE=x` to `rbw-x`.
- Its store/lookup/clear attributes are exactly:

  ```text
  application = rbw
  profile     = rbw | rbw-<RBW_PROFILE>
  type        = master_password
  ```

  The label is `<profile> master password`. Store uses the default Secret Service collection. No libsecret schema name is supplied ([helper lines 25, 31, 56, 66](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/bin/rbw-pinentry-keyring#L21-L31), [libsecret attribute handling](https://gitlab.gnome.org/GNOME/libsecret/-/blob/0936f740c02b60f02657729cd99f581db4517a41/libsecret/secret-attributes.c#L24-L44)). Attributes are lookup metadata, not confidential data ([libsecret documentation](https://gnome.pages.gitlab.gnome.org/libsecret/class.Item.html)).
- On `GETPIN` with prompt exactly `Master Password`, it runs `secret-tool lookup application rbw profile <profile> type master_password`.
- Exit 1—both “no match” and lookup/service failure in `secret-tool`—causes an interactive fallback to the plain `pinentry` executable. If a value is entered, the helper tries to store it with `secret-tool store` and suppresses all store output.
- Every non-master prompt, including 2FA and registration, is delegated to interactive `pinentry`.
- Dependencies are Bash, `secret-tool` (`libsecret-tools`), a working D-Bus user session, a Secret Service provider such as GNOME Keyring, an **unlocked** collection, and an interactive fallback `pinentry`. Upstream itself says only GNOME Keyring via `secret-tool` is supported ([1.8.0 changelog](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/CHANGELOG.md#L217-L229)).

Important failure modes:

1. The helper does not implement `SETERROR`. After a wrong cached master password, rbw's next attempt includes `SETERROR`; the helper answers `ERR Unknown command`, and rbw aborts while parsing that error instead of completing the retry ([helper command table](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/bin/rbw-pinentry-keyring#L39-L88), [rbw optional `SETERROR`](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/src/pinentry.rs#L66-L77)).
2. A locked/missing Secret Service is not fail-closed: it falls back to interactive pinentry and may hang or fail in a headless unit. `secret-tool lookup` returns 1 for both a service error and no value ([libsecret source](https://gitlab.gnome.org/GNOME/libsecret/-/blob/0936f740c02b60f02657729cd99f581db4517a41/tool/secret-tool.c#L205-L241)).
3. Store failure is hidden and, because the script uses `set -e`, can terminate the protocol without a useful Assuan response ([helper](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/bin/rbw-pinentry-keyring#L55-L69)).
4. It emits secret bytes without Assuan escaping. Spaces work after the 1.11.0 rewrite, but literal `%HH`, CR, or LF can be decoded or parsed incorrectly by rbw ([1.11.0 changelog](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/CHANGELOG.md#L134-L150), [Assuan data rules](https://www.gnupg.org/documentation/manuals/assuan/Server-responses.html)).
5. Once GNOME Keyring is unlocked, any process running as the same user and able to use that D-Bus session can issue the same attribute lookup. The attributes are visible metadata; obscurity of the tuple is not an access-control boundary.

## Can GNOME Keyring unlock unattended here?

It can start; unattended unlock is not established.

- D-Bus activation for `org.freedesktop.secrets` starts `gnome-keyring-daemon --start --foreground --components=secrets` ([GNOME Keyring 50.0 service file](https://gitlab.gnome.org/GNOME/gnome-keyring/-/blob/2ff8b070763ae025b90916a7b98643865819b451/daemon/org.freedesktop.secrets.service.in)). Starting the daemon is different from unlocking the login collection.
- GNOME documents `--login` as reading the login password from stdin for PAM and `--unlock` as reading a password from stdin to unlock or create the login keyring ([50.0 manual source](https://gitlab.gnome.org/GNOME/gnome-keyring/-/blob/2ff8b070763ae025b90916a7b98643865819b451/docs/gnome-keyring-daemon.xml#L91-L135)).
- `pam_gnome_keyring` reads `PAM_AUTHTOK`; if it is absent, it logs that no password is available and returns without unlocking. When present, it passes that password to the daemon ([50.0 PAM source](https://gitlab.gnome.org/GNOME/gnome-keyring/-/blob/2ff8b070763ae025b90916a7b98643865819b451/pam/gkr-pam-module.c#L850-L900)).
- WSL starts synchronized systemd user sessions with `login -f <user>`, which bypasses password authentication ([WSL source](https://github.com/microsoft/WSL/blob/4bfbacae1338c37443f8b5e8d10a69b216b5e8ab/doc/docs/technical-documentation/systemd.md#L10-L12)). A locked-password `agent` therefore has no login password token for PAM to reuse.

An administrator could pipe some other stored password to `gnome-keyring-daemon --unlock`, but that merely moves the unattended root-of-trust elsewhere and adds D-Bus/keyring state. Systemd credentials can feed rbw directly with fewer moving parts and clearer failure behavior.

## Evaluated options

| Option | Root of trust and reboot lifecycle | Exposure / behavior | Decision |
|---|---|---|---|
| `rbw-pinentry-keyring` + GNOME Keyring | Login-keyring password; persistent encrypted keyring on disk, unlocked state lost on WSL shutdown | Needs PAM password or another bootstrap secret; same UID can query it; interactive fallback on failure | Reject for unattended worker boot. |
| Custom Assuan pinentry + **user** `LoadCredentialEncrypted=` | User-scoped systemd credential; decrypted at service start. User credentials are tied to the selected UID and machine ID ([systemd-creds](https://github.com/systemd/systemd/blob/b3d8fc43e9cb531d958c17ef2cd93b374bc14e8a/man/systemd-creds.xml#L177-L198)). | Simple and disk ciphertext only, but the `agent` UID is allowed to decrypt/read its own credential. No isolation from worker code under that UID. | Minimal PoC only. |
| Custom Assuan pinentry + **system** `LoadCredentialEncrypted=` in root launcher | System-scoped credential, default encryption uses TPM2 if available and the host key on persistent `/var/lib/systemd`; without TPM it relies on `/var/lib/systemd/credential.secret` ([systemd-creds](https://github.com/systemd/systemd/blob/b3d8fc43e9cb531d958c17ef2cd93b374bc14e8a/man/systemd-creds.xml#L280-L305)). | Credential is copied to read-only, preferably unswappable runtime storage, accessible to unit UID and root ([systemd.exec](https://github.com/systemd/systemd/blob/b3d8fc43e9cb531d958c17ef2cd93b374bc14e8a/man/systemd.exec.xml#L4159-L4172)). Worker sees only target key. Root/host admin can recover secrets. | Recommended unattended baseline. |
| Kernel `user`/persistent keyring + custom pinentry | Kernel memory; user keyring shared by all processes with UID and destroyed when UID record ends; persistent keyring has an expiry and survives processes, not a kernel/WSL reboot ([user keyring](https://man7.org/linux/man-pages/man7/user-keyring.7.html), [persistent keyring](https://man7.org/linux/man-pages/man7/persistent-keyring.7.html)). | Same-UID access according to key permissions; still needs a boot-time loader from another root of trust. | Useful as a short-lived cache, not a root of trust. rbw-agent already provides the needed memory cache. |
| Official `bw` CLI | Master password plus API login; `bw unlock` creates a session key. | Official docs require `BW_SESSION` environment or `--session` argv for vault operations and offer `--passwordenv`/`--passwordfile` ([Bitwarden CLI docs](https://bitwarden.com/help/cli/#unlock)). This adds another high-value session secret in env/argv and a larger CLI; it does not remove master-password bootstrap. | Viable fallback if rbw compatibility breaks; not simpler or less exposed. |
| Windows Credential Manager | Windows user/DPAPI context. | With `[interop] enabled=false`, WSL cannot launch Windows processes, and with `[automount] enabled=false`, Windows drives are not mounted automatically ([Microsoft WSL config](https://github.com/MicrosoftDocs/WSL/blob/8842def77a852af26318b9ebec78063a94b068ed/WSL/wsl-config.md#L46-L53), [interop](https://github.com/MicrosoftDocs/WSL/blob/8842def77a852af26318b9ebec78063a94b068ed/WSL/wsl-config.md#L84-L93)). A Windows-side orchestrator could still inject a secret into WSL, but direct Linux retrieval is intentionally unavailable and would require Windows-side integration. | Keep as a possible stronger external bootstrap, not the Linux PoC. |
| Persistent plaintext file, `.env`, systemd `Environment=`/`EnvironmentFile=` | Linux filesystem | Persists plaintext and/or propagates it as environment; systemd says unit environments are exposed over D-Bus and down the process tree. | Reject. |

### Root and host reality

No unattended design eliminates a root of trust. systemd encrypted credentials improve at-rest handling and delay plaintext materialization until activation, but:

- The credential directory is explicitly readable by the unit UID and superuser ([systemd.exec](https://github.com/systemd/systemd/blob/b3d8fc43e9cb531d958c17ef2cd93b374bc14e8a/man/systemd.exec.xml#L4159-L4172)).
- If WSL exposes no TPM2 device, systemd's default falls back to the persistent host key. A copied VHD containing both ciphertext and `/var/lib/systemd/credential.secret` does not provide hardware separation. Verify with `systemd-creds has-tpm2`; do not assume TPM availability in WSL ([systemd-creds key selection](https://github.com/systemd/systemd/blob/b3d8fc43e9cb531d958c17ef2cd93b374bc14e8a/man/systemd-creds.xml#L280-L305)).
- Windows administrators who can access/export the WSL VHD and Linux root are trusted. If that is outside the threat model, use an external boot-time injector or hardware-backed secret service; the local host-key baseline is insufficient.
- `rbw-agent` keeps decrypted vault keys in memory and disables Linux dumpability with `prctl(PR_SET_DUMPABLE, 0)`, reducing same-UID ptrace exposure but not protecting from root ([rbw source](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/src/bin/rbw-agent/debugger.rs#L1-L18)).
- rbw's local JSON database contains encrypted vault material plus access and refresh tokens; rbw protects its cache/data/runtime directories with mode 0700 ([directory source](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/src/dirs.rs#L5-L34), [database fields](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/src/db.rs#L176-L186)). In the stronger design this profile must remain root-only.

## Recommended design

### Data and privilege flow

```text
Vaultwarden (source of truth: Canvas item, selected by immutable item UUID)
        │ TLS; rbw sync/login using root-only rbw profile
        ▼
root-owned systemd unit
  ├─ LoadCredentialEncrypted=rbw_master
  │    └─ plaintext exists only in /run/credentials/<unit>/ at activation
  ├─ rbw-agent + credential-backed Assuan pinentry
  │    ├─ sync; fail if server/auth/2FA is not satisfied
  │    └─ get exact item UUID
  ├─ stop rbw-agent
  ├─ erase temporary buffers where practical
  ├─ initgroups + setresgid/setresuid to agent; drop root permanently
  ├─ build a clean child environment (no CREDENTIALS_DIRECTORY/BW_SESSION/etc.)
  └─ execve(OpenHands worker,
             LOCAL_BACKEND_API_KEY=<fresh delivery copy>)
                    │
                    ▼
              Canvas child process
              (required environment exposure)
```

Keep initial enrollment separate:

1. Configure the root-only rbw profile with normal `pinentry-curses`.
2. Run the first `rbw sync` interactively and complete any registration/2FA.
3. Change rbw's pinentry to the credential-backed executable.
4. At unattended start, refuse every prompt except `Master Password`. If refresh-token invalidation or policy changes require 2FA, fail the service and require operator re-enrollment. Do not weaken 2FA to make boot “work.”

### Minimal fail-closed pinentry contract

This reference uses only Python's standard library. Install it root-owned and non-writable by `agent`. It tolerates rbw's appended command-line options, handles retries (`SETERROR`), serves only the master-password prompt, and percent-encodes every byte.

```python
#!/usr/bin/python3
import os
import sys
from pathlib import Path

out = sys.stdout.buffer
prompt = b""

def write(data: bytes) -> None:
    out.write(data)
    out.flush()

write(b"OK rbw credential pinentry ready\n")
for raw in sys.stdin.buffer:
    command, _, argument = raw.rstrip(b"\r\n").partition(b" ")
    if command == b"SETPROMPT":
        prompt = argument
        write(b"OK\n")
    elif command in {b"SETTITLE", b"SETDESC", b"SETERROR"}:
        write(b"OK\n")
    elif command == b"GETPIN":
        if prompt != b"Master Password":
            write(b"ERR 83886179 unexpected pinentry prompt\n")
            break
        try:
            secret = Path(os.environ["CREDENTIALS_DIRECTORY"], "rbw_master").read_bytes()
        except (KeyError, OSError):
            write(b"ERR 83886179 credential unavailable\n")
            break
        if not secret:
            write(b"ERR 83886179 empty credential\n")
            break
        encoded = b"".join(f"%{byte:02X}".encode() for byte in secret)
        write(b"D " + encoded + b"\nOK\n")
        break
    elif command == b"BYE":
        write(b"OK\n")
        break
    else:
        write(b"ERR 83886179 unsupported pinentry command\n")
        break
```

This is not a daemon. It is spawned only when rbw needs a master password, then exits.

### Service behavior

Use one system service for the stronger design:

```ini
[Unit]
Description=OpenHands worker with Vaultwarden-sourced Canvas key
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=10min
StartLimitBurst=2

[Service]
Type=simple
LoadCredentialEncrypted=rbw_master
Environment=HOME=/var/lib/openhands-vault
Environment=XDG_CONFIG_HOME=/var/lib/openhands-vault/config
Environment=XDG_CACHE_HOME=/var/lib/openhands-vault/cache
Environment=XDG_DATA_HOME=/var/lib/openhands-vault/data
Environment=XDG_RUNTIME_DIR=/run/openhands-vault
StateDirectory=openhands-vault
RuntimeDirectory=openhands-vault
StateDirectoryMode=0700
RuntimeDirectoryMode=0700
UMask=0077
ExecStart=/usr/local/libexec/openhands-vault-launcher
Restart=no
KillMode=control-group

[Install]
WantedBy=multi-user.target
```

The root-owned launcher must, without logging values or putting them in argv:

1. run `rbw sync` and require exit 0;
2. run `rbw get <exact-item-UUID>` and require one non-empty value;
3. run `rbw stop-agent` in a `finally` path;
4. delete `CREDENTIALS_DIRECTORY` and all rbw/bootstrap variables from the child environment;
5. set supplementary groups, GID, and UID for `agent`, with real/effective/saved IDs all changed;
6. call `execve()` directly with `LOCAL_BACKEND_API_KEY` in the environment mapping—not through `env KEY=value ...`, a shell command line, or a temporary file.

Add systemd sandboxing only after the required workspace/device/network write paths are known. Incorrect `ProtectSystem=`, `ProtectHome=`, or `ReadWritePaths=` settings can break an OpenHands worker; unresolved hardening is better than an untested template that prevents operation.

## Implementation plan and commands

All values in angle brackets are metadata/placeholders, never real secrets.

### 1. Verify WSL and package baseline

Ubuntu installed by current `wsl --install` uses systemd by default; otherwise set `[boot] systemd=true` and restart WSL ([Microsoft docs](https://github.com/MicrosoftDocs/WSL/blob/8842def77a852af26318b9ebec78063a94b068ed/WSL/wsl-config.md#L35-L45)). Confirm the intended isolation remains present:

```sh
systemctl is-system-running
systemd --version
rbw --version
apt-cache policy rbw systemd gnome-keyring libsecret-tools
grep -A3 -E '^\[(boot|automount|interop)\]' /etc/wsl.conf
systemd-creds has-tpm2
```

Expected WSL settings:

```ini
[boot]
systemd=true
[automount]
enabled=false
[interop]
enabled=false
appendWindowsPath=false
```

Remember: a Windows-side launch of the distribution is still needed after host reboot because systemd services do not keep/start the WSL instance by themselves ([Microsoft Learn](https://learn.microsoft.com/en-us/windows/wsl/systemd#how-does-enabling-systemd-affect-wsl-architecture)).

### 2. Install and pin rbw

Choose one and record it operationally:

```sh
# Ubuntu-supported build (currently 1.13.2-7):
sudo apt-get update
sudo apt-get install rbw pinentry-curses

# Or upstream 1.15.0 using Ubuntu's Rust toolchain:
cargo install --locked --version 1.15.0 rbw
```

If using a non-Ubuntu binary, place the exact reviewed binary in a root-owned path and verify its checksum/release provenance. Do not copy `rbw-pinentry-keyring`; the custom executable replaces it.

### 3. Create the encrypted master-password credential

System scope for the recommended service:

```sh
sudo -v
sudo install -d -m 0700 /etc/credstore.encrypted
systemd-ask-password 'Vaultwarden master password:' \
  | sudo systemd-creds encrypt --name=rbw_master - \
      /etc/credstore.encrypted/rbw_master
sudo chmod 0600 /etc/credstore.encrypted/rbw_master
```

The password crosses only the terminal-to-pipe-to-encrypt process path; it is not in shell history, argv, environment, or a plaintext disk file. `systemd-creds` supports stdin input and encrypted output files ([source](https://github.com/systemd/systemd/blob/b3d8fc43e9cb531d958c17ef2cd93b374bc14e8a/man/systemd-creds.xml#L124-L149)).

Minimal PoC user scope instead:

```sh
sudo loginctl enable-linger agent
sudo -u agent install -d -m 0700 /home/agent/.config/credstore.encrypted
sudo -u agent systemd-ask-password 'Vaultwarden master password:' \
  | sudo -u agent systemd-creds encrypt --user --name=rbw_master - \
      /home/agent/.config/credstore.encrypted/rbw_master
loginctl show-user agent -p Linger
```

Lingering starts the user's service manager at boot and keeps it after logouts ([loginctl 259.5 source](https://github.com/systemd/systemd/blob/b3d8fc43e9cb531d958c17ef2cd93b374bc14e8a/man/loginctl.xml)). This does not create a PAM password token and therefore does not unlock GNOME Keyring.

### 4. Enroll rbw interactively, then switch pinentry

For the recommended root-only profile, use the exact environment that the service unit will use:

```sh
sudo install -d -m 0700 \
  /var/lib/openhands-vault/{config,cache,data} /run/openhands-vault

sudo env HOME=/var/lib/openhands-vault \
  XDG_CONFIG_HOME=/var/lib/openhands-vault/config \
  XDG_CACHE_HOME=/var/lib/openhands-vault/cache \
  XDG_DATA_HOME=/var/lib/openhands-vault/data \
  XDG_RUNTIME_DIR=/run/openhands-vault \
  rbw config set email '<vault-account-email>'

sudo env HOME=/var/lib/openhands-vault \
  XDG_CONFIG_HOME=/var/lib/openhands-vault/config \
  XDG_CACHE_HOME=/var/lib/openhands-vault/cache \
  XDG_DATA_HOME=/var/lib/openhands-vault/data \
  XDG_RUNTIME_DIR=/run/openhands-vault \
  rbw config set base_url 'https://<vaultwarden-host>'

sudo env HOME=/var/lib/openhands-vault \
  XDG_CONFIG_HOME=/var/lib/openhands-vault/config \
  XDG_CACHE_HOME=/var/lib/openhands-vault/cache \
  XDG_DATA_HOME=/var/lib/openhands-vault/data \
  XDG_RUNTIME_DIR=/run/openhands-vault \
  rbw config set pinentry /usr/bin/pinentry-curses

# Operator-attended enrollment, including registration/2FA if requested:
sudo env HOME=/var/lib/openhands-vault \
  XDG_CONFIG_HOME=/var/lib/openhands-vault/config \
  XDG_CACHE_HOME=/var/lib/openhands-vault/cache \
  XDG_DATA_HOME=/var/lib/openhands-vault/data \
  XDG_RUNTIME_DIR=/run/openhands-vault \
  rbw sync

# After installing the root-owned reference pinentry:
sudo env HOME=/var/lib/openhands-vault \
  XDG_CONFIG_HOME=/var/lib/openhands-vault/config \
  XDG_CACHE_HOME=/var/lib/openhands-vault/cache \
  XDG_DATA_HOME=/var/lib/openhands-vault/data \
  XDG_RUNTIME_DIR=/run/openhands-vault \
  rbw config set pinentry /usr/local/libexec/rbw-pinentry-systemd-credential
```

Set a finite `lock_timeout`; do not attempt zero because rbw rejects it. A short timeout reduces decrypted-key residency but increases credential reads. Upstream defaults to one hour ([README](https://github.com/doy/rbw/blob/e673049e1fe58a1d266ce64722ea467e2edb9c2a/README.md#L80-L88)). The recommended launcher stops the agent immediately after retrieval, making the configured timeout a fallback rather than the main lifecycle control.

### 5. Install, enable, and start

```sh
sudo install -o root -g root -m 0755 \
  <reviewed-pinentry-file> \
  /usr/local/libexec/rbw-pinentry-systemd-credential
sudo install -o root -g root -m 0755 \
  <reviewed-launcher-file> \
  /usr/local/libexec/openhands-vault-launcher
sudo install -o root -g root -m 0644 \
  <reviewed-unit-file> \
  /etc/systemd/system/openhands-worker.service
sudo systemctl daemon-reload
sudo systemctl enable --now openhands-worker.service
```

Do not configure automatic auth retries. `Restart=no` plus a low start-rate limit prevents repeated bad-master/2FA attempts and makes authentication failures visible.

### 6. Verify without printing secrets

```sh
# Service and retrieval succeeded:
sudo systemctl --no-pager --full status openhands-worker.service
sudo journalctl -u openhands-worker.service -b --no-pager

# Worker is unprivileged:
pid=$(systemctl show -p MainPID --value openhands-worker.service)
test "$(awk '/^Uid:/{print $2}' "/proc/$pid/status")" = "$(id -u agent)"

# Master credential is not readable by agent:
sudo -u agent test ! -r \
  /run/credentials/openhands-worker.service/rbw_master

# Required key is present in the worker environment, without revealing it:
sudo tr '\0' '\n' < "/proc/$pid/environ" \
  | sed -n 's/^LOCAL_BACKEND_API_KEY=.*/LOCAL_BACKEND_API_KEY=present/p'

# Secret was not placed in the service definition or argv:
systemctl show openhands-worker.service -p Environment
ps -ww -p "$pid" -o args=

# Root-only rbw agent was stopped after handoff:
sudo env HOME=/var/lib/openhands-vault \
  XDG_CONFIG_HOME=/var/lib/openhands-vault/config \
  XDG_CACHE_HOME=/var/lib/openhands-vault/cache \
  XDG_DATA_HOME=/var/lib/openhands-vault/data \
  XDG_RUNTIME_DIR=/run/openhands-vault \
  rbw unlocked && exit 1 || true
```

Also perform controlled negative tests in a maintenance window: missing credential, expired/invalid master password, unreachable Vaultwarden, revoked refresh token, 2FA prompt, missing item UUID, duplicate/wrong item, empty item value, and launcher privilege-drop failure. Every case must leave the worker stopped and emit a non-secret diagnostic.

## Rotation and lifecycle

- **Canvas API key rotation:** update the existing Vaultwarden item, then restart the worker. The launcher runs `rbw sync` before `get`, so startup fails rather than using a stale cached value if Vaultwarden is unavailable. The old value remains in the old process environment until that process exits; a restart is the revocation boundary.
- **Vaultwarden master-password rotation:** atomically replace `/etc/credstore.encrypted/rbw_master` using a newly encrypted file, stop/purge the root-only rbw profile as required, perform one operator-attended sync if reauthentication/2FA is requested, then restart the worker. Never overwrite through a plaintext intermediate.
- **Reboot/WSL shutdown:** rbw's in-memory keys and all `/run` credentials disappear. The encrypted credential and root-only rbw cache persist in the Linux VHD. On next WSL start, systemd decrypts the credential and the service repeats sync/retrieval.
- **Decommission:** stop/disable the unit, `rbw purge` the root-only profile, remove its state/runtime directories and encrypted credential, revoke the Vaultwarden session/API key if applicable, and rotate the Canvas key. Removal of encrypted local files does not revoke already copied credentials.

## Unresolved deployment inputs

These must be fixed before turning the reference architecture into production files:

1. Exact Vaultwarden URL, deployed version, TLS trust chain, account email, KDF, and allowed 2FA method.
2. Exact rbw version/source and a passing integration test against the deployed Vaultwarden version. The Ubuntu package is 1.13.2; upstream is 1.15.0.
3. Exact Vaultwarden item UUID and field containing the Canvas key. Use a dedicated least-privilege vault account/organization collection if possible; do not select by a non-unique display name.
4. OpenHands worker executable, arguments, working directory, required PATH/locale/proxy variables, supplementary groups, device access, and writable workspace paths.
5. Whether a root-owned launcher is acceptable. If not, the PoC cannot isolate the vault master password from arbitrary code under `agent`; a separate privileged broker or external injector becomes necessary.
6. Actual WSL TPM2 exposure (`systemd-creds has-tpm2`) and whether an offline VHD/Windows-admin attacker is in scope.
7. The Windows-side mechanism that launches the WSL distribution after host boot. WSL systemd services do not themselves keep the instance alive.
8. Required availability policy: the recommendation fails closed when Vaultwarden cannot be synced. If cached-start behavior is required, define a maximum cache age and accept delayed rotation/revocation.
9. Canvas/OpenHands behavior around subprocess inheritance, crash dumps, telemetry, support bundles, and logs. Since the key must be in the Canvas environment, those paths need separate verification/redaction controls.

## Final recommendation

Adopt the root-owned systemd credential + narrow Assuan pinentry + one-shot root launcher that drops to `agent`; use the user-service version only to prove connectivity, and do not use GNOME Keyring as the unattended bootstrap for this locked, headless WSL account.
