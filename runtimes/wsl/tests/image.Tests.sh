#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
bake_file="$repo_root/runtimes/wsl/docker-bake.hcl"
build_script="$repo_root/runtimes/wsl/build-wsl.sh"

for file in "$bake_file" "$build_script"; do
  test -f "$file"
done

grep -F 'ghcr.io/lkshrk/openhands-worker:${VERSION}' "$bake_file"
grep -Eq '^ *target *= *"oci"' "$bake_file"
grep -Eq '^ *platforms *= *\["linux/amd64", "linux/arm64"\]' "$bake_file"
grep -Eq '^ *target *= *"wsl"' "$bake_file"
grep -Eq '^ *platforms *= *\["linux/amd64"\]' "$bake_file"
grep -Eq '^ *platforms *= *\["linux/arm64"\]' "$bake_file"

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
EOF
chmod 0755 "$fake_bin/docker"

if "$build_script" '' amd64 "$test_root/output"; then exit 1; fi
if "$build_script" 1.2.3 armv7 "$test_root/output"; then exit 1; fi

DOCKER_LOG="$test_root/docker.log" PATH="$fake_bin:$PATH" "$build_script" 1.2.3 amd64 "$test_root/output"
artifact="$test_root/output/openhands-worker-1.2.3-amd64.wsl"
checksum="$artifact.sha256"
test -f "$artifact"
test -f "$checksum"
grep -F 'buildx bake -f runtimes/wsl/docker-bake.hcl wsl-amd64 --set wsl-amd64.output=type=tar,dest=' "$test_root/docker.log"
grep -F "openhands-worker-1.2.3-amd64.wsl" "$checksum"
if DOCKER_LOG="$test_root/docker.log" PATH="$fake_bin:$PATH" "$build_script" 1.2.3 amd64 "$test_root/output"; then exit 1; fi
