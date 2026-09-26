#!/usr/bin/env bash

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../shared/dind-cleanup.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"
export PATH="$TEST_ROOT/bin:$PATH" STATE="$TEST_ROOT"

# Stand-ins: df reports the percentage in $STATE/used; docker logs its call and frees $STATE/frees per prune.
cat > "$TEST_ROOT/bin/df" <<'SH'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/rbd0 100 1 1 %s%% /var/lib/docker\n' "$(cat "$STATE/used")"
SH
cat > "$TEST_ROOT/bin/docker" <<'SH'
#!/bin/sh
[ "$1" = -H ] && shift 2
[ "$1" = info ] && exit 0
echo "$*" >> "$STATE/calls"
case "$*" in *prune*) echo $(( $(cat "$STATE/used") - $(cat "$STATE/frees") )) > "$STATE/used" ;; esac
SH
chmod 0755 "$TEST_ROOT/bin/df" "$TEST_ROOT/bin/docker"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

run() {
  echo "$1" > "$TEST_ROOT/used"
  echo "$2" > "$TEST_ROOT/frees"
  : > "$TEST_ROOT/calls"
  sh "$SCRIPT" --once > "$TEST_ROOT/out"
}

run 40 0
[ "$(cat "$TEST_ROOT/calls")" = "volume prune -f" ] || fail "below the threshold only anonymous volumes are pruned"
[ ! -s "$TEST_ROOT/out" ] || fail "a pass that frees nothing stays quiet"

run 40 5
grep -q 'volumes, 40% -> 35% used' "$TEST_ROOT/out" || fail "freed space is logged"

run 80 0
grep -qx 'system prune -f' "$TEST_ROOT/calls" || fail "at 75% stopped containers, dangling images and cache go"
grep -qx 'builder prune -f --keep-storage 5GB' "$TEST_ROOT/calls" || fail "at 75% the build cache shrinks"
! grep -q 'prune -af' "$TEST_ROOT/calls" || fail "below 90% images in use by nothing are kept"

run 80 10
[ "$(wc -l < "$TEST_ROOT/calls")" -eq 1 ] || fail "when the volume prune is enough nothing else runs"

run 95 0
grep -qx 'system prune -af' "$TEST_ROOT/calls" || fail "at 90% every unused image goes"
grep -q 'purge, 95% -> 95% used' "$TEST_ROOT/out" || fail "a purge is always logged"

printf 'PASS: dind-cleanup escalates with disk usage\n'
