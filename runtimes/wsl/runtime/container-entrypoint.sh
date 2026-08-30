#!/bin/bash
set -euo pipefail

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

if [ -n "${LOCAL_BACKEND_API_KEY:-}" ]; then
    api_key=$LOCAL_BACKEND_API_KEY
elif [ -n "${LOCAL_BACKEND_API_KEY_FILE:-}" ] && [ -r "$LOCAL_BACKEND_API_KEY_FILE" ]; then
    api_key=$(<"$LOCAL_BACKEND_API_KEY_FILE")
else
    fail 'LOCAL_BACKEND_API_KEY or LOCAL_BACKEND_API_KEY_FILE is required'
fi

[ -n "$api_key" ] || fail 'LOCAL_BACKEND_API_KEY must not be empty'
[ -f /etc/nginx/tls/tls.crt ] || fail 'missing TLS certificate'
[ -f /etc/nginx/tls/tls.key ] || fail 'missing TLS private key'

LOCAL_BACKEND_API_KEY=$api_key /usr/sbin/runuser -u agent -- /usr/bin/env -i \
    HOME=/home/agent PATH=/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin \
    LOCAL_BACKEND_API_KEY="$api_key" /home/agent/.local/bin/agent-canvas --public &
canvas_pid=$!
/usr/sbin/nginx -g 'daemon off;' &
nginx_pid=$!

shutdown() {
    /usr/bin/kill -TERM "$canvas_pid" "$nginx_pid" 2>/dev/null || true
    wait "$canvas_pid" 2>/dev/null || true
    wait "$nginx_pid" 2>/dev/null || true
}

trap 'shutdown; exit 0' INT TERM
if wait -n "$canvas_pid" "$nginx_pid"; then
    status=0
else
    status=$?
fi
shutdown
exit "$status"
