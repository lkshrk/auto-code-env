# Final multi-architecture fix wave

## Changes

- Agent Canvas ingress is exact-source patched to bind `127.0.0.1`; the patch rejects drift and repeat application.
- The smoke image runs the patched installed ingress and proves loopback connects while every container non-loopback IPv4 address is rejected.
- Worker validation has a dedicated amd64 deterministic-check job for provision, runtime, image, PowerShell, and ShellCheck gates; PowerShell uses digest-pinned `mcr.microsoft.com/powershell`.
- Chart publication is resumable. It creates or verifies the tag and draft first, compares any existing OCI package byte-for-byte, rechecks after an ambiguous push failure, and never rolls back a tag or release merely because `helm push` returned nonzero.
- Chart mock contract tests cover absent, matching existing, mismatched existing, denied registry, ambiguous push recovery, and matching published release paths.
- Removed invalid `.gitmodules` branch hint; gitlink remains authority.

## Validation

- `node --check runtimes/wsl/runtime/patch-agent-canvas-automation.mjs`
- `node --check runtimes/wsl/tests/agent-canvas-ingress-smoke.mjs`
- `bash .github/scripts/release-openhands-chart.Tests.sh`
- `bash runtimes/wsl/tests/runtime.Tests.sh`
- `bash runtimes/wsl/tests/image.Tests.sh`
- `docker buildx build --file runtimes/wsl/Containerfile --platform linux/arm64 --target smoke --output type=cacheonly .`
- `docker run --rm --platform linux/amd64 --volume "$PWD:/src:ro" --workdir /src mcr.microsoft.com/powershell@sha256:c2bee73acbaa53e9209daab8075b5d234f0f04e6824e7b6f7bf7dde1ba5b772b pwsh -NoProfile -File runtimes/wsl/tests/install.Tests.ps1`
- `actionlint .github/workflows/release-openhands-chart.yaml .github/workflows/validate-openhands-chart.yaml .github/workflows/validate-openhands-worker.yaml`
- `yamllint .github/workflows/release-openhands-chart.yaml .github/workflows/validate-openhands-chart.yaml .github/workflows/validate-openhands-worker.yaml`
- `git diff --check`

Native amd64 smoke remains CI-only: this host is arm64 and the amd64 path uses unsupported Rosetta/container tar behavior. The new GitHub `ubuntu-24.04` check job owns that gate.
