# OpenHands Worker Multi-Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Publish one pinned Ubuntu 26.04 worker filesystem as a multi-architecture OCI image and architecture-specific gzip-compressed WSL artifacts, then make Windows import the verified artifact instead of rebuilding Ubuntu locally.

**Architecture:** runtimes/wsl/Containerfile creates one provisioned filesystem for linux/amd64 and linux/arm64, with thin oci and wsl targets. OCI starts Agent Canvas behind nginx; WSL carries systemd and WSL metadata but receives TLS and credentials only after import. Existing hardened provisioner remains the single build implementation and becomes architecture-aware.

**Tech Stack:** Ubuntu 26.04, Docker Buildx/BuildKit, Bash, PowerShell, WSL 2.7+, nginx, systemd, GitHub Actions, GHCR.

**Spec:** docs/superpowers/specs/2026-08-30-openhands-worker-multiarch-design.md

## Current Status — 2026-09-04

Implementation and release automation are complete. Target-host rollout is not.

Delivered:

- PR #11 replaced the generic `dev-full`, Pilot, and Hermes image family with the canonical OpenHands worker and retained the isolated OpenHands chart pipeline.
- PR #12 flattened release inputs under one artifact root.
- PR #13 made draft release recovery use `gh release view`, which includes drafts.
- PR #14 changed `.wsl` output to deterministic gzip-compressed tar, matching Microsoft's custom distribution format and GitHub's strict 2 GiB asset limit.
- `openhands-chart-v1.16.0` is published as `oci://ghcr.io/lkshrk/charts/openhands-agent-canvas`.
- `openhands-worker-v0.1.3` is published as `ghcr.io/lkshrk/openhands-worker:0.1.3` plus amd64 and arm64 `.wsl` assets.

Verified release assets:

| Asset | Size | SHA-256 |
|---|---:|---|
| `openhands-worker-0.1.3-amd64.wsl` | 1,592,428,272 bytes | `f610c11e12f303602a492f262c04503f12c7cfc63f6ac9dc8cbc2df5973dd137` |
| `openhands-worker-0.1.3-arm64.wsl` | 1,549,616,246 bytes | `aa14cba95cfde154395daa9cfb695004bcf391a4e91b919e90106682b2416c8c` |

Release incident record:

| Tag | Result | Cause |
|---|---|---|
| `openhands-worker-v0.1.0` | failed before draft creation | Upload artifact paths produced a nested `release/` directory. |
| `openhands-worker-v0.1.1` | unpublished empty draft | REST release-by-tag lookup excluded drafts. |
| `openhands-worker-v0.1.2` | unpublished draft with checksum asset | Raw WSL tar files exceeded GitHub's 2 GiB asset limit. |
| `openhands-worker-v0.1.3` | published and verified | Gzip WSL assets, checksums, OCI manifest, SBOM, and provenance passed. |

Known deviation: `v0.1.3` was published before importing that exact artifact on
the Windows target. Treat target import and runtime verification in Tasks 8-10
as the remaining acceptance gate. The existing `openhands-worker` distro is a
provisional locally built instance and must not be overwritten automatically.

## Global Constraints

- Platforms: exactly linux/amd64 and linux/arm64.
- Base: ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b.
- OCI: ghcr.io/lkshrk/openhands-worker:<version>; never publish latest.
- WSL: openhands-worker-<version>-amd64.wsl and openhands-worker-<version>-arm64.wsl.
- agent stays UID/GID 1000, has no sudo, and runs all agent workloads.
- Only nginx TCP/443 is non-loopback-facing; Canvas stays on 127.0.0.1:8000.
- No private key, API key, rbw session, GitHub credential, Claude credential, or Codex credential enters Git or an image layer.
- Existing pins remain: Node 24.20.0, npm 11.19.0, uv 0.12.7, Canvas 1.16.0, Agent Server 1.44.0, Automation 1.9.0, Claude 2.1.251, Codex 0.151.0, Claude ACP 0.63.0, Codex ACP 1.1.7, rbw 1.13.2-7.
- Never replace, unregister, or migrate an existing WSL distribution automatically.
- Personal dotfiles are not build inputs.

---

### Task 1: Make provisioner architecture-aware

**Files:**
- Modify: runtimes/wsl/provision.sh
- Modify: runtimes/wsl/tests/provision.Tests.sh

**Produces:** one provisioner supporting x86_64/amd64 and aarch64/arm64 plus OPENHANDS_IMAGE_BUILD=1.

