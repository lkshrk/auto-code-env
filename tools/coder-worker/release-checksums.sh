#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 022

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly script_directory
repository_root=$(cd -- "$script_directory" && until [ -e .git ]; do [ "$PWD" = / ] && exit 1; cd ..; done && pwd)
readonly repository_root

out_directory=''

usage() {
    cat >&2 <<'EOF'
usage: release-checksums.sh --out DIR

Assembles the coder-worker release assets into DIR, writes checksums.txt over
every artifact install.ps1 fetches, and prints the SHA-256 of checksums.txt.
DIR must be new or empty. Signing checksums.txt is the release workflow's job,
so this script needs no key and never touches one; pass the digest it prints to
install.ps1 -ChecksumsSha256 to install from an unsigned local assembly.

install.ps1 is published but stays out of checksums.txt: it is the anchor the
operator already holds, and checksums.txt only covers what it fetches.
EOF
    exit 2
}

fail() {
    printf 'release-checksums: %s\n' "$1" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case $1 in
        --out) out_directory=${2:-}; shift 2 ;;
        *) usage ;;
    esac
done

[ -n "$out_directory" ] || usage
case $out_directory in /*) ;; *) out_directory="$PWD/$out_directory" ;; esac
case $out_directory in
    "$repository_root" | "$repository_root"/*) fail 'the output directory must be outside this repository' ;;
esac
if [ -e "$out_directory" ]; then
    [ -d "$out_directory" ] || fail "$out_directory is not a directory"
    [ -z "$(ls -A -- "$out_directory")" ] || fail "$out_directory is not empty"
else
    mkdir -p -- "$out_directory"
fi

install -m 0644 "$repository_root/coder/worker/install/install.ps1" "$out_directory/install.ps1"
install -m 0644 "$repository_root/coder/worker/runtime/coder-worker-overlay" "$out_directory/coder-worker-overlay"
install -m 0644 "$repository_root/coder/worker/tools/gen-docker-tls.sh" "$out_directory/gen-docker-tls.sh"
install -m 0644 "$repository_root/shared/windows/firewall.ps1" "$out_directory/firewall.ps1"
install -m 0644 "$repository_root/shared/windows/keepalive.ps1" "$out_directory/keepalive.ps1"

covered=(coder-worker-overlay gen-docker-tls.sh firewall.ps1 keepalive.ps1)
profiles=("$repository_root"/coder/worker/hosts/*.profile)
[ -e "${profiles[0]}" ] || fail 'no host profile to publish'
for source in "${profiles[@]}"; do
    asset="host-$(basename -- "$source")"
    install -m 0644 "$source" "$out_directory/$asset"
    covered+=("$asset")
done

cd -- "$out_directory"
sha256sum -- "${covered[@]}" > checksums.txt
sha256sum -c --quiet checksums.txt
sha256sum -- install.ps1 > install.ps1.sha256
sha256sum -- checksums.txt | cut -d' ' -f1
