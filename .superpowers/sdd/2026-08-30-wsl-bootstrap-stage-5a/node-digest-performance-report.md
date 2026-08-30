# Node digest performance report

## Change

Replaced the per-entry Node manifest with a root-owned one-line
`v2 sha256 <digest>` marker. The digest is a clean-environment,
pipefail-protected canonical GNU tar stream hashed by `/usr/bin/sha256sum`.
It sorts paths, normalizes timestamps, retains modes and numeric ownership,
records symlink targets and file content, and excludes only the root marker.

The 39-line per-file generator was deleted in full. The production diff
deletes 46 lines total; no per-file `stat`, `sort`, or `sha256sum` loop remains.
The remaining tree security scan is one `find`, plus the existing bounded
symlink-target checks.

Legacy multiline markers are not trusted. An installed tree is canonically
hashed and compared with the verified staged digest first; only equality
permits an atomic root-owned `0644` marker replacement. Foreign or mismatched
markers remain unchanged, including when replacement is interrupted.

## RED

Before production changes, `bash runtimes/wsl/tests/provision.Tests.sh`
exited 1 at the new exact `v2 sha256 [0-9a-f]{64}` marker assertion. The old
implementation still emitted its multiline per-entry manifest.

## GREEN

- `bash runtimes/wsl/tests/provision.Tests.sh` — exit 0 in 33 seconds.
- `bash -n runtimes/wsl/provision.sh runtimes/wsl/tests/provision.Tests.sh`
  — exit 0.
- `shellcheck runtimes/wsl/provision.sh runtimes/wsl/tests/provision.Tests.sh`
  — exit 0.
- `git diff --check` — exit 0.
- Injected tar-list, safety-find, digest-tar, and digest-SHA failures all stop
  before commit and leave no staging directories.
- Fixtures cover content, safe mode, ownership, symlink target, added,
  missing, nested-marker, timestamp, foreign-marker, legacy migration, and
  interrupted atomic-migration behavior.

## Benchmark

The existing real-tree observation was 5,888 archive entries, 4,800 files,
about 21,000 spawned processes, and a 3m54s rerun. The replacement has no
per-entry process fan-out.

The informational fixture rerun measured 374ms and 38 tracked logical command
invocations: 4 canonical tar, 4 stdin SHA, 8 find, and 22 stat calls. The count
includes repeated Stage 5A validation phases and fixed security checks; it does
not scale one SHA/stat process per file. No wall-clock or process-count
threshold is asserted.

An independent canonical-tar property probe produced fixture SHA-256
`5f591248bccf88879fef4b8ec26d3ceba3cf1bf1d78a9a1a088b236d20c5bdfb`.
Separate extracts with different timestamps matched. Content, mode, numeric
owner, symlink target, added, missing, and nested-marker mutations changed the
digest; adding the root marker did not.

## SHA

`6cd4fe770a9ed58077124f89207d217653892b57`

## Gaps

- The fixture tree is intentionally small; its timing is structural evidence,
  not a forecast for the 4,800-file release tree.
- The official Node archive was not rerun on target WSL ext4 in this task.
  Target rerun timing and integrity validation remain the authoritative later
  benchmark.
