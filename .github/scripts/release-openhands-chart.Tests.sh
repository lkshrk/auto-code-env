#!/usr/bin/env bash
# shellcheck disable=SC2016 # Literal workflow source patterns must not expand here.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
helper="$repo_root/.github/scripts/release-openhands-chart.sh"
workflow="$repo_root/.github/workflows/release-openhands-chart.yaml"
validation="$repo_root/.github/workflows/validate-openhands-chart.yaml"
test -x "$helper"
grep -F './.github/scripts/release-openhands-chart.sh' "$workflow" >/dev/null
grep -F '.github/scripts/release-openhands-chart.Tests.sh' "$validation" >/dev/null
grep -F '.github/scripts/release-openhands-chart.sh' "$validation" >/dev/null
grep -F 'shellcheck .github/scripts/release-openhands-chart.sh .github/scripts/release-openhands-chart.Tests.sh' "$validation" >/dev/null
test "$(grep -Fc 'git -C "$upstream" show -s --format=%ct HEAD' "$workflow")" = 1
test "$(grep -Fc 'find "$build/openhands-agent-canvas" -exec touch -h -d "@$epoch" {} +' "$workflow")" = 1
test "$(grep -Fc 'git -C "$upstream" show -s --format=%ct HEAD' "$validation")" = 1
test "$(grep -Fc 'find "$build/openhands-agent-canvas" -exec touch -h -d "@$epoch" {} +' "$validation")" = 2

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
bin="$test_root/bin"
mkdir "$bin"
printf package > "$test_root/package.tgz"

cat > "$bin/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case $1 in
  pull)
    state_file=${CHART_STATE:?}
    state=$(cat "$state_file")
    destination=${@: -1}
    printf '%s\n' "$destination" >> "$PULL_DESTINATIONS"
    case $state in
      absent) printf 'Error: chart: not found\n' >&2; exit 1 ;;
      matching) cp "$EXPECTED_PACKAGE" "$destination/openhands-agent-canvas-1.2.3.tgz" ;;
      mismatch) printf other > "$destination/openhands-agent-canvas-1.2.3.tgz" ;;
      no-package) : ;;
      denied) printf 'Error: unauthorized\n' >&2; exit 1 ;;
      ambiguous-before) printf 'Error: chart: not found\n' >&2; exit 1 ;;
      ambiguous-after) cp "$EXPECTED_PACKAGE" "$destination/openhands-agent-canvas-1.2.3.tgz" ;;
      *) exit 64 ;;
    esac
    ;;
  push)
    if test "$(cat "$CHART_STATE")" = ambiguous-before; then
      printf ambiguous-after > "$CHART_STATE"
      printf 'transport reset\n' >&2
      exit 1
    fi
    printf matching > "$CHART_STATE"
    ;;
  *) exit 64 ;;
esac
EOF
chmod 0755 "$bin/helm"

cat > "$bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case $1 in
  ls-remote) exit 2 ;;
  tag|push) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod 0755 "$bin/git"

cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2 $3" in
  'release view openhands-chart-v1.2.3')
    case ${RELEASE_STATE:?} in
      absent) printf 'release not found\n' >&2; exit 1 ;;
      draft) printf '{"isDraft":true,"tagName":"openhands-chart-v1.2.3","targetCommitish":"main"}\n' ;;
      published) printf '{"isDraft":false,"tagName":"openhands-chart-v1.2.3","targetCommitish":"main"}\n' ;;
      wrong-tag) printf '{"isDraft":true,"tagName":"other-tag"}\n' ;;
    esac
    ;;
  'release create openhands-chart-v1.2.3') printf created >> "$GH_LOG"; printf 'https://example.invalid/release\n' ;;
  'release edit openhands-chart-v1.2.3') printf published >> "$GH_LOG" ;;
  *) exit 64 ;;
esac
EOF
chmod 0755 "$bin/gh"

run_case() {
  local chart_state=$1 release_state=$2 expected=$3
  printf '%s' "$chart_state" > "$test_root/chart-state"
  : > "$test_root/gh.log"
  : > "$test_root/pull-destinations"
  PATH="$bin:$PATH" CHART_STATE="$test_root/chart-state" EXPECTED_PACKAGE="$test_root/package.tgz" GH_LOG="$test_root/gh.log" RELEASE_STATE="$release_state" PULL_DESTINATIONS="$test_root/pull-destinations" \
    PACKAGE="$test_root/package.tgz" OCI_REPOSITORY='oci://example.invalid/charts/openhands-agent-canvas' VERSION=1.2.3 RELEASE_TAG=openhands-chart-v1.2.3 \
    GITHUB_SHA=deadbeef TITLE=title NOTES_FILE="$test_root/notes" "$helper"
  grep -F "$expected" "$test_root/gh.log" >/dev/null
}

assert_pull_cleanup() {
  while IFS= read -r destination; do
    test ! -e "$destination"
  done < "$test_root/pull-destinations"
}

run_case absent absent 'release edit openhands-chart-v1.2.3'
run_case matching draft 'release edit openhands-chart-v1.2.3'
if run_case matching wrong-tag 'release edit openhands-chart-v1.2.3'; then exit 1; fi
if run_case mismatch draft 'release edit openhands-chart-v1.2.3'; then exit 1; fi
assert_pull_cleanup
if run_case no-package draft 'release edit openhands-chart-v1.2.3'; then exit 1; fi
assert_pull_cleanup
if run_case denied draft 'release edit openhands-chart-v1.2.3'; then exit 1; fi
run_case ambiguous-before absent 'release edit openhands-chart-v1.2.3'
run_case matching published 'release view openhands-chart-v1.2.3'
if grep -F 'release edit' "$test_root/gh.log"; then exit 1; fi
