#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
generator="$repo_root/coder/worker/tools/gen-docker-tls.sh"
fixture_image=auto-code-env-coder-worker-fixture:ubuntu-26.04

test -f "$generator"
if git -C "$repo_root" ls-files --error-unmatch \
  'coder/worker/**/*.pem' 'coder/worker/**/*key*' >/dev/null 2>&1; then
  echo 'no trust material may be committed under coder/worker'; exit 1
fi

if ! docker image inspect "$fixture_image" >/dev/null 2>&1; then
  printf '%s\n' \
    'FROM ubuntu:26.04' \
    'RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl openssl python3 iproute2 && rm -rf /var/lib/apt/lists/*' \
    'RUN mkdir -p /opt/fixture && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /opt/fixture/docker.asc' |
    docker build --quiet --tag "$fixture_image" -
fi

script=$(cat <<'INNER'
set -euo pipefail
generator=/src/coder/worker/tools/gen-docker-tls.sh

if bash "$generator" --out /src/coder/worker/generated >/dev/null 2>&1; then
  echo 'the generator must refuse to write inside the repository'; exit 1
fi
test ! -e /src/coder/worker/generated
if bash "$generator" >/dev/null 2>&1; then echo '--out is mandatory'; exit 1; fi
for bad in '--server-ip 999.1.1.1' '--server-ip 172.16.20.195/24' '--server-dns bad_name' '--ca-cn a/b'; do
  # shellcheck disable=SC2086
  if bash "$generator" --out /tmp/rejected $bad >/dev/null 2>&1; then
    echo "the generator must reject: $bad"; exit 1
  fi
done
echo 'PASS: the generator validates its inputs and never writes into the repository'

bash "$generator" --out /tmp/tls >/dev/null
if bash "$generator" --out /tmp/tls >/dev/null 2>&1; then
  echo 'the generator must refuse a non-empty output directory'; exit 1
fi
test "$(stat -c %a /tmp/tls)" = 700
for key in ca-key.pem server-key.pem client-key.pem; do
  test "$(stat -c '%a' "/tmp/tls/$key")" = 600
  openssl pkey -in "/tmp/tls/$key" -noout -text | grep -Fq 'NIST CURVE: P-256'
done
for certificate in ca.pem server-cert.pem client-cert.pem; do
  test "$(stat -c '%a' "/tmp/tls/$certificate")" = 644
done
openssl verify -CAfile /tmp/tls/ca.pem /tmp/tls/server-cert.pem /tmp/tls/client-cert.pem >/dev/null

while read -r certificate key; do
  test "$(openssl x509 -in "/tmp/tls/$certificate.pem" -noout -pubkey)" = "$(openssl pkey -in "/tmp/tls/$key.pem" -pubout)"
done <<'PAIRS'
ca ca-key
server-cert server-key
client-cert client-key
PAIRS

openssl x509 -in /tmp/tls/ca.pem -noout -text > /tmp/ca.txt
grep -Fq 'CA:TRUE, pathlen:0' /tmp/ca.txt
grep -A1 -F 'X509v3 Key Usage: critical' /tmp/ca.txt | grep -Fq 'Certificate Sign, CRL Sign'

openssl x509 -in /tmp/tls/server-cert.pem -noout -text > /tmp/server.txt
grep -Fq 'CA:FALSE' /tmp/server.txt
grep -A1 -F 'X509v3 Extended Key Usage' /tmp/server.txt | grep -Fq 'TLS Web Server Authentication'
grep -Fq 'IP Address:172.16.20.195' /tmp/server.txt
grep -Fq 'DNS:coder-worker.h-cloud.lan' /tmp/server.txt

openssl x509 -in /tmp/tls/client-cert.pem -noout -text > /tmp/client.txt
grep -A1 -F 'X509v3 Extended Key Usage' /tmp/client.txt | grep -Fq 'TLS Web Client Authentication'
if grep -Fq 'X509v3 Subject Alternative Name' /tmp/client.txt; then
  echo 'the client certificate must carry no subject alternative name'; exit 1
fi

ca_end=$(date -d "$(openssl x509 -in /tmp/tls/ca.pem -noout -enddate | cut -d= -f2)" +%s)
server_end=$(date -d "$(openssl x509 -in /tmp/tls/server-cert.pem -noout -enddate | cut -d= -f2)" +%s)
now=$(date +%s)
test "$(( (ca_end - now) / 86400 ))" -gt 3600
test "$(( (server_end - now) / 86400 ))" -gt 700
test "$(( (server_end - now) / 86400 ))" -lt 740
echo 'PASS: a ten-year CA signs two-year leaves'

bash "$generator" --out /tmp/custom --server-ip 10.1.2.3 --server-ip 10.1.2.4 \
  --server-dns docker.example --client-cn other-coderd >/dev/null
openssl x509 -in /tmp/custom/server-cert.pem -noout -text > /tmp/custom-server.txt
grep -Fq 'IP Address:10.1.2.3, IP Address:10.1.2.4, DNS:docker.example' /tmp/custom-server.txt
openssl x509 -in /tmp/custom/client-cert.pem -noout -subject | grep -Fq 'CN=other-coderd'
echo 'PASS: subject alternative names and common names are parameterized'
INNER
)

docker run --rm \
  --volume "$repo_root:/src:ro" \
  "$fixture_image" bash -c "$script"
echo 'gen-docker-tls tests passed'
