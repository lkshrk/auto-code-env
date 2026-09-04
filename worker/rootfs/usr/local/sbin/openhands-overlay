#!/bin/sh
# shellcheck disable=SC2016
set -eu

PINENTRY=/usr/local/libexec/openhands-rbw-pinentry
TLS_DIRECTORY=/etc/nginx/tls
TLS_CERTIFICATE="$TLS_DIRECTORY/tls.crt"
TLS_KEY="$TLS_DIRECTORY/tls.key"
CREDSTORE=/etc/credstore
BACKEND_KEY="$CREDSTORE/local_backend_api_key"
MASTER_PASSWORD_FILE=/run/openhands-rbw-master
SERVICE_DROPIN=/etc/systemd/system/agent-canvas.service.d/10-overlay.conf
RELEASE_MARKER=/etc/openhands/release
RBW_CONFIG=/root/.config/rbw/config.json
AGENT_HOME=/home/agent
GIT_CREDENTIALS=/home/agent/.git-credentials

usage() {
    cat >&2 <<'EOF'
usage: openhands-overlay secrets --vault-url URL --email EMAIL --crt-id UUID --key-id UUID --api-id UUID
       openhands-overlay github --pat-id UUID [--vault-url URL --email EMAIL]
       openhands-overlay origin https://canvas.example [https://other.example ...]
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

configure_rbw() {
    vault_url=$1 email=$2
    if [ -z "$vault_url" ] && [ -z "$email" ]; then
        [ -f "$RBW_CONFIG" ] || fail 'rbw is not configured yet; pass --vault-url and --email'
        return
    fi
    case $vault_url in https://*) ;; *) fail 'vault URL must be absolute HTTPS' ;; esac
    [ -n "$email" ] || fail 'email is required'
    [ -x "$PINENTRY" ] || fail 'image pinentry missing'
    umask 077
    mkdir -p "$(dirname "$RBW_CONFIG")"
    rbw config set base_url "$vault_url"
    rbw config set email "$email"
    rbw config set pinentry "$PINENTRY"
    rbw config set lock_timeout 300
}

# vault_run ENV_ASSIGNMENT... -- SCRIPT
# Runs SCRIPT as root inside one transient unit with an unlocked rbw; the master
# password lives only in a root tmpfs file for the duration.
vault_run() {
    set -- "$@"
    env_args=""
    while [ $# -gt 0 ]; do
        case $1 in
            --) shift; break ;;
            *) env_args="$env_args -E $1"; shift ;;
        esac
    done
    [ $# -eq 1 ] || fail 'vault_run needs exactly one script'
    umask 077
    trap 'rm -f "$MASTER_PASSWORD_FILE"' EXIT INT TERM
    systemd-ask-password --echo=no 'Vaultwarden master password:' | tr -d '\n' > "$MASTER_PASSWORD_FILE"
    [ -s "$MASTER_PASSWORD_FILE" ] || fail 'empty master password'
    # shellcheck disable=SC2086
    systemd-run --quiet --pipe --wait --collect \
        -E HOME=/root -E USER=root $env_args \
        -E OVERLAY_SCRIPT="$1" \
        -p "LoadCredential=rbw_master:$MASTER_PASSWORD_FILE" \
        /bin/sh -eu -c 'umask 077; rbw login; rbw sync; sh -eu -c "$OVERLAY_SCRIPT"; rbw lock; rbw stop-agent; rbw purge'
    rm -f "$MASTER_PASSWORD_FILE"
    trap - EXIT INT TERM
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
    for id in "$crt_id" "$key_id" "$api_id"; do
        is_uuid "$id" || fail 'item ids must be lowercase UUIDs'
    done
    configure_rbw "$vault_url" "$email"
    vault_run "OVERLAY_CRT_ID=$crt_id" "OVERLAY_KEY_ID=$key_id" "OVERLAY_API_ID=$api_id" -- '
        install -d -o root -g root -m 0755 /etc/nginx/tls
        install -d -o root -g root -m 0700 /etc/credstore
        rbw get --field notes "$OVERLAY_CRT_ID" > /etc/nginx/tls/tls.crt
        rbw get --field notes "$OVERLAY_KEY_ID" > /etc/nginx/tls/tls.key
        rbw get "$OVERLAY_API_ID" | tr -d "\n" > /etc/credstore/local_backend_api_key
        chown root:root /etc/nginx/tls/tls.crt /etc/nginx/tls/tls.key /etc/credstore/local_backend_api_key
        chmod 0644 /etc/nginx/tls/tls.crt
        chmod 0600 /etc/nginx/tls/tls.key /etc/credstore/local_backend_api_key
    '
    verify
}

github() {
    vault_url='' email='' pat_id=''
    while [ $# -gt 0 ]; do
        case $1 in
            --vault-url) vault_url=${2:-}; shift 2 ;;
            --email) email=${2:-}; shift 2 ;;
            --pat-id) pat_id=${2:-}; shift 2 ;;
            *) usage ;;
        esac
    done
    is_uuid "$pat_id" || fail '--pat-id must be a lowercase UUID'
    id agent >/dev/null 2>&1 || fail 'agent user missing'
    configure_rbw "$vault_url" "$email"
    vault_run "OVERLAY_PAT_ID=$pat_id" "OVERLAY_GIT_CREDENTIALS=$GIT_CREDENTIALS" -- '
        token=$(rbw get "$OVERLAY_PAT_ID" | tr -d "\n")
        [ -n "$token" ] || { echo "empty GitHub token" >&2; exit 1; }
        printf "https://x-access-token:%s@github.com\n" "$token" > "$OVERLAY_GIT_CREDENTIALS.tmp"
        chown agent:agent "$OVERLAY_GIT_CREDENTIALS.tmp"
        chmod 0600 "$OVERLAY_GIT_CREDENTIALS.tmp"
        mv -f "$OVERLAY_GIT_CREDENTIALS.tmp" "$OVERLAY_GIT_CREDENTIALS"
    '
    runuser -u agent -- env HOME="$AGENT_HOME" git config --global credential.helper store
    [ "$(stat -c '%U:%G %a' "$GIT_CREDENTIALS")" = 'agent:agent 600' ] || fail 'wrong owner or mode on git credentials'
    echo 'github credential installed for agent'
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

origin() {
    [ $# -ge 1 ] || usage
    for value in "$@"; do
        printf '%s' "$value" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]+)?$' || fail "origin must be https://host[:port] without a path: $value"
    done
    umask 022
    install -d -o root -g root -m 0755 "$(dirname "$SERVICE_DROPIN")"
    {
        echo '[Service]'
        index=0
        for value in "$@"; do
            printf 'Environment=OH_ALLOW_CORS_ORIGINS_%s=%s\n' "$index" "$value"
            index=$((index + 1))
        done
    } > "$SERVICE_DROPIN"
    chown root:root "$SERVICE_DROPIN"
    chmod 0644 "$SERVICE_DROPIN"
    systemctl daemon-reload
    systemctl try-restart agent-canvas.service
    for value in "$@"; do
        printf 'origin %s\n' "$value"
    done
}

status() {
    if [ -r "$RELEASE_MARKER" ]; then
        printf 'release %s\n' "$(cat "$RELEASE_MARKER")"
    else
        echo 'release unknown (no marker)'
    fi
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
    github) github "$@" ;;
    verify) [ $# -eq 0 ] || usage; verify ;;
    enable) [ $# -eq 0 ] || usage; enable_services ;;
    origin) origin "$@" ;;
    status) [ $# -eq 0 ] || usage; status ;;
    *) usage ;;
esac
