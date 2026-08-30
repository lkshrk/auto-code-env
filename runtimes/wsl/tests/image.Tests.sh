#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
bake_file="$repo_root/runtimes/wsl/docker-bake.hcl"
build_script="$repo_root/runtimes/wsl/build-wsl.sh"
validation_workflow="$repo_root/.github/workflows/validate-openhands-worker.yaml"
release_workflow="$repo_root/.github/workflows/release-openhands-worker.yaml"

for file in "$bake_file" "$build_script"; do
  test -f "$file"
done

for file in "$validation_workflow" "$release_workflow"; do
  test -f "$file"
done

python3 - "$validation_workflow" "$release_workflow" <<'PY'
import re
import sys
from pathlib import Path

validation, release = map(lambda path: Path(path).read_text(), sys.argv[1:])

def require(text, pattern, message):
    if not re.search(pattern, text, re.MULTILINE):
        raise SystemExit(message)

require(validation, r'pull_request:', 'validation must run on pull requests')
require(validation, r'runtimes/wsl/\*\*', 'validation must filter worker paths')
require(validation, r'ubuntu-24\.04-arm', 'validation must use native arm64 runner')
require(validation, r'linux/amd64', 'validation must validate amd64')
require(validation, r'linux/arm64', 'validation must validate arm64')
require(validation, r'type=cacheonly', 'validation must smoke cache-only build')
require(validation, r'build-wsl\.sh', 'validation must export WSL artifact')

require(release, r'openhands-worker-v\*', 'release must only run for worker tags')
require(release, r'packages:\s*write', 'release must publish OCI packages')
require(release, r'contents:\s*write', 'release must create GitHub release only in release job')
require(release, r'push-by-digest=true', 'release must push architecture images by digest')
require(release, r'--sbom=true', 'release must publish SBOM')
require(release, r'--provenance=mode=max', 'release must publish provenance')
require(release, r'openhands-worker-\$\{VERSION\}-\$\{\{ matrix\.arch \}\}\.wsl', 'release must preserve architecture WSL filenames')
require(release, r'checksums\.txt', 'release must publish combined checksums')
require(release, r'imagetools create', 'release must create immutable multi-arch manifest')
require(release, r'gh release create', 'release must publish WSL artifacts')
if ':latest' in release:
    raise SystemExit('release must not publish a mutable latest tag')
for workflow in (validation, release):
    for action in re.findall(r'^\s*uses:\s+[^@\s]+@([^\s#]+)', workflow, re.MULTILINE):
        if not re.fullmatch(r'[0-9a-f]{40}', action):
            raise SystemExit(f'action ref must be immutable: {action}')
PY

bake_json=$(VERSION=1.2.3 docker buildx bake -f "$bake_file" --print image wsl-amd64 wsl-arm64)
printf '%s' "$bake_json" | jq -e '
  .target.image.tags == ["ghcr.io/lkshrk/openhands-worker:1.2.3"] and
  .target.image.target == "oci" and
  .target.image.platforms == ["linux/amd64", "linux/arm64"] and
  .target["wsl-amd64"].target == "wsl" and
  .target["wsl-amd64"].platforms == ["linux/amd64"] and
  .target["wsl-arm64"].target == "wsl" and
  .target["wsl-arm64"].platforms == ["linux/arm64"]
' >/dev/null

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
fake_bin="$test_root/bin"
mkdir "$fake_bin"
cat > "$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$DOCKER_LOG"
for argument; do
  case $argument in
    *type=tar,dest=*) printf artifact > "${argument#*type=tar,dest=}" ;;
  esac
done
if test -n "${CHECKSUM_COLLISION:-}"; then
  destination=${argument#*type=tar,dest=}
  artifact_name=${destination##*/.}
  artifact_name=${artifact_name%.*}
  printf collision > "${destination%/*}/${artifact_name}.sha256"
fi
EOF
chmod 0755 "$fake_bin/docker"
cat > "$fake_bin/ln" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
/bin/ln "$@"
if test -n "${CHECKSUM_INTERRUPT:-}"; then
  calls_file=${LN_CALLS:?}
  calls=$(cat "$calls_file" 2>/dev/null || printf 0)
  calls=$((calls + 1))
  printf '%s\n' "$calls" > "$calls_file"
  if test "$calls" = 2; then kill -TERM "$PPID"; fi
fi
EOF
chmod 0755 "$fake_bin/ln"

if "$build_script" '' amd64 "$test_root/output"; then exit 1; fi
if "$build_script" 1.2.3 armv7 "$test_root/output"; then exit 1; fi

DOCKER_LOG="$test_root/docker.log" PATH="$fake_bin:$PATH" "$build_script" 1.2.3 amd64 "$test_root/output"
artifact="$test_root/output/openhands-worker-1.2.3-amd64.wsl"
checksum="$artifact.sha256"
test -f "$artifact"
test -f "$checksum"
grep -F 'buildx bake -f runtimes/wsl/docker-bake.hcl wsl-amd64 --set wsl-amd64.output=type=tar,dest=' "$test_root/docker.log"
(cd "$test_root/output" && sha256sum -c "$(basename "$checksum")")
test -f "$test_root/output/openhands-worker-1.2.3-amd64.wsl"
DOCKER_LOG="$test_root/docker.log" PATH="$fake_bin:$PATH" "$build_script" 1.2.3 arm64 "$test_root/output"
(cd "$test_root/output" && sha256sum -c openhands-worker-1.2.3-arm64.wsl.sha256)

before_artifact=$(sha256sum "$artifact")
before_checksum=$(sha256sum "$checksum")
if DOCKER_LOG="$test_root/docker.log" PATH="$fake_bin:$PATH" "$build_script" 1.2.3 amd64 "$test_root/output"; then exit 1; fi
test "$before_artifact" = "$(sha256sum "$artifact")"
test "$before_checksum" = "$(sha256sum "$checksum")"

collision_artifact="$test_root/output/openhands-worker-1.2.4-amd64.wsl"
collision_checksum="$collision_artifact.sha256"
if CHECKSUM_COLLISION=1 DOCKER_LOG="$test_root/docker.log" PATH="$fake_bin:$PATH" "$build_script" 1.2.4 amd64 "$test_root/output"; then exit 1; fi
test ! -e "$collision_artifact"
test "$(cat "$collision_checksum")" = collision

interrupted_artifact="$test_root/output/openhands-worker-1.2.5-amd64.wsl"
interrupted_checksum="$interrupted_artifact.sha256"
if CHECKSUM_INTERRUPT=1 LN_CALLS="$test_root/ln-calls" DOCKER_LOG="$test_root/docker.log" PATH="$fake_bin:$PATH" "$build_script" 1.2.5 amd64 "$test_root/output"; then exit 1; fi
test ! -e "$interrupted_artifact"
test ! -e "$interrupted_checksum"
