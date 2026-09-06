#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly CURVE=prime256v1
readonly CA_DAYS=3650
readonly LEAF_DAYS=730

out_directory=''
ca_common_name='coder-worker docker CA'
server_common_name='coder-worker'
client_common_name='coderd'
server_ips=()
server_dns_names=()

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly script_directory
repository_root=$(cd -- "$script_directory" && until [ -e .git ]; do [ "$PWD" = / ] && exit 0; cd ..; done && pwd)
readonly repository_root

usage() {
    cat >&2 <<'EOF'
usage: gen-docker-tls.sh --out DIR [--server-ip IP]... [--server-dns NAME]...
                         [--ca-cn NAME] [--server-cn NAME] [--client-cn NAME]

Generates one ECDSA P-256 certificate authority, one server certificate for the
coder-worker Docker daemon, and one client certificate for coderd. Everything is
written into DIR, which must be new or empty and outside this repository.
EOF
    exit 2
}

fail() {
    printf 'gen-docker-tls: %s\n' "$1" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case $1 in
        --out) out_directory=${2:-}; shift 2 ;;
        --server-ip) server_ips+=("${2:-}"); shift 2 ;;
        --server-dns) server_dns_names+=("${2:-}"); shift 2 ;;
        --ca-cn) ca_common_name=${2:-}; shift 2 ;;
        --server-cn) server_common_name=${2:-}; shift 2 ;;
        --client-cn) client_common_name=${2:-}; shift 2 ;;
        *) usage ;;
    esac
done

[ -n "$out_directory" ] || usage
[ "${#server_ips[@]}" -gt 0 ] || server_ips=(172.16.20.195)
[ "${#server_dns_names[@]}" -gt 0 ] || server_dns_names=(coder-worker.h-cloud.lan)

for name in "$ca_common_name" "$server_common_name" "$client_common_name"; do
    case $name in
        '' | */* | *,*) fail "invalid common name: $name" ;;
    esac
done
for address in "${server_ips[@]}"; do
    printf '%s' "$address" |
        grep -Eq '^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}$' ||
        fail "invalid IPv4 address: $address"
done
for name in "${server_dns_names[@]}"; do
    printf '%s' "$name" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' || fail "invalid DNS name: $name"
done

parent=$(cd -- "$(dirname -- "$out_directory")" && pwd) || fail "unable to resolve $(dirname -- "$out_directory")"
resolved="${parent}/$(basename -- "$out_directory")"
if [ -n "$repository_root" ]; then
    case $resolved in
        "$repository_root" | "$repository_root"/*) fail 'refusing to write trust material inside the repository' ;;
    esac
fi
if [ -e "$resolved" ]; then
    [ -d "$resolved" ] || fail "$resolved exists and is not a directory"
    [ -z "$(ls -A "$resolved")" ] || fail "$resolved is not empty"
else
    mkdir "$resolved"
fi
chmod 0700 "$resolved"

subject_alt_name=$(
    {
        for address in "${server_ips[@]}"; do printf 'IP:%s\n' "$address"; done
        for name in "${server_dns_names[@]}"; do printf 'DNS:%s\n' "$name"; done
    } | paste -sd, -
)

openssl version | grep -q '^OpenSSL ' || fail 'OpenSSL is required; LibreSSL does not support -addext'

work=$(mktemp -d) || fail 'unable to create a working directory'
trap 'rm -rf "$work"' EXIT INT TERM

openssl ecparam -name "$CURVE" -genkey -noout -out "$resolved/ca-key.pem"
openssl req -x509 -new -key "$resolved/ca-key.pem" -sha256 -days "$CA_DAYS" \
    -subj "/CN=${ca_common_name}" \
    -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -addext 'subjectKeyIdentifier=hash' \
    -out "$resolved/ca.pem"

issue_leaf() {
    local name=$1 common_name=$2 extensions=$3

    openssl ecparam -name "$CURVE" -genkey -noout -out "$resolved/${name}-key.pem"
    openssl req -new -key "$resolved/${name}-key.pem" -subj "/CN=${common_name}" -out "$work/${name}.csr"
    printf '%s\n' "$extensions" > "$work/${name}.ext"
    openssl x509 -req -in "$work/${name}.csr" -CA "$resolved/ca.pem" -CAkey "$resolved/ca-key.pem" \
        -CAcreateserial -CAserial "$work/ca.srl" -days "$LEAF_DAYS" -sha256 \
        -extfile "$work/${name}.ext" -out "$resolved/${name}-cert.pem"
}

issue_leaf server "$server_common_name" "basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=${subject_alt_name}
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer"

issue_leaf client "$client_common_name" "basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer"

chmod 0600 "$resolved"/*-key.pem
chmod 0644 "$resolved"/ca.pem "$resolved"/server-cert.pem "$resolved"/client-cert.pem

openssl verify -CAfile "$resolved/ca.pem" "$resolved/server-cert.pem" "$resolved/client-cert.pem" > /dev/null ||
    fail 'the generated leaf certificates do not verify against the generated CA'

cat <<EOF
Wrote ECDSA P-256 trust material to $resolved

Vaultwarden (one item per file, PEM in the item notes, referenced by UUID):
  ca.pem           --ca-id
  server-cert.pem  --crt-id
  server-key.pem   --key-id

h-cloud SOPS secret coder-docker-tls (kubernetes/apps/coder/coder/app/coder-docker-tls.sops.yaml):
  ca.pem           -> stringData key ca.pem
  client-cert.pem  -> stringData key cert.pem
  client-key.pem   -> stringData key key.pem

ca-key.pem signs replacements for both leaves. It belongs in neither the distro
nor the cluster; keep it offline and delete $resolved once both halves are
stored.
EOF
