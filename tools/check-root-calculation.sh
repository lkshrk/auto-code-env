#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && until [ -e .git ]; do [ "$PWD" = / ] && exit 1; cd ..; done && pwd)
cd "$repo_root"

# Counting "../.." breaks silently whenever a file moves, which it has three times.
offenders=$(grep -rnE '(repo_root|repository_root)=\$\(cd.*(\.\./)+' \
    --include='*.sh' --include='*-overlay' \
    coder openhands shared tools 2>/dev/null | grep -v '/upstream/' || true)

if [ -n "$offenders" ]; then
    printf '%s\n' 'these compute the repository root by counting levels, which a move breaks silently:' >&2
    printf '%s\n' "$offenders" >&2
    printf '%s\n' 'walk up to the .git marker instead; see tools/check-root-calculation.sh' >&2
    exit 1
fi
echo 'PASS: no script locates the repository root by counting directory levels'
