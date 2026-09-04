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

Non-v2 markers are not trusted or classified. An installed tree is canonically
hashed and compared with the verified staged digest first; only equality
permits an atomic root-owned `0644` marker replacement. Exact-v2 markers must
carry the staged digest. Mismatched trees and interrupted replacements retain
their original marker.

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
- Injected tar-list, link-find, digest-tar, and digest-SHA failures all stop
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

## Review fix round

### Rulings

Xattrs, ACLs, and hardlink topology remain outside the integrity contract. The
replaced detailed manifest covered paths, content, mode, numeric ownership,
and symlink targets only; this round adds no tar metadata flags or link checks.

### RED

After changing only the fixture contract, the suite exited 1 with
`foreign Node.js manifest`. The equal installed tree carried an arbitrary
non-v2 marker, proving the first implementation incorrectly classified marker
content before verifying the tree.

### Fix

- Exact-v2 marker grammar must carry the verified staged digest. Every other
  root-owned regular `0644` marker is treated as opaque and migrates only after
  canonical installed/staged digest equality.
- The atomic replacement temp now lives under the registered Node stage root,
  outside `NODE_HOME` but on the same filesystem. A stale external crash temp
  does not affect reruns; a stale internal temp from the prior implementation
  is included in the digest and rejected.
- Safety-scan and link-enumeration `find` failures have distinct injectors that
  match their actual argument vectors. Both emit valid-looking output, return
  nonzero, stop before commit, and clean registered staging.
- Marker fixtures construct canonical expected bytes and use `cmp`; they cover
  the required final newline, arbitrary non-v2 content, a real multiline
  D/L/F marker, mismatched non-v2 preservation, and exact-v2 digest mismatch.

### GREEN

- `bash runtimes/wsl/tests/provision.Tests.sh` — exit 0 in 33 seconds.
- `bash -n runtimes/wsl/provision.sh runtimes/wsl/tests/provision.Tests.sh`
  — exit 0.
- `shellcheck runtimes/wsl/provision.sh runtimes/wsl/tests/provision.Tests.sh`
  — exit 0.
- `git diff --check` — exit 0.
- Informational fixture rerun: 486ms and 38 tracked logical invocations
  (`tar=4`, `sha256sum=4`, `find=8`, `stat=22`); no threshold asserted.

### SHA

`032a48e2cb3d5c5c36485c8f7ee9f556e073a49f`

### Gap

The target WSL ext4 rerun and 4,800-file release-tree benchmark remain later
work. No target timing claim is made from the small fixture.

## Canonical marker byte fix

### RED

The fixture copied a valid v2 marker, removed only its final newline, reran the
provisioner, and compared against the original bytes. The suite exited 1 at
that `cmp`: `mapfile -t` had accepted the canonical-looking line and skipped
migration.

### Fix

After extracting the candidate digest, `node_manifest_digest` now reconstructs
`v2 sha256 <digest>\n` with `printf` and compares the complete marker file
byte-for-byte before returning the digest. A correct digest without the final
newline is therefore non-v2; digest-equal trees migrate it through the existing
atomic replacement path. Existing mismatch behavior is unchanged.

### GREEN

- `bash runtimes/wsl/tests/provision.Tests.sh` — exit 0 in 35 seconds.
- `bash -n runtimes/wsl/provision.sh runtimes/wsl/tests/provision.Tests.sh`
  — exit 0.
- `shellcheck runtimes/wsl/provision.sh runtimes/wsl/tests/provision.Tests.sh`
  — exit 0.
- `git diff --check` — exit 0.
- Informational fixture rerun: 433ms and 38 tracked logical invocations
  (`tar=4`, `sha256sum=4`, `find=8`, `stat=22`); no threshold asserted.

### SHA

`8ec40ba741b6c6c3bbbd24fdecf9f47468c3adbf`
