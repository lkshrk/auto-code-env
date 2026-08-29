# WSL Bootstrap Stage 5A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Install pinned Linux-native Node.js 24 LTS and uv/uvx toolchain for later OpenHands and CLI packages.

**Architecture:** Extend root provisioner with exact upstream release downloads and published SHA-256 verification. Install immutable versioned payload under `/opt/openhands` and root-owned entry points under `/usr/local/bin`; fail closed on collisions.

**Tech Stack:** Ubuntu 26.04 apt, Node.js official dist, Astral uv GitHub release assets.

**Spec:** `runtimes/wsl/README.md`

## Global Constraints

- Pins: Node `24.20.0`; npm `11.19.0`; uv `0.12.7`.
- Support target `x86_64` only in this stage; fail other architectures.
- Verify Node `SHASUMS256.txt` and uv asset `.sha256` over HTTPS before install.
- Install Node versioned under `/opt/openhands/node-v24.20.0-linux-x64`; uv/uvx root-owned 0755 under `/usr/local/bin`.
- Never overwrite foreign files/symlinks; exact existing install is idempotent.
- Install only required OS packages: ca-certificates, curl, xz-utils.
- Keep agent unprivileged; no npm packages/OpenHands/CLIs/services/secrets yet.

---

### Task 1: Pinned Node and uv toolchain

**Files:**
- Modify: `runtimes/wsl/provision.sh`
- Modify: `runtimes/wsl/tests/provision.Tests.sh`
- Modify: `runtimes/wsl/README.md`

- [ ] Write failing Ubuntu 26.04 behavior tests for exact versions and rerun.
- [ ] Implement HTTPS download, checksum, safe extraction/install, collision checks.
- [ ] Test corrupted/preexisting collision failure without overwrite.
- [ ] Verify exact node/npm/npx/uv/uvx versions and ownership/modes.
- [ ] Run Ubuntu suite, Bash syntax, existing PowerShell suite/parser, scoped whitespace.
- [ ] Target run through installer, verify versions, worker stopped, rerun idempotent.
