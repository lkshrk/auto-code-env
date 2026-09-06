#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
assembler="$repo_root/coder-worker/scripts/release-checksums.sh"
installer="$repo_root/coder-worker/windows/install.ps1"

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

first=$(bash "$assembler" --out "$work/one")
second=$(bash "$assembler" --out "$work/two")
test "$first" = "$second"
echo 'PASS: the release assembler is deterministic'

(cd "$work/one" && sha256sum -c --quiet checksums.txt)
test "$(sha256sum < "$work/one/checksums.txt" | cut -d' ' -f1)" = "$first"
test -f "$work/one/install.ps1"
test -f "$work/one/install.ps1.sha256"
if grep -Fq ' install.ps1' "$work/one/checksums.txt"; then
  echo 'install.ps1 embeds the digest of checksums.txt, so it must stay out of it'; exit 1
fi
for asset in coder-worker-overlay firewall.ps1 keepalive.ps1 gen-docker-tls.sh; do
  grep -Eq "^[0-9a-f]{64}  $asset\$" "$work/one/checksums.txt" ||
    { echo "checksums.txt is missing $asset"; exit 1; }
done
grep -Eq '^[0-9a-f]{64}  host-[A-Za-z0-9][A-Za-z0-9._-]*\.profile$' "$work/one/checksums.txt"
grep -oE '\-Asset "[a-z0-9.-]+"' "$installer" | cut -d'"' -f2 | sort -u |
  grep -Fxv checksums.txt > "$work/fetched"
test -s "$work/fetched"
while IFS= read -r asset; do
  grep -Eq "^[0-9a-f]{64}  $asset\$" "$work/one/checksums.txt" ||
    { echo "install.ps1 fetches $asset but checksums.txt does not cover it"; exit 1; }
done < "$work/fetched"
echo 'PASS: checksums.txt covers every fetched artifact and excludes install.ps1'

for absent in ImportSubjectPublicKeyInfo DSASignatureFormat; do
  if grep -Fq "$absent" "$installer"; then
    echo "install.ps1 must not use $absent; Windows PowerShell 5.1 does not have it"; exit 1
  fi
done
if grep -Fq 'DefaultChecksumsSha256' "$installer"; then
  echo 'install.ps1 must not pin a per-release checksums digest'; exit 1
fi
key=$(grep -Eo '^[$]ReleaseSigningKey = "[A-Za-z0-9+/]+={0,2}"$' "$installer" | cut -d'"' -f2)
test -n "$key"
printf '%s' "$key" | openssl base64 -d -A > "$work/release-signing-key.der"
openssl pkey -pubin -inform DER -in "$work/release-signing-key.der" -noout -text > "$work/release-signing-key.txt"
grep -Fq 'NIST CURVE: P-256' "$work/release-signing-key.txt"
echo 'PASS: install.ps1 embeds a parseable P-256 release signing key'

workflow="$repo_root/.github/workflows/coder-worker-release.yaml"
# shellcheck disable=SC2016
required_in_workflow=(
  'openssl dgst -sha256 -sign "$private" -out "$release/checksums.txt.sig" "$payload"'
  $'{ printf \'%s\\n\' "$tag"; cat "$release/checksums.txt"; } > "$payload"'
  'git ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}"'
  'openssl dgst -sha256 -verify "$RUNNER_TEMP/release-signing-key.pem"'
  'rm -f "$RUNNER_TEMP/signing-key.pem"'
  'umask 077'
)
for required in "${required_in_workflow[@]}"; do
  grep -Fq "$required" "$workflow" ||
    { echo "the release workflow must contain: $required"; exit 1; }
done
grep -q 'ReleaseSigningKey.*coder-worker/windows/install\.ps1' "$workflow" ||
  { echo 'the release workflow must read the public key out of install.ps1'; exit 1; }
grep -Fq '= checksums.txt.sig ]; then' "$workflow" ||
  { echo 'a republished release must not compare the signature by digest; ECDSA is not deterministic'; exit 1; }
grep -Fq 'the published checksums.txt.sig does not verify against ReleaseSigningKey' "$workflow" ||
  { echo 'a republished release must verify the published signature'; exit 1; }
grep -A1 -F -e '- name: Remove the signing key' "$workflow" | grep -Fq 'if: always()' ||
  { echo 'the private key removal step must always run'; exit 1; }
if grep -Fq 'DefaultChecksumsSha256' "$workflow"; then
  echo 'the release workflow must not gate on a per-release checksums digest'; exit 1
fi
echo 'PASS: the release workflow signs checksums.txt and gates it on the embedded key'

trigger="$work/trigger"
sed -n '/^on:/,/^permissions:/p' "$workflow" > "$trigger"
grep -Fq '      - main' "$trigger" ||
  { echo 'the release workflow must trigger on a push to main'; exit 1; }
grep -Fq '      - coder-worker-v*' "$trigger" ||
  { echo 'the release workflow must still trigger on a release tag'; exit 1; }
if grep -Eq '^ *paths(-ignore)?:' "$trigger"; then
  echo 'a paths filter interacts badly with tag pushes and would silently skip releases'; exit 1
