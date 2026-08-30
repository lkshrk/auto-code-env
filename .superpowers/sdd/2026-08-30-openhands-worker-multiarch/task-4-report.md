# Task 4 report

## Result

Implemented verified architecture-specific WSL image imports.

## TDD

- RED: `install.Tests.ps1` failed because `Get-WslArtifactArchitecture` was absent.
- GREEN: tests pass after adding artifact validation and `--from-file` import.

## Validation

- `docker run --rm -v "$PWD:/workspace" -w /workspace mcr.microsoft.com/powershell:7.5-ubuntu-24.04@sha256:042240d57ec9e47e511033b92625a8d95875ee5860af3015992c248b58a8be81 pwsh -NoProfile -File runtimes/wsl/tests/install.Tests.ps1`
- Pinned-container PowerShell parser check for `runtimes/wsl/install.ps1`.
- `git diff --check`.

## Scope

- Added `AMD64`/`ARM64` artifact selection, strict local-or-HTTPS source handling, SHA-256 verification, temp download cleanup, and exact `wsl --install --from-file ... --name ... --no-launch` import.
- Existing exact distributions return after `--list --quiet`, before image validation or download.
- Removed top-level online-list and Stage 4 dynamic provisioning execution; mirrored-networking and new-import identity checks remain.

## Limitations

- Validation uses the pinned Linux PowerShell container; no Windows host or real WSL import was available.

## Round 1 review fixes

- Local and HTTPS artifacts are both staged into an installer-owned temporary directory.
- The staged image stays open with read-only sharing while its SHA-256 is calculated and through WSL import; cleanup disposes the handle before removing only the owned directory.
- WOW64 architecture now takes precedence via `PROCESSOR_ARCHITEW6432`, then process architecture, then `RuntimeInformation`.
- Tests cover staged-path lifecycle, Windows-only write denial, cleanup on failed hashing, and no import after a hash mismatch.
