#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
bake_file="$repo_root/runtimes/wsl/docker-bake.hcl"
build_script="$repo_root/runtimes/wsl/build-wsl.sh"
validation_workflow="$repo_root/.github/workflows/validate-openhands-worker.yaml"
release_workflow="$repo_root/.github/workflows/release-openhands-worker.yaml"
readme="$repo_root/runtimes/wsl/README.md"
dockerignore="$repo_root/.dockerignore"

for file in "$bake_file" "$build_script"; do
  test -f "$file"
done

for file in "$validation_workflow" "$release_workflow" "$readme" "$dockerignore"; do
  test -f "$file"
done

ruby -ryaml -rjson -ropen3 -rtmpdir - "$validation_workflow" "$release_workflow" "$readme" "$dockerignore" <<'RUBY'
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

validation, release = ARGV.first(2).map { |path| workflow(path) }
readme = File.read(ARGV.fetch(2))
dockerignore = File.readlines(ARGV.fetch(3), chomp: true)

assert(dockerignore == [
  '**',
  '!.dockerignore',
  '!runtimes/',
  '!runtimes/wsl/',
  '!runtimes/wsl/Containerfile',
  '!runtimes/wsl/provision.sh',
  '!runtimes/wsl/wsl.conf',
  '!runtimes/wsl/wsl-distribution.conf',
  '!runtimes/wsl/omni/',
  '!runtimes/wsl/omni/settings.json',
  '!runtimes/wsl/runtime/',
  '!runtimes/wsl/runtime/agent-canvas.service',
  '!runtimes/wsl/runtime/container-entrypoint.sh',
  '!runtimes/wsl/runtime/nginx-site.conf',
  '!runtimes/wsl/runtime/openhands-overlay.sh',
  '!runtimes/wsl/runtime/patch-agent-canvas-automation.mjs',
  '!runtimes/wsl/runtime/systemd-modules-load-wsl.conf',
  '!runtimes/wsl/tests/',
  '!runtimes/wsl/tests/agent-canvas-ingress-smoke.mjs'
], 'Docker context must contain only worker build inputs')

[
  'multi-architecture OCI image',
  'gzip-compressed tar',
  'openhands-worker-<version>-amd64.wsl',
  'openhands-worker-<version>-arm64.wsl',
  'checksums.txt',
  'releases/download/openhands-worker-v<version>/install.ps1',
  'releases/download/openhands-worker-v<version>/firewall.ps1',
  'releases/download/openhands-worker-v<version>/keepalive.ps1',
  'idle-stops',
  'openhands-overlay secrets',
  'openhands-overlay enable',
  '-RemoteAddresses',
  'never from an older',
  '(cd dist && sha256sum -c openhands-worker-1.2.3-amd64.wsl.sha256)',
  'ImagePath',
  'ImageUri',
  'SHA-256',
  'exactly one artifact source',
  '-amd64.wsl',
  '-arm64.wsl',
  'existing distro is a no-op',
  'after host mirrored-networking reconciliation',
  'does not migrate',
  'WSL state migration',
  'persistent mounts',
  'LOCAL_BACKEND_API_KEY',
  'LOCAL_BACKEND_API_KEY_FILE',
  '/etc/nginx/tls/tls.crt',
  '/etc/nginx/tls/tls.key',
  '`tls.crt`: `root:root`, mode `0644`',
  '`tls.key`: `root:root`, mode `0600`',
  '/etc/credstore/local_backend_api_key',
  'LoadCredential=local_backend_api_key',
  'ConditionVirtualization=!wsl',
  'Omni `0.10.4`',
  'Windows-on-Arm',
  'PR #16635',
  'OpenHands issue #16217',
  'Publication gate: native amd64 CI and real Windows import'
].each do |phrase|
  assert(readme.include?(phrase), "README must document #{phrase.inspect}")
end
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
validation_export = run(validate, 'Export and inspect native WSL image')
assert(validation_export.include?('build-wsl.sh'), 'validation must export WSL image')
checks = validation.fetch('jobs').fetch('checks-amd64')
assert(checks['runs-on'] == 'ubuntu-24.04', 'deterministic checks must run on amd64')
checks_run = run(checks, 'Run deterministic validation')
%w[provision.Tests.sh runtime.Tests.sh image.Tests.sh overlay.Tests.sh install.Tests.ps1 firewall.Tests.ps1 keepalive.Tests.ps1].each do |test|
  assert(checks_run.include?(test), "deterministic checks must run #{test}")
