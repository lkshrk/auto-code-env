# Task 1 report — rbw credential pinentry

## RED

- Added fixture assertions for pinned `rbw`, its ownership/version, the installed
  pinentry protocol, rerun, collision rejection, and counterfeit package rejection.
- Before implementation, the fixture failed at `invalid rbw installation`.

## GREEN

- Commit: `be886a5f159e364b05eb49a22b2c66d1d6725dd4`
- Installs `rbw=1.13.2-7`; verifies dpkg status/version and `/usr/bin/rbw`
  package ownership before running it.
- Atomically installs root-owned mode-0755 Python stdlib pinentry. It returns the
  credential's exact bytes (including a final newline if present), percent-encoded,
  only for the exact `Master Password` prompt.

## Validation

- Passed: `bash -n runtimes/wsl/provision.sh runtimes/wsl/tests/provision.Tests.sh`
- Passed: `shellcheck runtimes/wsl/provision.sh runtimes/wsl/tests/provision.Tests.sh`
- Passed: `git diff --check`
- Passed focused fixture protocol/rerun, foreign destination, and counterfeit
  package checks.

## Gaps

- The full historical fixture suite exceeds this runner's 30-second command
  window and its background-process cleanup prevents collecting its final exit;
  it progressed through existing negative cases without a Stage 6A error.
- No real Ubuntu/WSL install or rerun was run here; that remains the target-stage
  validation.

## Fix round 1

- Commit: `88f012d34140f91bf52a41ed92c21da75a0802a1`
- `dpkg --verify rbw` now runs with the clean allowlisted environment and must
  succeed with no output before `/usr/bin/rbw` can execute.
- Atomic pinentry publication now detects a successful-returning `mv -n` race:
  a raced destination must be safe and byte-identical to staging; otherwise it
  fails and cleanup removes the staged file.
- Focused fixtures passed for dpkg discrepancy, nonzero verification, raced
  destination, normal protocol/rerun; Bash syntax, ShellCheck, and whitespace
  checks passed.
