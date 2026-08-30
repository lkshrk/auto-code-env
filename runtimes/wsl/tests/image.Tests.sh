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

ruby -ryaml -rjson -ropen3 - "$validation_workflow" "$release_workflow" <<'RUBY'
def assert(condition, message)
  abort(message) unless condition
end

def workflow(path)
  YAML.safe_load(File.read(path), aliases: true)
end

def trigger(document)
  document['on'] || document[true]
end

def step(job, name)
  job.fetch('steps').find { |item| item['name'] == name } || abort("missing step: #{name}")
end

def run(job, name)
  step(job, name).fetch('run')
end

validation, release = ARGV.map { |path| workflow(path) }
native_matrix = [
  { 'arch' => 'amd64', 'platform' => 'linux/amd64', 'runner' => 'ubuntu-24.04' },
  { 'arch' => 'arm64', 'platform' => 'linux/arm64', 'runner' => 'ubuntu-24.04-arm' }
]

assert(trigger(validation).dig('pull_request', 'paths') == [
  '.github/workflows/validate-openhands-worker.yaml',
  '.github/workflows/release-openhands-worker.yaml',
  'runtimes/wsl/**'
], 'validation paths must be worker-only')
assert(validation['permissions'] == { 'contents' => 'read' }, 'validation permissions must be read-only')
validate = validation.fetch('jobs').fetch('validate')
assert(validate.dig('strategy', 'matrix', 'include') == native_matrix, 'validation must use exact native matrix')
assert(validate.fetch('steps').none? { |item| item['uses'].to_s.include?('qemu') }, 'validation must not enable emulation')
assert(run(validate, 'Smoke native image build').include?('type=cacheonly'), 'validation must smoke cache-only build')
assert(run(validate, 'Export and inspect native WSL image').include?('build-wsl.sh'), 'validation must export WSL image')

assert(trigger(release).dig('push', 'tags') == ['openhands-worker-v*'], 'release must only run for worker tags')
assert(release['permissions'] == { 'contents' => 'read' }, 'release default permissions must be read-only')
assert(release['concurrency'] == {
  'group' => 'release-openhands-worker-${{ github.ref_name }}',
  'cancel-in-progress' => false
}, 'release must serialize each worker version without cancellation')
build = release.fetch('jobs').fetch('build')
publish = release.fetch('jobs').fetch('publish')
assert(build['permissions'] == { 'contents' => 'read', 'packages' => 'write' }, 'build must have only package publishing permission')
assert(publish['permissions'] == { 'contents' => 'write', 'packages' => 'write' }, 'only publish job may write release contents')
assert(publish['env'] == { 'GH_TOKEN' => '${{ secrets.GITHUB_TOKEN }}' }, 'publish job must authenticate every gh command')
assert(build.dig('strategy', 'matrix', 'include') == native_matrix, 'release must use exact native matrix')
assert(build.fetch('steps').none? { |item| item['uses'].to_s.include?('qemu') }, 'release must not enable emulation')
build_run = run(build, 'Build architecture image and WSL artifact')
assert(build_run.include?('push-by-digest=true'), 'release must push architecture images by digest')
assert(build_run.include?('--sbom=true') && build_run.include?('--provenance=mode=max'), 'release must publish SBOM and provenance')
upload = step(build, 'Upload architecture release inputs').fetch('with')
assert(upload['name'] == 'worker-release-${{ matrix.arch }}', 'release artifact name must be architecture-scoped')
assert(upload['path'].include?('${{ steps.build.outputs.artifact }}') && upload['path'].include?('image-digest-${{ matrix.arch }}.txt'), 'release must upload WSL files and digests')
prepare = run(publish, 'Verify artifacts and prepare draft release')
assert(prepare.include?('git ls-remote') && prepare.include?('GITHUB_SHA'), 'release must verify triggering tag target')
assert(prepare.include?('gh release create "$tag"') && prepare.include?('--verify-tag') && prepare.include?('--draft'), 'release must create or reuse verified draft')
assert(prepare.include?('gh release upload "$tag" --clobber'), 'draft asset upload must be idempotent')
assert(prepare.include?(".tag_name") && !prepare.include?('target_commitish'), 'remote tag is authority for release reuse')
assert(prepare.include?('.state == "uploaded"') && prepare.include?('.digest == $digest'), 'published assets must be complete and match local digests')
manifest = run(publish, 'Verify or create immutable manifest')
assert(manifest.include?('imagetools inspect --raw') && manifest.include?('manifest unknown') && manifest.include?('reference="$IMAGE:$VERSION"') && manifest.include?('grep -Fq "$reference"'), 'manifest lookup must distinguish exact absence from errors')
assert(manifest.include?('--tag "$IMAGE:$VERSION"') && !manifest.include?(':latest'), 'manifest must use only immutable version tag')
assert(manifest.include?('image-digest-amd64.txt') && manifest.include?('image-digest-arm64.txt'), 'manifest must contain exact child digests')
assert((prepare + manifest).include?('sha256sum -c checksums.txt'), 'release must verify combined checksums')
finalize = run(publish, 'Publish verified draft release')
assert(finalize.include?('gh release edit "$tag" --draft=false'), 'only verified draft may be published')