- [x] Add failing fixture coverage for both Node archive names and both uv targets.
- [x] Add failures for armv7l and for skipping WSL identity without image-build mode.
- [x] Run bash runtimes/wsl/tests/provision.Tests.sh and confirm aarch64 fails because support is absent.
- [x] Map architecture once:

~~~bash
case "$machine_arch" in
  x86_64|amd64) node_arch=x64; uv_target=x86_64-unknown-linux-gnu ;;
  aarch64|arm64) node_arch=arm64; uv_target=aarch64-unknown-linux-gnu ;;
  *) fail "unsupported architecture: $machine_arch" ;;
esac
~~~

- [x] OPENHANDS_IMAGE_BUILD=1 skips only WSL_DISTRO_NAME enforcement and wsl.conf installation. All root, checksum, ownership, path, and version checks remain.
- [x] Run provision fixtures, bash -n, and ShellCheck.
- [x] Commit: feat(wsl): support amd64 and arm64 toolchains

### Task 2: Add shared runtime and platform targets

**Files:**
- Create: runtimes/wsl/Containerfile
- Create: runtimes/wsl/runtime/container-entrypoint.sh
- Create: runtimes/wsl/runtime/agent-canvas.service
- Create: runtimes/wsl/runtime/nginx-site.conf
- Create: runtimes/wsl/wsl-distribution.conf
- Create: runtimes/wsl/tests/runtime.Tests.sh

**Consumes:** Task 1 image-build mode.
**Produces:** provisioned, oci, and wsl BuildKit targets.

- [x] Write runtime.Tests.sh first. Cover missing/empty API key, missing TLS files, file-secret loading without output, Canvas run as agent with --public, nginx proxy to 127.0.0.1:8000/listen 443, systemd User=agent and LoadCredential, and WSL default UID/name.
- [x] Run runtime.Tests.sh and confirm missing files cause RED.
- [x] Implement entrypoint: require LOCAL_BACKEND_API_KEY or LOCAL_BACKEND_API_KEY_FILE, validate TLS files, start Canvas through absolute runuser path, start nginx, forward INT/TERM, exit when either child exits.
- [x] Implement systemd unit with credential read from CREDENTIALS_DIRECTORY; embed no secret.
- [x] Implement Containerfile: pinned Ubuntu digest, provision with OPENHANDS_IMAGE_BUILD=1, nginx install, exact Agent Server/Automation uv-cache warm, root-owned runtime assets, OCI entrypoint/EXPOSE 443, WSL config/distribution/unit overlay.
- [x] Run runtime tests, bash -n, ShellCheck, and docker buildx build --check.
- [x] Commit: feat(worker): add OCI and WSL runtime targets

### Task 3: Add multi-platform build/export verification

**Files:**
- Create: runtimes/wsl/docker-bake.hcl
- Create: runtimes/wsl/build-wsl.sh
- Create: runtimes/wsl/tests/image.Tests.sh

**Consumes:** Task 2 targets.
**Produces:** image, wsl-amd64, wsl-arm64 targets and deterministic named artifacts.

- [x] Write failing contract tests for exact platforms, immutable image name, required version, output names, tar export, checksum output, unsupported platform refusal, and no overwrite.
- [x] Run image.Tests.sh and confirm RED.
- [x] Add Bake targets: image -> oci on amd64+arm64; wsl-amd64 -> wsl on amd64; wsl-arm64 -> wsl on arm64.
- [x] Implement build-wsl.sh VERSION ARCH OUTPUT_DIR using one platform and type=tar, then deterministic `gzip -9n`. Emit `.wsl` plus checksum fragment. Reject empty version, unsupported arch, existing output, or compressed output at GitHub's 2 GiB boundary.
- [x] Run image tests, bash -n, and ShellCheck.
- [x] Build/load amd64 OCI and smoke exact versions, UID/GID, no sudo, directories, nginx -t.
- [x] Export arm64 WSL file and inspect tar for arm64 Node/uv paths plus WSL config.
- [x] Commit: build(worker): produce OCI and WSL artifacts

### Task 4: Import verified WSL artifacts on Windows

**Files:**
- Modify: runtimes/wsl/install.ps1
- Modify: runtimes/wsl/tests/install.Tests.ps1

**Consumes:** Task 3 .wsl plus SHA-256.
**Produces:** local/HTTPS artifact resolution and verified from-file install.

