#!/bin/sh
# Keeps the DinD data volume from filling: unused anonymous volumes always go, more as usage rises.

set -u

: "${DIND_DATA:=/var/lib/docker}"
: "${DIND_CLEANUP_INTERVAL:=300}"
: "${DIND_PRUNE_AT:=75}"
: "${DIND_PURGE_AT:=90}"

docker() { command docker -H unix:///var/run/docker.sock "$@"; }

used() { df -P "$DIND_DATA" | awk 'NR == 2 { sub("%", "", $5); print $5 }'; }

pass() {
  docker info >/dev/null 2>&1 || return 0
  before=$(used)
  level=volumes
  docker volume prune -f >/dev/null
  if [ "$(used)" -ge "$DIND_PRUNE_AT" ]; then
    level=prune
    docker system prune -f >/dev/null
    docker builder prune -f --keep-storage 5GB >/dev/null
  fi
  if [ "$(used)" -ge "$DIND_PURGE_AT" ]; then
    level=purge
    docker system prune -af >/dev/null
  fi
  after=$(used)
  if [ "$level" != volumes ] || [ "$after" != "$before" ]; then
    echo "dind-cleanup: $level, ${before}% -> ${after}% used"
  fi
}

if [ "${1:-}" = --once ]; then
  pass
  exit 0
fi

while :; do
  pass
  sleep "$DIND_CLEANUP_INTERVAL"
done
