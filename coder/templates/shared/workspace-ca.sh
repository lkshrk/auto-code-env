#!/usr/bin/env sh

coder_export_workspace_ca() {
  set -- "${CODER_WORKSPACE_CA_PATH:-/etc/ssl/lan/lan-ca.pem}"
  [ -r "$1" ] || return 0
  [ -r /etc/ssl/certs/ca-certificates.crt ] || {
    printf '%s\n' 'System CA bundle is missing' >&2
    return 1
  }
  set -- "$1" "$HOME/.local/state/coder-environment/ca-bundle.pem"
  mkdir -p "$(dirname "$2")" || return 1
  export CODER_CA_INPUT_SSL_CERT_FILE="${CODER_CA_INPUT_SSL_CERT_FILE-${SSL_CERT_FILE:-}}"
  export CODER_CA_INPUT_NODE_EXTRA_CA_CERTS="${CODER_CA_INPUT_NODE_EXTRA_CA_CERTS-${NODE_EXTRA_CA_CERTS:-}}"
  export CODER_CA_INPUT_REQUESTS_CA_BUNDLE="${CODER_CA_INPUT_REQUESTS_CA_BUNDLE-${REQUESTS_CA_BUNDLE:-}}"
  export CODER_CA_INPUT_CURL_CA_BUNDLE="${CODER_CA_INPUT_CURL_CA_BUNDLE-${CURL_CA_BUNDLE:-}}"
  export CODER_CA_INPUT_GIT_SSL_CAINFO="${CODER_CA_INPUT_GIT_SSL_CAINFO-${GIT_SSL_CAINFO:-}}"
  set -- "$1" "$2" "$(mktemp "$(dirname "$2")/.ca-bundle.XXXXXX")"
  [ -n "$3" ] || return 1
  if ! (
    cat /etc/ssl/certs/ca-certificates.crt || exit 1
    printf '\n'
    cat "$1" || exit 1
    printf '\n'
    for certificate in "${CODER_CA_INPUT_SSL_CERT_FILE}" "${CODER_CA_INPUT_NODE_EXTRA_CA_CERTS}" "${CODER_CA_INPUT_REQUESTS_CA_BUNDLE}" "${CODER_CA_INPUT_CURL_CA_BUNDLE}" "${CODER_CA_INPUT_GIT_SSL_CAINFO}"; do
      if [ -n "$certificate" ] && [ "$certificate" != "$2" ] && [ "$certificate" != "$1" ] && [ "$certificate" != /etc/ssl/certs/ca-certificates.crt ]; then
        cat "$certificate" || exit 1
        printf '\n'
      fi
    done
  ) > "$3"; then
    rm -f "$3"
    return 1
  fi
  if [ -f "$2" ] && cmp -s "$3" "$2"; then
    rm -f "$3"
  else
    mv -T "$3" "$2" || { rm -f "$3"; return 1; }
  fi
  export CODER_WORKSPACE_CA_SOURCE="$1"
  export SSL_CERT_FILE="$2"
  export NODE_EXTRA_CA_CERTS="$2"
  export REQUESTS_CA_BUNDLE="$2"
  export CURL_CA_BUNDLE="$2"
  export GIT_SSL_CAINFO="$2"
}

coder_install_system_ca() (
  [ -n "${CODER_WORKSPACE_CA_SOURCE:-}" ] || return 0
  target=/usr/local/share/ca-certificates/lan-ca.crt
  if [ -r "$target" ] && cmp -s "$CODER_WORKSPACE_CA_SOURCE" "$target"; then
    return 0
  fi
  sudo -n install -m 0644 "$CODER_WORKSPACE_CA_SOURCE" "$target" || return 1
  sudo -n update-ca-certificates >/dev/null
)

coder_export_workspace_ca || exit 1