end
assert(checks_run.match?(%r{mcr\.microsoft\.com/powershell@sha256:[0-9a-f]{64}}), 'PowerShell test image must be digest-pinned')
assert(checks_run.include?('shellcheck'), 'deterministic checks must run ShellCheck')

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
full_tar_check = %q{tar -tf "$artifact" | grep -E '^\.?/?etc/wsl\.conf$' >/dev/null}
modules_tar_check = %q{tar -tf "$artifact" | grep -E '^\.?/?etc/systemd/system/systemd-modules-load\.service\.d/10-wsl\.conf$' >/dev/null}
assert(validation_export.include?(full_tar_check), 'validation must consume the full WSL tar listing')
assert(build_run.include?(full_tar_check), 'release must consume the full WSL tar listing')
assert(validation_export.include?(modules_tar_check), 'validation must inspect the WSL module-loader drop-in')
assert(build_run.include?(modules_tar_check), 'release must inspect the WSL module-loader drop-in')
dbus_tar_check = %q{tar -tf "$artifact" | grep -E '^\.?/?usr/lib/systemd/system/dbus\.socket$' >/dev/null}
pam_tar_check = %q{tar -xOf "$artifact" --wildcards '*etc/pam.d/common-session' | grep -E '^session[[:space:]]+optional[[:space:]]+pam_systemd\.so' >/dev/null}
assert(validation_export.include?(dbus_tar_check), 'validation must inspect the D-Bus system bus socket unit')
assert(build_run.include?(dbus_tar_check), 'release must inspect the D-Bus system bus socket unit')
assert(validation_export.include?(pam_tar_check), 'validation must inspect the pam_systemd session hook')
assert(build_run.include?(pam_tar_check), 'release must inspect the pam_systemd session hook')
assert(build_run.include?('push-by-digest=true'), 'release must push architecture images by digest')
assert(build_run.include?('--sbom=true') && build_run.include?('--provenance=mode=max'), 'release must publish SBOM and provenance')
assert(build_run.include?('> "$output/image-digest-${{ matrix.arch }}.txt"'), 'release inputs must share one upload root')
assert(build_run.include?('artifact="$output/openhands-worker-${VERSION}-${{ matrix.arch }}.wsl"'), 'WSL artifact must use the shared upload root')
upload = step(build, 'Upload architecture release inputs').fetch('with')
assert(upload['name'] == 'worker-release-${{ matrix.arch }}', 'release artifact name must be architecture-scoped')
assert(upload.fetch('path').lines.map(&:strip).reject(&:empty?) == [
  '${{ steps.build.outputs.artifact }}',
  '${{ steps.build.outputs.artifact }}.sha256',
  '${{ runner.temp }}/release/image-digest-${{ matrix.arch }}.txt'
], 'release must upload exactly three files from one root')
prepare = run(publish, 'Verify artifacts and prepare draft release')
assert(prepare.include?('git ls-remote') && prepare.include?('GITHUB_SHA'), 'release must verify triggering tag target')
assert(prepare.include?('gh release create "$tag"') && prepare.include?('--verify-tag') && prepare.include?('--draft'), 'release must create or reuse verified draft')
assert(prepare.include?('gh release view "$tag" --json isDraft,tagName,assets'), 'release lookup must include drafts')
assert(prepare.include?('gh release upload "$tag" --clobber'), 'draft asset upload must be idempotent')
assert(prepare.include?('cp runtimes/wsl/install.ps1 release/install.ps1'), 'release must stage the installer from the tagged tree')
assert(prepare.include?('cp runtimes/wsl/firewall.ps1 release/firewall.ps1'), 'release must stage the firewall script from the tagged tree')
assert(prepare.include?('cp runtimes/wsl/keepalive.ps1 release/keepalive.ps1'), 'release must stage the keepalive script from the tagged tree')
assert(prepare.include?('sha256sum install.ps1 firewall.ps1 keepalive.ps1 >> checksums.txt'), 'release checksums must cover every host script')
assert(prepare.scan(/"?keepalive\.ps1"?/).length >= 4, 'keepalive script must be uploaded and verified like every other asset')
assert(prepare.scan(/"?firewall\.ps1"?/).length >= 4, 'firewall script must be uploaded and verified like every other asset')
assert(prepare.include?('release/install.ps1'), 'release must publish the installer')
assert(prepare.scan(/"?install\.ps1"?/).length >= 4, 'installer must be uploaded and verified like every other asset')
assert(prepare.include?('.tagName') && prepare.include?('.isDraft') && !prepare.include?('releases/tags') && !prepare.include?('targetCommitish'), 'remote tag is authority for release reuse')
assert(prepare.include?('.state == "uploaded"') && prepare.include?('.digest == $digest'), 'published assets must be complete and match local digests')
manifest = run(publish, 'Verify or create immutable manifest')
assert(manifest.include?('source_descriptors') && manifest.include?('imagetools inspect --raw') && manifest.include?('is_exact_absence'), 'manifest must flatten validated source indexes')
assert(manifest.include?('--tag "$IMAGE:$VERSION"') && !manifest.include?(':latest'), 'manifest must use only immutable version tag')
assert(manifest.include?('image-digest-amd64.txt') && manifest.include?('image-digest-arm64.txt'), 'manifest must contain exact child digests')
assert((prepare + manifest).include?('sha256sum -c checksums.txt'), 'release must verify combined checksums')
finalize = run(publish, 'Publish verified draft release')
assert(finalize.include?('gh release edit "$tag" --draft=false'), 'only verified draft may be published')