fi

resolve="$work/resolve-step"
awk '/^      - name: / { current = substr($0, 15); next } current == "Resolve the release tag" { print }' \
  "$workflow" > "$resolve"
test -s "$resolve" || { echo 'the release workflow must resolve its own tag'; exit 1; }
# shellcheck disable=SC2016
required_in_resolve=(
  'readonly RELEASE_VERSION='
  'coder-worker/wsl/coder-worker-overlay'
  'tag="coder-worker-v$version"'
  'git ls-remote --tags origin "refs/tags/$tag"'
  'echo "skip=true" >> "$GITHUB_OUTPUT"'
  'git tag "$tag" "$GITHUB_SHA"'
  'git push origin "refs/tags/$tag"'
)
for required in "${required_in_resolve[@]}"; do
  grep -Fq "$required" "$resolve" ||
    { echo "the tag-resolving step must contain: $required"; exit 1; }
done

line_of() { grep -n -F -e "$2" "$1" | head -1 | cut -d: -f1; }
# shellcheck disable=SC2016
create=$(line_of "$resolve" 'git tag "$tag" "$GITHUB_SHA"')
# shellcheck disable=SC2016
already=$(line_of "$resolve" 'echo "skip=true" >> "$GITHUB_OUTPUT"')
pinned=$(line_of "$resolve" 'DefaultRelease')
test "$already" -lt "$create" ||
  { echo 'an already-released tag must be detected before the workflow creates one'; exit 1; }
test "$pinned" -lt "$create" ||
  { echo 'a half-finished version bump must be refused before the workflow creates a tag'; exit 1; }
echo 'PASS: the release workflow tags the built commit, and only when the version is new and consistent'

awk '
  /^      - name: / {
    name = substr($0, 15); n++; step[n] = name; body[n] = ""
    if (name == "Resolve the release tag") resolve = n
    next
  }
  n { body[n] = body[n] $0 "\n" }
  END {
    if (!resolve) { print "the workflow has no tag-resolving step"; exit 1 }
    for (i = resolve + 1; i <= n; i++)
      if (index(body[i], "steps.tag.outputs.skip") == 0) {
        printf "step \"%s\" would run on a merge that releases nothing\n", step[i]
        bad = 1
      }
    exit bad
  }
' "$workflow" || exit 1

# shellcheck disable=SC2016
gates_in_workflow=(
  'test "$tag_commit" = "$GITHUB_SHA"'
  'grep -Fxq "\$DefaultRelease = \"$tag\"" coder-worker/windows/install.ps1'
  'grep -Fxq "readonly RELEASE_VERSION=$VERSION" coder-worker/wsl/coder-worker-overlay'
  'pwsh -NoProfile -File coder-worker/tests/install.Tests.ps1'
)
for suite in release profile install overlay gen-docker-tls images; do
  gates_in_workflow+=("bash coder-worker/tests/$suite.Tests.sh")
done
for required in "${gates_in_workflow[@]}"; do
  grep -Fq "$required" "$workflow" ||
    { echo "the release workflow must keep the gate: $required"; exit 1; }
done
echo 'PASS: every release gate survives, and no step past the tag runs when nothing is released'

bind() { { printf '%s\n' "$1"; cat "$work/one/checksums.txt"; } > "$2"; }
openssl ecparam -name prime256v1 -genkey -noout -out "$work/throwaway.pem"
bind coder-worker-v1.0.0 "$work/payload"
openssl dgst -sha256 -sign "$work/throwaway.pem" -out "$work/one/checksums.txt.sig" "$work/payload"
openssl pkey -in "$work/throwaway.pem" -pubout -out "$work/throwaway.pub.pem"
rm -f "$work/throwaway.pem"
openssl dgst -sha256 -verify "$work/throwaway.pub.pem" \
  -signature "$work/one/checksums.txt.sig" "$work/payload" >/dev/null
bind coder-worker-v1.0.1 "$work/other-tag"
if openssl dgst -sha256 -verify "$work/throwaway.pub.pem" \
  -signature "$work/one/checksums.txt.sig" "$work/other-tag" >/dev/null 2>&1; then
  echo 'a signature must not carry from one release tag to another'; exit 1
fi
printf 'x\n' >> "$work/one/checksums.txt"
bind coder-worker-v1.0.0 "$work/payload"
if openssl dgst -sha256 -verify "$work/throwaway.pub.pem" \
  -signature "$work/one/checksums.txt.sig" "$work/payload" >/dev/null 2>&1; then
  echo 'a tampered checksums.txt must not verify against its signature'; exit 1
fi
echo 'PASS: a signed checksums.txt is bound to its tag and to its bytes'

if bash "$assembler" --out "$work/one" >/dev/null 2>&1; then
  echo 'the assembler must refuse a non-empty output directory'; exit 1
fi
if bash "$assembler" --out "$repo_root/coder-worker/hosts" >/dev/null 2>&1; then
  echo 'the assembler must refuse an output directory inside the repository'; exit 1
fi
echo 'PASS: the assembler refuses an unsafe output directory'
echo 'release tests passed'
