#!/usr/bin/env sh

coder_export_workspace_ca() {
  local source bundle temporary certificate
  source="${CODER_WORKSPACE_CA_PATH:-/etc/ssl/lan/lan-ca.pem}"
  [ -r "$source" ] || return 0
  [ -r /etc/ssl/certs/ca-certificates.crt ] || {
    printf '%s\n' 'System CA bundle is missing' >&2
    return 1
  }
  bundle="$HOME/.local/state/coder-environment/ca-bundle.pem"
  mkdir -p "$(dirname "$bundle")" || return 1
  export CODER_CA_INPUT_SSL_CERT_FILE="${CODER_CA_INPUT_SSL_CERT_FILE-${SSL_CERT_FILE:-}}"
  export CODER_CA_INPUT_NODE_EXTRA_CA_CERTS="${CODER_CA_INPUT_NODE_EXTRA_CA_CERTS-${NODE_EXTRA_CA_CERTS:-}}"
  export CODER_CA_INPUT_REQUESTS_CA_BUNDLE="${CODER_CA_INPUT_REQUESTS_CA_BUNDLE-${REQUESTS_CA_BUNDLE:-}}"
  export CODER_CA_INPUT_CURL_CA_BUNDLE="${CODER_CA_INPUT_CURL_CA_BUNDLE-${CURL_CA_BUNDLE:-}}"
  export CODER_CA_INPUT_GIT_SSL_CAINFO="${CODER_CA_INPUT_GIT_SSL_CAINFO-${GIT_SSL_CAINFO:-}}"
  temporary=$(mktemp "$(dirname "$bundle")/.ca-bundle.XXXXXX") || return 1
  if ! (
    cat /etc/ssl/certs/ca-certificates.crt || exit 1
    printf '\n'
    cat "$source" || exit 1
    printf '\n'
    for certificate in "${CODER_CA_INPUT_SSL_CERT_FILE}" "${CODER_CA_INPUT_NODE_EXTRA_CA_CERTS}" "${CODER_CA_INPUT_REQUESTS_CA_BUNDLE}" "${CODER_CA_INPUT_CURL_CA_BUNDLE}" "${CODER_CA_INPUT_GIT_SSL_CAINFO}"; do
      if [ -n "$certificate" ] && [ "$certificate" != "$bundle" ] && [ "$certificate" != "$source" ] && [ "$certificate" != /etc/ssl/certs/ca-certificates.crt ]; then
        cat "$certificate" || exit 1
        printf '\n'
      fi
    done
  ) > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  if [ -f "$bundle" ] && cmp -s "$temporary" "$bundle"; then
    rm -f "$temporary"
  else
    mv -T "$temporary" "$bundle" || { rm -f "$temporary"; return 1; }
  fi
  export CODER_WORKSPACE_CA_SOURCE="$source"
  export SSL_CERT_FILE="$bundle"
  export NODE_EXTRA_CA_CERTS="$bundle"
  export REQUESTS_CA_BUNDLE="$bundle"
  export CURL_CA_BUNDLE="$bundle"
  export GIT_SSL_CAINFO="$bundle"
}

coder_install_system_ca() {
  [ -n "${CODER_WORKSPACE_CA_SOURCE:-}" ] || return 0
  local target=/usr/local/share/ca-certificates/lan-ca.crt
  if [ -r "$target" ] && cmp -s "$CODER_WORKSPACE_CA_SOURCE" "$target"; then
    return 0
  fi
  sudo -n install -m 0644 "$CODER_WORKSPACE_CA_SOURCE" "$target" || return 1
  sudo -n update-ca-certificates >/dev/null
}

coder_export_workspace_ca || exit 1
