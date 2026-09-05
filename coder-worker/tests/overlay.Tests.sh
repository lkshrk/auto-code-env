#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
overlay="$repo_root/coder-worker/wsl/coder-worker-overlay"
fixture_image=auto-code-env-coder-worker-fixture:ubuntu-26.04

test -f "$overlay"
grep -Fq 'LoadCredential=rbw_master:' "$overlay"
grep -Fq 'rbw purge' "$overlay"
grep -Fq 'systemd-ask-password --echo=no' "$overlay"
grep -Fq 'PLAINTEXT_PORT=2375' "$overlay"
if grep -Eq 'echo .*\$OVERLAY_|printf .*server-key' "$overlay"; then
  echo 'the overlay must never print secret material'; exit 1
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
umask 022
. /src/coder-worker/tests/fixture.sh
fixture_install_host_stubs
fixture_install_shims

mkdir -p /root/coder-worker
install -m 0644 /src/coder-worker/wsl/setup.sh /root/coder-worker/setup.sh
install -m 0644 /src/coder-worker/wsl/coder-worker-overlay /root/coder-worker/coder-worker-overlay
bash /root/coder-worker/setup.sh > /tmp/setup.log

bash /src/coder-worker/scripts/gen-docker-tls.sh --out /tmp/tls > /dev/null
bash /src/coder-worker/scripts/gen-docker-tls.sh --out /tmp/other --ca-cn 'other CA' > /dev/null
printf 'hunter2' > /tmp/fixture.master

cat > /usr/bin/rbw <<'EOF'
#!/bin/sh
echo "rbw $*" >> /tmp/log/rbw
case "$1" in
  config) mkdir -p /root/.config/rbw; touch /root/.config/rbw/config.json; exit 0 ;;
  login|sync|lock|stop-agent|purge)
    test -n "${CREDENTIALS_DIRECTORY:-}" || { echo 'no credentials directory' >&2; exit 1; }
    test "$(cat "$CREDENTIALS_DIRECTORY/rbw_master")" = "$(cat /tmp/fixture.master)" || { echo 'wrong master' >&2; exit 1; }
    exit 0 ;;
  get)
    case "$*" in
      "get --field notes 11111111-1111-1111-1111-111111111111") cat /tmp/tls/ca.pem ;;
      "get --field notes 22222222-2222-2222-2222-222222222222") cat /tmp/tls/server-cert.pem ;;
      "get --field notes 33333333-3333-3333-3333-333333333333") cat /tmp/tls/server-key.pem ;;
      "get --field notes 44444444-4444-4444-4444-444444444444") cat /tmp/other/ca.pem ;;
      "get --field notes 55555555-5555-5555-5555-555555555555") cat /tmp/other/server-key.pem ;;
      "get --field notes 66666666-6666-6666-6666-666666666666") cat /tmp/other/server-cert.pem ;;
      *) echo "unknown item $*" >&2; exit 1 ;;
    esac ;;
  *) echo "unexpected rbw $*" >&2; exit 1 ;;
esac
EOF
chmod 0755 /usr/bin/rbw

start_listener() {
  port=$1
  python3 -c "
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', $port))
s.listen()
time.sleep(600)
" &
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    if coder-worker-overlay status > /tmp/listener.log 2>/dev/null && grep -qx "listen $port" /tmp/listener.log; then
      return
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  echo "listener on $port never came up"; exit 1
}

run() { coder-worker-overlay "$@"; }

if run verify >/dev/null 2>&1; then echo 'verify must fail before secrets exist'; exit 1; fi
if run enable >/dev/null 2>&1; then echo 'enable must fail before secrets exist'; exit 1; fi
if run secrets --vault-url http://vault.example --email a@b --ca-id 11111111-1111-1111-1111-111111111111 --crt-id 22222222-2222-2222-2222-222222222222 --key-id 33333333-3333-3333-3333-333333333333 --lan-ca-id 44444444-4444-4444-4444-444444444444 >/dev/null 2>&1; then
  echo 'a plain HTTP vault must be rejected'; exit 1
