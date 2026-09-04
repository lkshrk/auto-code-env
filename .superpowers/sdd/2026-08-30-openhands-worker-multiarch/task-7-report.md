# Task 7 report — worker delivery documentation

## RED

Added README contract assertions to `image.Tests.sh`. The first run failed:
`README must document "multi-architecture OCI image"`.

## Change

- Replaced stale dynamic WSL Store/Stage instructions with artifact import.
- Documents one multi-architecture OCI image, per-architecture WSL assets,
  checksums, HTTPS/local import parameters, architecture suffix enforcement,
  existing-distro no-op, and no automatic WSL state migration.
- Separates immutable image from Windows networking/firewall/DNS/TLS/credential
  overlay and Docker/Kubernetes runtime mounts/secret inputs.
- Documents WSL systemd credential activation, Omni `0.10.4` ownership and
  groups, update flow, temporary Canvas #16635 patch removal condition, and
  native CI/real-Windows-release gates.

## Verification

- `bash runtimes/wsl/tests/provision.Tests.sh` — pass.
- `bash runtimes/wsl/tests/runtime.Tests.sh` — pass.
- `bash runtimes/wsl/tests/image.Tests.sh` — pass.
- Pinned PowerShell container: `runtimes/wsl/tests/install.Tests.ps1` — pass.
- ShellCheck, `node --check`, actionlint, YAML parse, JSON parse, and
  `git diff --check` — pass.
- Native arm64 smoke was started and reached Omni convergence. Local Docker
  logging did not yield a completed status in this runner; native amd64 remains
  CI-only on this arm64 host. Do not treat either as release proof.

## Fix round 1

- Corrected local checksum verification to run from artifact directory.
- Clarified existing-distro no-op follows host mirrored-network reconciliation,
  which may still update `.wslconfig` and call `wsl --shutdown`.
- Documented exact TLS file ownership/modes and systemd credential source:
  `/etc/credstore/local_backend_api_key`, `root:root`, `0600`, loaded through
  `LoadCredential=local_backend_api_key`.
- Corrected workaround tracking to OpenHands issue #16217 and removal only
  after PR #16635 ships in compatible Agent Canvas.
- Strengthened README assertions for those exact contracts and publication
  gate wording.

## Remaining gates

Native arm64 post-Omni smoke now exits 0. Native amd64 CI, release-artifact tar
inspections in CI, real Windows import, and Windows-on-Arm runtime verification
remain required before publication.
