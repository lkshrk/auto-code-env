#!/bin/sh
set -eu

PINENTRY=/usr/local/libexec/openhands-rbw-pinentry
TLS_DIRECTORY=/etc/nginx/tls
TLS_CERTIFICATE="$TLS_DIRECTORY/tls.crt"
TLS_KEY="$TLS_DIRECTORY/tls.key"
CREDSTORE=/etc/credstore
BACKEND_KEY="$CREDSTORE/local_backend_api_key"
MASTER_PASSWORD_FILE=/run/openhands-rbw-master

usage() {
    cat >&2 <<'EOF'
usage: openhands-overlay secrets --vault-url URL --email EMAIL --crt-id UUID --key-id UUID --api-id UUID
       openhands-overlay verify
       openhands-overlay enable
       openhands-overlay status
EOF
    exit 2
}

fail() {
    printf 'openhands-overlay: %s\n' "$1" >&2
    exit 1
}

require_root() {
    [ "$(id -u)" = 0 ] || fail 'must run as root'
}

is_uuid() {
    printf '%s' "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

secrets() {
    vault_url='' email='' crt_id='' key_id='' api_id=''
    while [ $# -gt 0 ]; do
        case $1 in
            --vault-url) vault_url=${2:-}; shift 2 ;;
            --email) email=${2:-}; shift 2 ;;
            --crt-id) crt_id=${2:-}; shift 2 ;;
            --key-id) key_id=${2:-}; shift 2 ;;
            --api-id) api_id=${2:-}; shift 2 ;;
            *) usage ;;
        esac
    done
    case $vault_url in https://*) ;; *) fail 'vault URL must be absolute HTTPS' ;; esac
    [ -n "$email" ] || fail 'email is required'
    for id in "$crt_id" "$key_id" "$api_id"; do
        is_uuid "$id" || fail 'item ids must be lowercase UUIDs'
    done
    [ -x "$PINENTRY" ] || fail 'image pinentry missing'

    umask 077
    mkdir -p /root/.config/rbw
    rbw config set base_url "$vault_url"
    rbw config set email "$email"
    rbw config set pinentry "$PINENTRY"
    rbw config set lock_timeout 300

    trap 'rm -f "$MASTER_PASSWORD_FILE"' EXIT INT TERM
    systemd-ask-password --echo=no "Vaultwarden master password for $email:" | tr -d '\n' > "$MASTER_PASSWORD_FILE"
    [ -s "$MASTER_PASSWORD_FILE" ] || fail 'empty master password'

    # shellcheck disable=SC2016
    systemd-run --quiet --pipe --wait --collect \
        -E HOME=/root -E USER=root \
        -E OVERLAY_CRT_ID="$crt_id" -E OVERLAY_KEY_ID="$key_id" -E OVERLAY_API_ID="$api_id" \
        -p "LoadCredential=rbw_master:$MASTER_PASSWORD_FILE" \
        /bin/sh -eu -c '
            umask 077
            rbw login
            rbw sync
            install -d -o root -g root -m 0755 /etc/nginx/tls
            install -d -o root -g root -m 0700 /etc/credstore
            rbw get --field notes "$OVERLAY_CRT_ID" > /etc/nginx/tls/tls.crt
            rbw get --field notes "$OVERLAY_KEY_ID" > /etc/nginx/tls/tls.key
            rbw get "$OVERLAY_API_ID" | tr -d "\n" > /etc/credstore/local_backend_api_key
            chown root:root /etc/nginx/tls/tls.crt /etc/nginx/tls/tls.key /etc/credstore/local_backend_api_key
            chmod 0644 /etc/nginx/tls/tls.crt
            chmod 0600 /etc/nginx/tls/tls.key /etc/credstore/local_backend_api_key
            rbw lock
            rbw stop-agent
            rbw purge
        '
    rm -f "$MASTER_PASSWORD_FILE"
    trap - EXIT INT TERM
    verify
}

assert_file() {
    path=$1 mode=$2
    [ -f "$path" ] || fail "missing $path"
    [ "$(stat -c '%U:%G %a' "$path")" = "root:root $mode" ] || fail "wrong owner or mode on $path"
}

verify() {
    assert_file "$TLS_CERTIFICATE" 644
    assert_file "$TLS_KEY" 600
    assert_file "$BACKEND_KEY" 600
    [ "$(stat -c '%U:%G %a' "$CREDSTORE")" = 'root:root 700' ] || fail "wrong owner or mode on $CREDSTORE"
    subject=$(openssl x509 -in "$TLS_CERTIFICATE" -noout -subject) || fail 'unreadable certificate'
    certificate_key=$(openssl x509 -in "$TLS_CERTIFICATE" -noout -pubkey) || fail 'unreadable certificate public key'
    private_key=$(openssl pkey -in "$TLS_KEY" -pubout) || fail 'unreadable private key'
    [ "$certificate_key" = "$private_key" ] || fail 'private key does not match certificate'
    [ "$(wc -c < "$BACKEND_KEY")" -ge 32 ] || fail 'backend key shorter than 32 bytes'
    nginx -t >/dev/null 2>&1 || fail 'nginx configuration test failed'
    printf 'tls: %s\n' "$subject"
    openssl x509 -in "$TLS_CERTIFICATE" -noout -enddate
    printf 'backend key: %s bytes\n' "$(wc -c < "$BACKEND_KEY")"
    echo 'overlay verified'
}

enable_services() {
    verify
    systemctl enable --now nginx.service agent-canvas.service
    status
}

status() {
    systemctl is-active nginx.service agent-canvas.service || true
    cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | while read -r _ local _ state _; do
        [ "$state" = 0A ] && printf 'listen %s:%d\n' "${local%:*}" "0x${local#*:}"
    done | sort -u
}

require_root
command=${1:-}
[ $# -gt 0 ] && shift
case $command in
    secrets) secrets "$@" ;;
    verify) [ $# -eq 0 ] || usage; verify ;;
    enable) [ $# -eq 0 ] || usage; enable_services ;;
    status) [ $# -eq 0 ] || usage; status ;;
    *) usage ;;
esac