fi
if run secrets --vault-url https://vault.example --email a@b --ca-id nope --crt-id 22222222-2222-2222-2222-222222222222 --key-id 33333333-3333-3333-3333-333333333333 --lan-ca-id 44444444-4444-4444-4444-444444444444 >/dev/null 2>&1; then
  echo 'a non-UUID item id must be rejected'; exit 1
fi
test ! -e /tmp/log/systemd-run
echo 'PASS: the overlay refuses to run before it is configured'

output=$(run secrets --vault-url https://vault.example --email a@b \
  --ca-id 11111111-1111-1111-1111-111111111111 \
  --crt-id 22222222-2222-2222-2222-222222222222 \
  --key-id 33333333-3333-3333-3333-333333333333 \
  --lan-ca-id 44444444-4444-4444-4444-444444444444)
printf '%s\n' "$output" | grep -Fq 'overlay verified'
printf '%s\n' "$output" | grep -Fq 'IP Address:172.16.20.195'
if printf '%s\n' "$output" | grep -Eq 'PRIVATE KEY'; then echo 'key material leaked to stdout'; exit 1; fi

test "$(stat -c '%U:%G %a' /etc/docker/tls)" = 'root:root 700'
test "$(stat -c '%U:%G %a' /etc/docker/tls/ca.pem)" = 'root:root 644'
test "$(stat -c '%U:%G %a' /etc/docker/tls/server-cert.pem)" = 'root:root 644'
test "$(stat -c '%U:%G %a' /etc/docker/tls/server-key.pem)" = 'root:root 600'
test "$(stat -c '%U:%G %a' /etc/ssl/lan/lan-ca.pem)" = 'root:root 644'
test -f /etc/ssl/lan/lan-ca.pem
cmp -s /tmp/tls/ca.pem /etc/docker/tls/ca.pem
cmp -s /tmp/tls/server-cert.pem /etc/docker/tls/server-cert.pem
cmp -s /tmp/tls/server-key.pem /etc/docker/tls/server-key.pem
cmp -s /tmp/other/ca.pem /etc/ssl/lan/lan-ca.pem
test ! -e /run/coder-worker-rbw-master
grep -Fq 'LoadCredential=rbw_master:/run/coder-worker-rbw-master' /tmp/log/systemd-run
test "$(grep -c '^rbw login$' /tmp/log/rbw)" = 1
test "$(tail -n 1 /tmp/log/rbw)" = 'rbw purge'
grep -Fq 'rbw config set pinentry /usr/local/libexec/coder-worker-rbw-pinentry' /tmp/log/rbw
login_line=$(grep -n '^rbw login$' /tmp/log/rbw | cut -d: -f1)
first_get=$(grep -n '^rbw get ' /tmp/log/rbw | head -n 1 | cut -d: -f1)
test "$login_line" -lt "$first_get"
echo 'PASS: trust material is fetched in one transient vault session'

: > /tmp/log/rbw
if run secrets --vault-url https://vault.example --email a@b \
  --ca-id 11111111-1111-1111-1111-111111111111 \
  --crt-id 22222222-2222-2222-2222-222222222222 \
  --key-id 33333333-3333-3333-3333-333333333333 \
  --lan-ca-id 99999999-9999-9999-9999-999999999999 >/dev/null 2>&1; then
  echo 'secrets must fail when a vault item is missing'; exit 1
fi
test "$(tail -n 3 /tmp/log/rbw | tr '\n' ' ')" = 'rbw lock rbw stop-agent rbw purge '
test -z "$(find /etc/docker/tls /etc/ssl/lan -name '*.tmp')"
cmp -s /tmp/tls/ca.pem /etc/docker/tls/ca.pem
cmp -s /tmp/tls/server-cert.pem /etc/docker/tls/server-cert.pem
cmp -s /tmp/tls/server-key.pem /etc/docker/tls/server-key.pem
cmp -s /tmp/other/ca.pem /etc/ssl/lan/lan-ca.pem
test ! -e /run/coder-worker-rbw-master
echo 'PASS: a failed fetch still locks and purges the vault and leaves the trust material untouched'