source_filter = manifest.match(/jq -e --arg arch "\$arch" '(.*?)' "\$source"/m)&.[](1)
final_filter = manifest.match(/jq -e --slurpfile expected "\$expected" '(.*?)' "\$manifest"/m)&.[](1)
abort('source index validation must be jq-based') unless source_filter
abort('final manifest validation must be jq-based') unless final_filter
index_type = 'application/vnd.oci.image.index.v1+json'
manifest_list_type = 'application/vnd.docker.distribution.manifest.list.v2+json'
manifest_type = 'application/vnd.oci.image.manifest.v1+json'
docker_manifest_type = 'application/vnd.docker.distribution.manifest.v2+json'
amd64 = "sha256:#{'a' * 64}"
arm64 = "sha256:#{'b' * 64}"
amd64_attestation = "sha256:#{'c' * 64}"
arm64_attestation = "sha256:#{'d' * 64}"
source_index_amd64 = "sha256:#{'e' * 64}"
source_index_arm64 = "sha256:#{'f' * 64}"
runtime = lambda do |digest, architecture|
  { 'mediaType' => manifest_type, 'digest' => digest, 'platform' => { 'os' => 'linux', 'architecture' => architecture } }
end
attestation = lambda do |digest, runtime_digest|
  {
    'mediaType' => manifest_type,
    'digest' => digest,
    'platform' => { 'os' => 'unknown', 'architecture' => 'unknown' },
    'annotations' => {
      'vnd.docker.reference.type' => 'attestation-manifest',
      'vnd.docker.reference.digest' => runtime_digest
    }
  }
end
source = lambda do |architecture, runtime_digest, attestation_digest|
  { 'mediaType' => index_type, 'manifests' => [runtime.call(runtime_digest, architecture), attestation.call(attestation_digest, runtime_digest)] }
end
run_source = lambda do |architecture, document|
  Open3.capture3('jq', '-e', '--arg', 'arch', architecture, source_filter, stdin_data: JSON.generate(document))
end
amd64_source = source.call('amd64', amd64, amd64_attestation)
arm64_source = source.call('arm64', arm64, arm64_attestation)
amd64_descriptors, _, amd64_status = run_source.call('amd64', amd64_source)
arm64_descriptors, _, arm64_status = run_source.call('arm64', arm64_source)
assert(amd64_status.success? && arm64_status.success?, 'nested per-architecture indexes must pass')
docker_source = source.call('amd64', amd64, amd64_attestation)
docker_source['manifests'].each { |item| item['mediaType'] = docker_manifest_type }
assert(run_source.call('amd64', docker_source)[2].success?, 'Docker image manifest children must pass')
runtime_index = source.call('amd64', amd64, amd64_attestation)
runtime_index['manifests'][0]['mediaType'] = index_type
assert(!run_source.call('amd64', runtime_index)[2].success?, 'nested index runtime child must fail')
attestation_index = source.call('amd64', amd64, amd64_attestation)
attestation_index['manifests'][1]['mediaType'] = index_type
assert(!run_source.call('amd64', attestation_index)[2].success?, 'nested index attestation child must fail')
runtime_manifest_list = source.call('amd64', amd64, amd64_attestation)
runtime_manifest_list['manifests'][0]['mediaType'] = manifest_list_type
assert(!run_source.call('amd64', runtime_manifest_list)[2].success?, 'nested manifest-list runtime child must fail')
attestation_manifest_list = source.call('amd64', amd64, amd64_attestation)
attestation_manifest_list['manifests'][1]['mediaType'] = manifest_list_type
assert(!run_source.call('amd64', attestation_manifest_list)[2].success?, 'nested manifest-list attestation child must fail')
expected = JSON.parse(amd64_descriptors) + JSON.parse(arm64_descriptors)
run_final = lambda do |document, descriptors|
  Dir.mktmpdir do |directory|
    expected_path = File.join(directory, 'expected.json')
    File.write(expected_path, JSON.generate(descriptors))
    Open3.capture3('jq', '-e', '--slurpfile', 'expected', expected_path, final_filter, stdin_data: JSON.generate(document))
  end
