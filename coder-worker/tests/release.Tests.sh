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
  'openssl dgst -sha256 -sign "$private" -out "$release/checksums.txt.sig" "$release/checksums.txt"'
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
grep -A1 -F -e '- name: Remove the signing key' "$workflow" | grep -Fq 'if: always()' ||
  { echo 'the private key removal step must always run'; exit 1; }
if grep -Fq 'DefaultChecksumsSha256' "$workflow"; then
  echo 'the release workflow must not gate on a per-release checksums digest'; exit 1
fi
echo 'PASS: the release workflow signs checksums.txt and gates it on the embedded key'

openssl ecparam -name prime256v1 -genkey -noout -out "$work/throwaway.pem"
openssl dgst -sha256 -sign "$work/throwaway.pem" -out "$work/one/checksums.txt.sig" "$work/one/checksums.txt"
openssl pkey -in "$work/throwaway.pem" -pubout -out "$work/throwaway.pub.pem"
rm -f "$work/throwaway.pem"
openssl dgst -sha256 -verify "$work/throwaway.pub.pem" \
  -signature "$work/one/checksums.txt.sig" "$work/one/checksums.txt" >/dev/null
printf 'x\n' >> "$work/one/checksums.txt"
if openssl dgst -sha256 -verify "$work/throwaway.pub.pem" \
  -signature "$work/one/checksums.txt.sig" "$work/one/checksums.txt" >/dev/null 2>&1; then
  echo 'a tampered checksums.txt must not verify against its signature'; exit 1
fi
echo 'PASS: an assembled checksums.txt signs and verifies, and refuses to after a byte changes'

if bash "$assembler" --out "$work/one" >/dev/null 2>&1; then
  echo 'the assembler must refuse a non-empty output directory'; exit 1
fi
if bash "$assembler" --out "$repo_root/coder-worker/hosts" >/dev/null 2>&1; then
  echo 'the assembler must refuse an output directory inside the repository'; exit 1
fi
echo 'PASS: the assembler refuses an unsafe output directory'
echo 'release tests passed'