: > /tmp/docker-up
start_listener 2376
run enable > /tmp/enable.log
enable_output=$(cat /tmp/enable.log)
printf '%s\n' "$enable_output" | grep -qx 'listen 2376'
printf '%s\n' "$enable_output" | grep -Fq 'listening on 2376 with mutual TLS'
grep -Fq 'systemctl enable --now docker.socket docker.service' /tmp/log/systemctl
grep -Fq 'docker image pull -- codercom/enterprise-base:ubuntu' /tmp/log/docker
grep -Fq 'docker image pull -- docker:27-dind' /tmp/log/docker
echo 'PASS: enable starts docker and confirms the mutual-TLS listener'

start_listener 2375
if run enable > /tmp/plaintext.log 2>&1; then echo 'enable must refuse a plaintext listener'; exit 1; fi
grep -Fq 'plaintext docker listener is present on 2375' /tmp/plaintext.log
echo 'PASS: a plaintext listener fails enable'

run status > /tmp/status.log
grep -Fq 'release coder-worker ' /tmp/status.log
grep -qx 'listen 2376' /tmp/status.log

mv /etc/ssl/lan/lan-ca.pem /tmp/lan-ca.pem
mkdir /etc/ssl/lan/lan-ca.pem
if run verify >/dev/null 2>&1; then echo 'verify must reject a directory in place of lan-ca.pem'; exit 1; fi
if run secrets --vault-url https://vault.example --email a@b \
  --ca-id 11111111-1111-1111-1111-111111111111 \
  --crt-id 22222222-2222-2222-2222-222222222222 \
  --key-id 33333333-3333-3333-3333-333333333333 \
  --lan-ca-id 44444444-4444-4444-4444-444444444444 > /tmp/lanca.log 2>&1; then
  echo 'secrets must refuse to write over a directory'; exit 1
fi
grep -Fq 'refusing to replace non-regular file /etc/ssl/lan/lan-ca.pem' /tmp/lanca.log
rmdir /etc/ssl/lan/lan-ca.pem
install -o root -g root -m 0644 /tmp/lan-ca.pem /etc/ssl/lan/lan-ca.pem
run verify > /dev/null
echo 'PASS: a bind-mount directory in place of lan-ca.pem is refused'

run secrets --vault-url https://vault.example --email a@b \
  --ca-id 11111111-1111-1111-1111-111111111111 \
  --crt-id 22222222-2222-2222-2222-222222222222 \
  --key-id 55555555-5555-5555-5555-555555555555 \
  --lan-ca-id 44444444-4444-4444-4444-444444444444 > /dev/null 2>/tmp/mismatch || true
grep -Fq 'the server key does not match the server certificate' /tmp/mismatch
if run enable >/dev/null 2>&1; then echo 'enable must refuse a mismatched key'; exit 1; fi

run secrets --vault-url https://vault.example --email a@b \
  --ca-id 11111111-1111-1111-1111-111111111111 \
  --crt-id 66666666-6666-6666-6666-666666666666 \
  --key-id 55555555-5555-5555-5555-555555555555 \
  --lan-ca-id 44444444-4444-4444-4444-444444444444 > /dev/null 2>/tmp/foreign || true
grep -Fq 'was not issued by ca.pem' /tmp/foreign
echo 'PASS: a key or issuer mismatch fails verify'

install -o root -g root -m 0644 /tmp/tls/server-cert.pem /etc/docker/tls/server-cert.pem
install -o root -g root -m 0600 /tmp/tls/server-key.pem /etc/docker/tls/server-key.pem
python3 - <<'PY'
import json
config = json.load(open("/etc/docker/daemon.json"))
config["hosts"] = ["fd://", "tcp://0.0.0.0:2375"]
json.dump(config, open("/etc/docker/daemon.json", "w"))
PY
if run verify > /tmp/badconfig.log 2>&1; then echo 'verify must reject a 2375 listener in daemon.json'; exit 1; fi
grep -Fq 'mentions the plaintext port 2375' /tmp/badconfig.log
echo 'PASS: a plaintext port in daemon.json fails verify'
INNER
)

docker run --rm \
  --volume "$repo_root:/src:ro" \
  "$fixture_image" bash -c "$script"
echo 'overlay tests passed'
