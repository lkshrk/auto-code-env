# OpenHands Worker Multi-Architecture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Publish one pinned Ubuntu 26.04 worker filesystem as a multi-architecture OCI image and architecture-specific WSL artifacts, then make Windows import the verified artifact instead of rebuilding Ubuntu locally.

**Architecture:** runtimes/wsl/Containerfile creates one provisioned filesystem for linux/amd64 and linux/arm64, with thin oci and wsl targets. OCI starts Agent Canvas behind nginx; WSL carries systemd and WSL metadata but receives TLS and credentials only after import. Existing hardened provisioner remains the single build implementation and becomes architecture-aware.

**Tech Stack:** Ubuntu 26.04, Docker Buildx/BuildKit, Bash, PowerShell, WSL 2.7+, nginx, systemd, GitHub Actions, GHCR.

**Spec:** docs/superpowers/specs/2026-08-30-openhands-worker-multiarch-design.md

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

- [ ] Add failing fixture coverage for both Node archive names and both uv targets.
- [ ] Add failures for armv7l and for skipping WSL identity without image-build mode.
- [ ] Run bash runtimes/wsl/tests/provision.Tests.sh and confirm aarch64 fails because support is absent.
- [ ] Map architecture once:

~~~bash
case "$machine_arch" in
  x86_64|amd64) node_arch=x64; uv_target=x86_64-unknown-linux-gnu ;;
  aarch64|arm64) node_arch=arm64; uv_target=aarch64-unknown-linux-gnu ;;
  *) fail "unsupported architecture: $machine_arch" ;;
esac
~~~

- [ ] OPENHANDS_IMAGE_BUILD=1 skips only WSL_DISTRO_NAME enforcement and wsl.conf installation. All root, checksum, ownership, path, and version checks remain.
- [ ] Run provision fixtures, bash -n, and ShellCheck.
- [ ] Commit: feat(wsl): support amd64 and arm64 toolchains

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

- [ ] Write runtime.Tests.sh first. Cover missing/empty API key, missing TLS files, file-secret loading without output, Canvas run as agent with --public, nginx proxy to 127.0.0.1:8000/listen 443, systemd User=agent and LoadCredential, and WSL default UID/name.
- [ ] Run runtime.Tests.sh and confirm missing files cause RED.
- [ ] Implement entrypoint: require LOCAL_BACKEND_API_KEY or LOCAL_BACKEND_API_KEY_FILE, validate TLS files, start Canvas through absolute runuser path, start nginx, forward INT/TERM, exit when either child exits.
- [ ] Implement systemd unit with credential read from CREDENTIALS_DIRECTORY; embed no secret.
- [ ] Implement Containerfile: pinned Ubuntu digest, provision with OPENHANDS_IMAGE_BUILD=1, nginx install, exact Agent Server/Automation uv-cache warm, root-owned runtime assets, OCI entrypoint/EXPOSE 443, WSL config/distribution/unit overlay.
- [ ] Run runtime tests, bash -n, ShellCheck, and docker buildx build --check.
- [ ] Commit: feat(worker): add OCI and WSL runtime targets

### Task 3: Add multi-platform build/export verification

**Files:**
- Create: runtimes/wsl/docker-bake.hcl
- Create: runtimes/wsl/build-wsl.sh
- Create: runtimes/wsl/tests/image.Tests.sh

**Consumes:** Task 2 targets.
**Produces:** image, wsl-amd64, wsl-arm64 targets and deterministic named artifacts.

- [ ] Write failing contract tests for exact platforms, immutable image name, required version, output names, tar export, checksum output, unsupported platform refusal, and no overwrite.
- [ ] Run image.Tests.sh and confirm RED.
- [ ] Add Bake targets: image -> oci on amd64+arm64; wsl-amd64 -> wsl on amd64; wsl-arm64 -> wsl on arm64.
- [ ] Implement build-wsl.sh VERSION ARCH OUTPUT_DIR using one platform and type=tar. Emit .wsl plus checksum fragment. Reject empty version, unsupported arch, or existing output.
- [ ] Run image tests, bash -n, and ShellCheck.
- [ ] Build/load amd64 OCI and smoke exact versions, UID/GID, no sudo, directories, nginx -t.
- [ ] Export arm64 WSL file and inspect tar for arm64 Node/uv paths plus WSL config.
- [ ] Commit: build(worker): produce OCI and WSL artifacts

### Task 4: Import verified WSL artifacts on Windows

**Files:**
- Modify: runtimes/wsl/install.ps1
- Modify: runtimes/wsl/tests/install.Tests.ps1

**Consumes:** Task 3 .wsl plus SHA-256.
**Produces:** local/HTTPS artifact resolution and verified from-file install.

- [ ] Add RED tests for AMD64/ARM64 mapping; exactly one local ImagePath or HTTPS ImageUri; mandatory 64-hex SHA; hash-before-install; exact --install --from-file call; wrong hash/HTTP URI/unsupported arch/import failure/missing registration; existing distro no-op without download; no online Ubuntu listing or dynamic asset transfer.
- [ ] Run PowerShell tests and confirm Store-install expectations fail.
- [ ] Add CmdletBinding param block while preserving DistroName and host configuration.
- [ ] Resolve/download into installer-owned temp directory, verify Get-FileHash SHA256, then invoke wsl --install --from-file <path> --name <name> --no-launch.
- [ ] Never modify existing target. Remove top-level Stage 4 dynamic provisioning after tests prove import parity.
- [ ] Run PowerShell tests and parser.
- [ ] Commit: feat(wsl): import verified worker images

### Task 5: Add isolated worker CI/release

**Files:**
- Create: .github/workflows/validate-openhands-worker.yaml
- Create: .github/workflows/release-openhands-worker.yaml
- Modify: runtimes/wsl/tests/image.Tests.sh

**Consumes:** Tasks 1-4 tests and build targets.
**Produces:** PR validation, multi-arch GHCR image, WSL files, checksums, SBOM, provenance.

- [ ] Add RED workflow assertions: path filters, exact platforms, immutable tag, filenames, checksum upload, packages:write, release-only contents:write, SBOM/provenance.
- [ ] Implement validation on WSL/worker paths only.
- [ ] Implement release only for openhands-worker-v*: strip version; publish OCI multi-platform version tag; export both WSL files; combine checksums.txt; create/upload GitHub release. Do not touch chart workflows.
- [ ] Run image tests and git diff --check.
- [ ] Commit: ci(worker): validate and publish multi-arch artifacts

### Task 6: Document and verify delivery

**Files:**
- Modify: runtimes/wsl/README.md
- Modify: runtimes/wsl/tests/image.Tests.sh

- [ ] Add RED docs assertions for OCI use, WSL local/HTTPS params, SHA verification, persistent mounts, TLS/API key inputs, architectures, update flow, existing-distro no-op, and missing automated WSL state migration.
- [ ] Update README from Store/dynamic creation to versioned artifacts. Keep host overlay and security ownership explicit.
- [ ] State arm64 build proof is not native Windows-on-ARM runtime proof; do not publish WSL release before real import verification.
- [ ] Run all shell tests, PowerShell tests, ShellCheck, docker amd64 build/smoke, both WSL tar inspections, and git diff --check.
- [ ] Commit: docs(worker): explain multi-arch delivery

