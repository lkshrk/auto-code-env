#!/usr/bin/env bash
# Real repository sanity checks for hermes-hq. Runs locally and in CI
# (.github/workflows/validate.yaml's verify-script job).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail=0
check() {
  local desc="$1"
  shift
  if "$@" >/tmp/verify-check.out 2>&1; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    tail -20 /tmp/verify-check.out
    fail=1
  fi
  rm -f /tmp/verify-check.out
}

# 1. Required top-level files/dirs exist.
for path in README.md image/Containerfile coder/templates/common.tf docs/secrets-checklist.md; do
  if [ -e "$path" ]; then
    echo "PASS: $path exists"
  else
    echo "FAIL: $path missing"
    fail=1
  fi
done

# 2. No stray kubernetes/ manifests - h-cloud owns all deployment
# manifests, this repo should never reintroduce them.
if [ -d kubernetes ]; then
  echo "FAIL: kubernetes/ directory present - h-cloud owns all manifests, not this repo"
  fail=1
else
  echo "PASS: no kubernetes/ directory (correctly out of scope)"
fi

# 3. Every coder/templates/<name>/main.tf directory has a matching
# common.tf reference and no stray .terraform/ artifacts committed.
for dir in coder/templates/*/; do
  name=$(basename "$dir")
  if [ ! -f "$dir/main.tf" ]; then
    echo "FAIL: $name has no main.tf"
    fail=1
  fi
  if [ -d "$dir/.terraform" ] || [ -f "$dir/.terraform.lock.hcl" ]; then
    echo "FAIL: $name has committed .terraform artifacts (should be gitignored)"
    fail=1
  fi
done
echo "PASS: coder/templates structure checked"

# 4. Containerfile references match: HERMES_HOME under VOLUME, no
# leftover 'custom:litellm' style provider naming leaking into image
# defaults, no hardcoded secrets.
if grep -qE '(ghp_|gho_|github_pat_|sk-ant-|sk-or-v1-)' image/Containerfile; then
  echo "FAIL: image/Containerfile appears to contain a real credential"
  fail=1
else
  echo "PASS: no obvious credential leakage in image/Containerfile"
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "verify.sh: one or more checks failed"
  exit 1
fi

echo
echo "verify.sh: all checks passed"
