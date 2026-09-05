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

grep -Fxq "\$DefaultChecksumsSha256 = \"$first\"" "$installer" || {
  echo "install.ps1 must embed \$DefaultChecksumsSha256 = \"$first\""
  echo 'recompute it with coder-worker/scripts/release-checksums.sh --out DIR'
  exit 1
}
echo 'PASS: install.ps1 embeds the digest of the checksums.txt it will fetch'

if bash "$assembler" --out "$work/one" >/dev/null 2>&1; then
  echo 'the assembler must refuse a non-empty output directory'; exit 1
fi
if bash "$assembler" --out "$repo_root/coder-worker/hosts" >/dev/null 2>&1; then
  echo 'the assembler must refuse an output directory inside the repository'; exit 1
fi
echo 'PASS: the assembler refuses an unsafe output directory'
echo 'release tests passed'
