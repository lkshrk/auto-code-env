# Chart final recovery report

## Changes

- Normalize every packaged chart entry mtime, including symlinks, to the pinned upstream commit timestamp before Helm packaging in validation and release workflows.
- Rebuild the validation chart after deliberately changing source mtimes; package bytes and SHA-256 must match.
- Release recovery now validates `tagName` and boolean `isDraft`; tag identity remains owned by `ensure_tag`, so GitHub's `targetCommitish` no longer blocks a valid resumed release.
- `pull_and_compare` now cleans its temporary directory on success, mismatch, missing package, and pull failure.
- Validate chart scripts with ShellCheck.

## Regression coverage

- Contract test accepts an existing draft/published GitHub release whose `targetCommitish` is `main`, and rejects a mismatched tag name.
- Contract test asserts temporary Helm pull destinations are absent after mismatch and no-package failures.
- Workflow validation packages twice from distinct source mtimes and compares both bytes and SHA-256.

## Validation

- `bash .github/scripts/release-openhands-chart.Tests.sh`
- `shellcheck .github/scripts/release-openhands-chart.sh .github/scripts/release-openhands-chart.Tests.sh`
- `actionlint .github/workflows/release-openhands-chart.yaml .github/workflows/validate-openhands-chart.yaml`
- `git diff --check -- .github`
- Local Helm reproducibility smoke: same SHA-256 after two distinct source-mtime inputs.