end
final_index = { 'mediaType' => index_type, 'manifests' => expected }
assert(run_final.call(final_index, expected)[2].success?, 'flattened final descriptor union must pass')
old_top_level_comparison = expected.map(&:dup)
old_top_level_comparison[0] = runtime.call(source_index_amd64, 'amd64')
assert(!run_final.call({ 'mediaType' => index_type, 'manifests' => old_top_level_comparison }, expected)[2].success?, 'source index digest is not final runtime digest')
assert(!run_source.call('amd64', { 'mediaType' => index_type, 'manifests' => [runtime.call(amd64, 'amd64')] })[2].success?, 'missing source attestation must fail')
wrong_attestation = source.call('amd64', amd64, amd64_attestation)
wrong_attestation['manifests'][1]['annotations']['vnd.docker.reference.digest'] = arm64
assert(!run_source.call('amd64', wrong_attestation)[2].success?, 'wrong source attestation reference must fail')
extra_platform = final_index.merge('manifests' => expected + [runtime.call("sha256:#{'9' * 64}", 's390x')])
assert(!run_final.call(extra_platform, expected)[2].success?, 'extra final platform must fail')

asset_filter = prepare.match(/jq -e --arg asset "\$asset" --arg digest "\$digest"\s*\\?\s*'(.*?)'\s*\\?\s*"\$release_json"/m)&.[](1)
abort('published asset validation must be jq-based') unless asset_filter
run_asset = lambda do |assets, digest|
  Open3.capture3('jq', '-e', '--arg', 'asset', 'openhands-worker-1.2.3-amd64.wsl', '--arg', 'digest', digest, asset_filter, stdin_data: JSON.generate('assets' => assets))
end
valid_asset = { 'name' => 'openhands-worker-1.2.3-amd64.wsl', 'state' => 'uploaded', 'digest' => "sha256:#{'e' * 64}" }
assert(run_asset.call([valid_asset], valid_asset['digest'])[2].success?, 'matching uploaded asset must pass')
assert(!run_asset.call([], valid_asset['digest'])[2].success?, 'missing asset must fail')
assert(!run_asset.call([valid_asset], "sha256:#{'f' * 64}")[2].success?, 'wrong asset digest must fail')

reference = 'ghcr.io/lkshrk/openhands-worker:1.2.3'
absence_helper = manifest.match(/(is_exact_absence\(\) \{.*?^\s*\})/m)&.[](1)
abort('registry absence must use a dedicated exact predicate') unless absence_helper
run_absence = lambda do |diagnostic|
  Dir.mktmpdir do |directory|
    error_path = File.join(directory, 'inspect-error.log')
    File.write(error_path, diagnostic)
    Open3.capture3('bash', '-c', "#{absence_helper}\nis_exact_absence \"$1\" \"$2\"", 'bash', error_path, reference)[2]
  end
