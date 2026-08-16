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
for path in README.md image/Containerfile image/.env.example coder/templates/common.tf docs/secrets-checklist.md; do
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

# 4. No hardcoded secrets in the Containerfile or the sample env file.
# .env.example's secret-key lines must stay empty (KEY=) - a filled-in
# value there means a real credential almost got committed.
if grep -qE '(ghp_|gho_|github_pat_|sk-ant-|sk-or-v1-)' image/Containerfile image/.env.example; then
  echo "FAIL: a real credential pattern was found in image/Containerfile or image/.env.example"
  fail=1
else
  echo "PASS: no obvious credential leakage in image/Containerfile or image/.env.example"
fi

for key in HERMES_CUSTOM_API_AI_H_CLOUD_LAN_API_KEY OPENROUTER_API_KEY SIGNAL_ACCOUNT \
           GITHUB_TOKEN CODER_SESSION_TOKEN OPENVIKING_API_KEY; do
  if grep -qE "^${key}=.+" image/.env.example; then
    echo "FAIL: image/.env.example has a non-empty value for secret key ${key}"
    fail=1
  fi
done
echo "PASS: all secret keys in image/.env.example are empty placeholders"

if [ "$fail" -ne 0 ]; then
  echo
  echo "verify.sh: one or more checks failed"
  exit 1
fi

echo
echo "verify.sh: all checks passed"