- [x] Add RED tests for AMD64/ARM64 mapping; exactly one local ImagePath or HTTPS ImageUri; mandatory 64-hex SHA; hash-before-install; exact --install --from-file call; wrong hash/HTTP URI/unsupported arch/import failure/missing registration; existing distro no-op without download; no online Ubuntu listing or dynamic asset transfer.
- [x] Run PowerShell tests and confirm Store-install expectations fail.
- [x] Add CmdletBinding param block while preserving DistroName and host configuration.
- [x] Resolve/download into installer-owned temp directory, verify Get-FileHash SHA256, then invoke `wsl --install --from-file $image.Path --name $Name --no-launch`.
- [x] Never modify existing target. Remove top-level Stage 4 dynamic provisioning after tests prove import parity.
- [x] Run PowerShell tests and parser.
- [x] Commit: feat(wsl): import verified worker images

### Task 5: Add isolated worker CI/release

**Files:**
- Create: .github/workflows/validate-openhands-worker.yaml
- Create: .github/workflows/release-openhands-worker.yaml
- Modify: runtimes/wsl/tests/image.Tests.sh

**Consumes:** Tasks 1-4 tests and build targets.
**Produces:** PR validation, multi-arch GHCR image, WSL files, checksums, SBOM, provenance.

- [x] Add RED workflow assertions: path filters, exact platforms, immutable tag, filenames, checksum upload, packages:write, release-only contents:write, SBOM/provenance.
- [x] Implement validation on WSL/worker paths only.
- [x] Implement release only for openhands-worker-v*: strip version; publish OCI multi-platform version tag; export both WSL files; combine checksums.txt; create/upload GitHub release. Do not touch chart workflows.
- [x] Run image tests and git diff --check.
- [x] Commit: ci(worker): validate and publish multi-arch artifacts

### Task 6: Converge Ubuntu packages and agent tools with Omni 0.10.4

**Files:**
- Create: runtimes/wsl/omni/settings.json
- Modify: runtimes/wsl/provision.sh
- Modify: runtimes/wsl/tests/provision.Tests.sh
- Modify: runtimes/wsl/Containerfile
- Modify: runtimes/wsl/tests/runtime.Tests.sh

**Produces:** verified Omni bootstrap plus explicit root and agent convergence groups.

- [x] Add RED fixture coverage for pinned Omni amd64/arm64 archive/checksum selection, exact version, immutable root installation, config installation, root system group, no-script npm group, and Claude-only lifecycle group.
- [x] Pin Omni v0.10.4 and verify its release checksum before installing /usr/local/bin/omni.
- [x] Install only ca-certificates, curl, and xz-utils as pre-Omni bootstrap requirements; Omni root sync owns ca-certificates, curl, xz-utils, git, nginx, python3, and rbw=1.13.2-7.
- [x] Keep Node and uv binary bootstrap outside Omni; Omni does not provide those runtimes before its npm/python providers can run.
- [x] Run agent npm groups separately: ignore all lifecycle scripts for Canvas/ACP/Codex, then strict-allow only @anthropic-ai/claude-code for Claude Code.
- [x] Preserve all existing package, binary, ownership, exact-version, and runtime post-verification.
- [x] Remove duplicate nginx apt installation from Containerfile and verify Omni config is root-owned, non-writable, and contains no script provider or secret.
- [x] Run full provision/runtime suites, Bash/Node syntax, ShellCheck, BuildKit checks, and native arm64 smoke target.
- [x] Commit: feat(worker): converge tools with Omni

### Task 7: Document and verify delivery

**Files:**
- Modify: runtimes/wsl/README.md
- Modify: runtimes/wsl/tests/image.Tests.sh

- [x] Add RED docs assertions for OCI use, WSL local/HTTPS params, SHA verification, persistent mounts, TLS/API key inputs, architectures, update flow, existing-distro no-op, and missing automated WSL state migration.
- [x] Update README from Store/dynamic creation to versioned artifacts. Keep host overlay and security ownership explicit.
- [x] Document that arm64 Linux build proof is not Windows-on-ARM runtime proof and record the intended real-Windows-import publication gate. Current status records the `v0.1.3` gate deviation.
- [x] Run all shell tests, PowerShell tests, ShellCheck, docker amd64 build/smoke, both WSL tar inspections, and git diff --check.
- [x] Commit: docs(worker): explain multi-arch delivery

### Task 8: Replace the provisional Windows distro with the released artifact

**Files:** None. This is an operator-run Windows migration.

**Consumes:** `openhands-worker-v0.1.3` amd64 asset and SHA-256 above.
**Produces:** exact released worker registered as `openhands-worker` on `towerr`.