end
assert(run_absence.call("ERROR: #{reference}: not found\n").success?, 'exact registry absence must pass')
assert(!run_absence.call("ERROR: ghcr.io/lkshrk/openhands-worker:1.2: not found\n").success?, 'prefix tag must not be absence')
assert(!run_absence.call("ERROR: #{reference}: not found\nextra\n").success?, 'multiline error must not be absence')
assert(!run_absence.call("ERROR: #{reference}: denied\n").success?, 'registry permission failure must not be absence')
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
    *type=tar,dest=*)
      destination=${argument#*type=tar,dest=}
      root=$(mktemp -d)
      mkdir -p "$root/etc"
      printf '[boot]\nsystemd=true\n' > "$root/etc/wsl.conf"
      TZ=UTC touch -t 200001010000 "$root/etc/wsl.conf"
      tar -cf "$destination" -C "$root" etc/wsl.conf
      rm -rf -- "$root"
      ;;
  esac
done
if test -n "${CHECKSUM_COLLISION:-}"; then
  printf collision > "$CHECKSUM_COLLISION"
fi
EOF
chmod 0755 "$fake_bin/docker"
cat > "$fake_bin/wc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if test -n "${OVERSIZE:-}"; then
  printf '2147483648\n'
else
  /usr/bin/wc "$@"
fi
EOF
chmod 0755 "$fake_bin/wc"
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

mkdir "$test_root/real-output"
ln -s real-output "$test_root/output"
DOCKER_LOG="$test_root/docker.log" PATH="$fake_bin:$PATH" "$build_script" 1.2.3 amd64 "$test_root/output"
artifact="$test_root/output/openhands-worker-1.2.3-amd64.wsl"
checksum="$artifact.sha256"
test -f "$artifact"
test -f "$checksum"
gzip -t "$artifact"
tar -tf "$artifact" | grep -Fx 'etc/wsl.conf' >/dev/null
canonical_output=$(cd "$test_root/output" && pwd -P)
grep -F "buildx bake --allow=fs.write=$canonical_output -f runtimes/wsl/docker-bake.hcl wsl-amd64 --set wsl-amd64.output=type=tar,dest=" "$test_root/docker.log"
(cd "$test_root/output" && sha256sum -c "$(basename "$checksum")")
test -f "$test_root/output/openhands-worker-1.2.3-amd64.wsl"
DOCKER_LOG="$test_root/docker.log" PATH="$fake_bin:$PATH" "$build_script" 1.2.3 arm64 "$test_root/output"
arm64_artifact="$test_root/output/openhands-worker-1.2.3-arm64.wsl"
(cd "$test_root/output" && sha256sum -c openhands-worker-1.2.3-arm64.wsl.sha256)
cmp -s "$artifact" "$arm64_artifact"
test -z "$(find -L "$test_root/output" -maxdepth 1 -name '.openhands-worker-*.tar.*' -print -quit)"

before_artifact=$(sha256sum "$artifact")
before_checksum=$(sha256sum "$checksum")
if DOCKER_LOG="$test_root/docker.log" PATH="$fake_bin:$PATH" "$build_script" 1.2.3 amd64 "$test_root/output"; then exit 1; fi
test "$before_artifact" = "$(sha256sum "$artifact")"
test "$before_checksum" = "$(sha256sum "$checksum")"

collision_artifact="$test_root/output/openhands-worker-1.2.4-amd64.wsl"
collision_checksum="$collision_artifact.sha256"
if CHECKSUM_COLLISION="$collision_checksum" DOCKER_LOG="$test_root/docker.log" PATH="$fake_bin:$PATH" "$build_script" 1.2.4 amd64 "$test_root/output"; then exit 1; fi
test ! -e "$collision_artifact"
test "$(cat "$collision_checksum")" = collision

interrupted_artifact="$test_root/output/openhands-worker-1.2.5-amd64.wsl"
interrupted_checksum="$interrupted_artifact.sha256"
if CHECKSUM_INTERRUPT=1 LN_CALLS="$test_root/ln-calls" DOCKER_LOG="$test_root/docker.log" PATH="$fake_bin:$PATH" "$build_script" 1.2.5 amd64 "$test_root/output"; then exit 1; fi
test ! -e "$interrupted_artifact"
test ! -e "$interrupted_checksum"

oversize_artifact="$test_root/output/openhands-worker-1.2.6-amd64.wsl"
oversize_checksum="$oversize_artifact.sha256"
if OVERSIZE=1 DOCKER_LOG="$test_root/docker.log" PATH="$fake_bin:$PATH" "$build_script" 1.2.6 amd64 "$test_root/output"; then exit 1; fi
test ! -e "$oversize_artifact"
test ! -e "$oversize_checksum"
test -z "$(find -L "$test_root/output" -maxdepth 1 -name '.openhands-worker-1.2.6-amd64.wsl*' -print -quit)"
