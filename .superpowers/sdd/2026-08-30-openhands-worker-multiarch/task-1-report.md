# Task 1 report — architecture-aware WSL provisioner

## Result

- Added one architecture mapping for `x86_64|amd64` -> Node `x64`, uv `x86_64-unknown-linux-gnu`; and `aarch64|arm64` -> Node `arm64`, uv `aarch64-unknown-linux-gnu`.
- Unsupported architectures fail with `unsupported architecture: <machine_arch>`.
- `OPENHANDS_IMAGE_BUILD=1` skips only WSL identity enforcement and `/etc/wsl.conf` installation.
- Root, asset, account, ownership, checksum, archive, path, package, and version validation remains on the image-build path.

## TDD evidence

1. Added fixtures for both Node archive roots and both uv targets, converted the existing aarch64 rejection fixture into an arm64 installation test, and added armv7l, absent WSL identity, and image-build fixtures.
2. RED: `bash runtimes/wsl/tests/provision.Tests.sh` exited 1 at `unsupported architecture: only x86_64 is supported` for the new aarch64 fixture.
3. Implemented the minimum mapping and image-build conditions in `runtimes/wsl/provision.sh`.
4. GREEN: the full fixture command exits 0.

## Validation

- `bash runtimes/wsl/tests/provision.Tests.sh` — pass.
- `bash -n runtimes/wsl/provision.sh`
- `bash -n runtimes/wsl/tests/provision.Tests.sh`
- `shellcheck runtimes/wsl/provision.sh runtimes/wsl/tests/provision.Tests.sh`
- `git diff --check -- runtimes/wsl/provision.sh runtimes/wsl/tests/provision.Tests.sh`

## Review

- Checked that architecture values flow through the Node archive/directory and uv archive/target validation instead of duplicating branching at consumers.
- Checked image-build bypass is exact-value only (`OPENHANDS_IMAGE_BUILD=1`) and wraps only the two WSL-specific operations.

## Commit

`a6e10c095803ccf42d2393822ebb709c2adb54da` — `feat(wsl): support amd64 and arm64 toolchains`

## Limitation

The arm64 coverage uses the existing mocked download fixture. Optional real toolchain coverage remains gated by `RUN_WSL_REAL_TOOLCHAIN_TESTS=1` and currently exercises amd64 only.

## Compatibility fix — dpkg excluded documentation

Ubuntu 26.04 package exclusions can make `dpkg --verify` report only `missing` records below `/usr/share/man/` and `/usr/share/doc/`, even when the package binaries are intact. `assert_package_files` now accepts precisely those records and rejects every other line or nonzero command result; existing package status, binary ownership, root-file, and version checks remain unchanged.

TDD evidence: before the filter, a fixture `missing /usr/share/man/man1/rbw.1.gz` failed with `invalid rbw package files`; after the filter, rbw and python documentation/man records pass. The fixture rejects `/usr/bin` missing records, `??5??????` altered-file records, `/etc` configuration records, unexpected records, and an allowed-looking record followed by an unexpected line. Existing fixtures retain nonzero `dpkg --verify` coverage for both packages.

Validation: focused package-boundary fixture passes; `bash -n` passes for both scripts; ShellCheck and `git diff --check` pass. The full `bash runtimes/wsl/tests/provision.Tests.sh` command was invoked, but this terminal terminates foreground commands after 30 seconds before the suite returns an exit status.

Validation update: the controller’s persistent `bash runtimes/wsl/tests/provision.Tests.sh` run reached `EXIT0` after commit `30127ca`; `bash -n` and ShellCheck were already green.

Final status fix: Ubuntu 26.04 reports `python3-minimal` as `ii ` (including the blank error-state character). The fixture now reproduces that exact status; RED failed with `invalid python3-minimal package` until the provisioner required `ii ` explicitly. Commit `0b95999` passed the persistent full fixture (`STATUS=0`), `bash -n`, and ShellCheck.

## Python standard-library completion

Native arm64 image build exposed that `python3-minimal` provides `/usr/bin/python3` but not the complete standard library required by the generated rbw pinentry: `uvx` failed with `ModuleNotFoundError: No module named queue`. Ubuntu 26.04 verification confirmed `python3` provides `queue`, while `python3-minimal` owns `/usr/bin/python3`.

`29b80e8` installs `python3` alongside `python3-minimal`, requires both packages to be exactly installed (`ii `), retains the `python3-minimal` ownership check for `/usr/bin/python3`, and runs `/usr/bin/python3 -c 'import queue'` before creating pinentry. This completion adds `dpkg --verify python3` as a second fail-closed package check.

Fixture coverage now builds Ubuntu 26.04 with full `python3`, expects the exact apt command to include both packages, verifies `python3` package files, rejects a corrupted `python3` package, and replaces the Python entry point with a recorder that fails only `-c 'import queue'`. Provisioning fails after exactly that one invocation and before pinentry is created.

Validation: `bash runtimes/wsl/tests/provision.Tests.sh` exited `0` in a persistent tty run; `bash -n runtimes/wsl/provision.sh`; `bash -n runtimes/wsl/tests/provision.Tests.sh`; `shellcheck runtimes/wsl/provision.sh runtimes/wsl/tests/provision.Tests.sh`; and `git diff --check -- runtimes/wsl/provision.sh runtimes/wsl/tests/provision.Tests.sh` all passed.

## Python import isolation

The standard-library proof now invokes Python as `/usr/bin/python3 -I -c 'import queue'`. `-I` prevents a `queue.py` in the provisioner's current directory from spoofing a successful standard-library import. The failure recorder requires the exact argument sequence `-I:-c:import queue`; a cwd-shadow fixture writes a failing `queue.py` and proves provisioning still succeeds. Focused Ubuntu 26.04 fixture execution with that shadow file passed, as did a persistent full fixture run (`EXIT=0`, about 49 seconds), `bash -n`, ShellCheck, and `git diff --check`.