- [ ] Terminate the provisional distro and export it with `wsl --export openhands-worker "$env:USERPROFILE\WSL-Backups\openhands-worker-before-v0.1.3.vhdx" --vhd`.
- [ ] Verify backup exists, has nonzero length, and record its SHA-256 outside the distro.
- [ ] Copy the VHDX to `openhands-worker-before-v0.1.3-smoke.vhdx`, register that copy with `wsl --import-in-place openhands-worker-backup-smoke "$env:USERPROFILE\WSL-Backups\openhands-worker-before-v0.1.3-smoke.vhdx"`, and verify it boots as root with the expected Ubuntu identity, `/home/agent`, and systemd.
- [ ] Terminate and unregister only `openhands-worker-backup-smoke`, then verify the original backup still exists and retains its recorded SHA-256.
- [ ] Obtain explicit operator confirmation before `wsl --unregister openhands-worker`; unregistering permanently deletes the registered instance.
- [ ] Download `runtimes/wsl/install.ps1` from main commit `41babcfc977f05f3827fc2a20dafd588a7711301` and verify SHA-256 `1bfcc8189d97bb30fccb8e6846c9879874570046759485d87de6069dfcc86980`.
- [ ] Run installer with the v0.1.3 amd64 release URL and SHA-256 `f610c11e12f303602a492f262c04503f12c7cfc63f6ac9dc8cbc2df5973dd137`.
- [ ] Verify distro is WSL2, default user is `agent`, PID 1 is `systemd`, system state is running, `/mnt/c` is not mounted, Windows interop is absent, and four agent directories remain `agent:agent 0700`.
- [ ] Keep VHD backup until TLS, authentication, ACP execution, and workspace checks pass.

### Task 9: Apply host-specific DNS, TLS, secret, and firewall overlay

**Files:**
- External repository: `~/Dev/h-cloud/kubernetes/apps/cert-manager/cert-manager/app/towerr-openhands-worker-certificate.yaml`
- Runtime-only: `/etc/nginx/tls/tls.crt`, `/etc/nginx/tls/tls.key`, `/etc/credstore/local_backend_api_key`

**Produces:** `https://towerr.workers.ai.h-cloud.lan` with nginx as the only LAN-facing service.

- [ ] Push/reconcile h-cloud certificate commit `de77199d` and verify cert-manager produces secret `towerr-openhands-worker-tls` for `towerr.workers.ai.h-cloud.lan`.
- [ ] Choose and document the secure certificate/key export mechanism from Kubernetes to WSL; never commit or log the private key.
- [ ] Install certificate as `root:root 0644` and private key as `root:root 0600` under `/etc/nginx/tls`.
- [ ] Create `LOCAL_BACKEND_API_KEY` in a dedicated least-privilege Vaultwarden account/collection. Authenticate `rbw` only in the root-owned provisioning context, select the item by immutable UUID, and materialize `/etc/credstore/local_backend_api_key` as `root:root 0600` without logging it. Never expose the root Vaultwarden session to `agent`.
- [ ] Create DNS record `towerr.workers.ai.h-cloud.lan -> 172.16.20.195` and verify resolution from the Canvas/control-plane network.
- [ ] Obtain the exact trusted `RemoteAddresses` range from the operator before creating the Windows/Hyper-V inbound TCP/443 rule. Do not assume the entire `172.16.20.0/24` VLAN is trusted.
- [ ] Verify TCP/443 is reachable only from the approved range and TCP/8000 is unreachable from the LAN.

### Task 10: Authenticate agents and prove end-to-end operation

**Consumes:** Tasks 8-9 completed worker.
**Produces:** verified Canvas-to-ACP development workflow.

- [ ] Authenticate Claude Code and Codex as unprivileged `agent`; do not use PAYG provider keys for the PoC. Keep Vaultwarden/rbw root-only.
- [ ] Configure dedicated non-personal GitHub credentials limited to the required repository after choosing fine-grained PAT or dedicated SSH key.
- [ ] Enable/start `agent-canvas.service` and nginx only after TLS and backend credential files exist.
- [ ] Verify nginx serves the local-CA certificate for `towerr.workers.ai.h-cloud.lan` and proxies HTTPS/WebSockets successfully.
- [ ] Verify port 8000 listens only on `127.0.0.1`, API authentication rejects a missing/wrong key, and the valid key succeeds.
- [ ] Run one real Claude Code ACP task and one real Codex ACP task in `/home/agent/workspaces`.
- [ ] Clone one approved PoC repository using dedicated GitHub credentials and verify workspace ownership and write access.
- [ ] Measure required outbound endpoints before proposing egress controls; present practical WSL mirrored-networking options before changing policy.
- [ ] Record final Windows, WSL, TLS, firewall, authentication, ACP, and workspace evidence in this plan.
