#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
overlay="$repo_root/coder-worker/wsl/coder-worker-overlay"
backend="$repo_root/coder/templates/backends/docker.tf"

test -f "$overlay"
test -f "$backend"

# The overlay pre-pulls; the template runs. A drift makes the first build fetch over the LAN or fail offline.
pulled=$(sed -n "/^readonly -a WORKSPACE_IMAGES=(/,/^)/p" "$overlay" | sed -n "s/^ *'\(.*\)'$/\1/p" | sort)
run=$(sed -n 's/^ *image *= *"\(.*\)"$/\1/p' "$backend" | sort -u)

test -n "$pulled" || { echo 'no images found in the overlay'; exit 1; }
test -n "$run" || { echo 'no images found in the docker backend'; exit 1; }

if [ "$pulled" != "$run" ]; then
    echo 'the overlay pre-pulls a different image set than the docker backend runs'
    diff <(printf '%s\n' "$pulled") <(printf '%s\n' "$run") || true
    exit 1
fi
echo 'PASS: the overlay pre-pulls exactly the images the desktop backend runs'

for image in $run; do
    case ${image##*/} in
        *:latest) echo "the desktop backend runs a latest tag: $image"; exit 1 ;;
        *:*) ;;
        *) echo "the desktop backend runs an untagged image: $image"; exit 1 ;;
    esac
done
echo 'PASS: every desktop workspace image carries a tag other than latest'
echo 'images tests passed'