manifest_filter = manifest.match(/jq -e --arg amd64 "\$amd64_digest" --arg arm64 "\$arm64_digest" '(.*?)' "\$manifest"/m)&.[](1)
abort('manifest validation must be jq-based') unless manifest_filter
amd64 = "sha256:#{'a' * 64}"
arm64 = "sha256:#{'b' * 64}"
descriptor = lambda { |digest, architecture| { 'digest' => digest, 'platform' => { 'os' => 'linux', 'architecture' => architecture } } }
attestation = {
  'digest' => "sha256:#{'c' * 64}",
  'platform' => { 'os' => 'unknown', 'architecture' => 'unknown' },
  'annotations' => {
    'vnd.docker.reference.type' => 'attestation-manifest',
    'vnd.docker.reference.digest' => amd64
  }
}
run_manifest = lambda do |descriptors|
  Open3.capture3('jq', '-e', '--arg', 'amd64', amd64, '--arg', 'arm64', arm64, manifest_filter, stdin_data: JSON.generate('manifests' => descriptors))
end
assert(run_manifest.call([descriptor.call(amd64, 'amd64'), descriptor.call(arm64, 'arm64')])[2].success?, 'exact manifest must pass')
assert(!run_manifest.call([descriptor.call(amd64, 'amd64'), descriptor.call(arm64, 'arm64'), descriptor.call("sha256:#{'d' * 64}", 's390x')])[2].success?, 'extra platform must fail')
assert(!run_manifest.call([descriptor.call(amd64, 'amd64'), descriptor.call("sha256:#{'d' * 64}", 'arm64')])[2].success?, 'wrong digest must fail')
assert(!run_manifest.call([descriptor.call(amd64, 'amd64'), descriptor.call(amd64, 'amd64'), descriptor.call(arm64, 'arm64')])[2].success?, 'duplicate platform must fail')
assert(run_manifest.call([descriptor.call(amd64, 'amd64'), descriptor.call(arm64, 'arm64'), attestation])[2].success?, 'valid attestation must pass')
assert(!run_manifest.call([descriptor.call(amd64, 'amd64'), descriptor.call(arm64, 'arm64'), attestation, attestation])[2].success?, 'duplicate attestation must fail')

asset_filter = prepare.match(/jq -e --arg asset "\$asset" --arg digest "\$digest"\s*\\?\s*'(.*?)'\s*\\?\s*"\$release_json"/m)&.[](1)
abort('published asset validation must be jq-based') unless asset_filter
run_asset = lambda do |assets, digest|
  Open3.capture3('jq', '-e', '--arg', 'asset', 'openhands-worker-1.2.3-amd64.wsl', '--arg', 'digest', digest, asset_filter, stdin_data: JSON.generate('assets' => assets))
end
valid_asset = { 'name' => 'openhands-worker-1.2.3-amd64.wsl', 'state' => 'uploaded', 'digest' => "sha256:#{'e' * 64}" }
assert(run_asset.call([valid_asset], valid_asset['digest'])[2].success?, 'matching uploaded asset must pass')
assert(!run_asset.call([], valid_asset['digest'])[2].success?, 'missing asset must fail')
assert(!run_asset.call([valid_asset], "sha256:#{'f' * 64}")[2].success?, 'wrong asset digest must fail')

absent = lambda { |diagnostic, reference| diagnostic.include?(reference) && diagnostic.match?(/manifest unknown|not found/i) }
reference = 'ghcr.io/lkshrk/openhands-worker:1.2.3'
assert(absent.call("#{reference}: manifest unknown", reference), 'exact registry absence must pass')
assert(!absent.call("#{reference}: denied", reference), 'registry permission failure must not be absence')
assert(!absent.call('ghcr.io/other/worker: manifest unknown', reference), 'different registry reference must not be absence')
assert(!absent.call('not found', reference), 'bare not-found error must not be absence')
(validation.fetch('jobs').values + release.fetch('jobs').values).each do |job|
  job.fetch('steps').map { |item| item['uses'] }.compact.each do |uses|
    assert(uses.match?(%r{@[0-9a-f]{40}$}), "action ref must be immutable: #{uses}")
  end
end
RUBY

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
