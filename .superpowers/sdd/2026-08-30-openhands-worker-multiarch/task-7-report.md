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

## Remaining gates

Native amd64 CI, completed native arm64 CI, both release-artifact tar
inspections, and real Windows import remain required before publication.
