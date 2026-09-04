#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
overlay="$repo_root/worker/rootfs/usr/local/sbin/openhands-overlay"
fixture_image=auto-code-env-wsl-overlay-fixture:ubuntu-26.04

test -f "$overlay"
grep -Fq 'LoadCredential=rbw_master:' "$overlay"
grep -Fq 'rbw purge' "$overlay"
grep -Fq 'systemd-ask-password --echo=no' "$overlay"
if grep -Eq 'echo .*\$OVERLAY_|printf .*tls\.key' "$overlay"; then exit 1; fi

if ! docker image inspect "$fixture_image" >/dev/null 2>&1; then
  printf '%s\n' \
    'FROM ubuntu:26.04' \
    'RUN apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*' |
    docker build --quiet --tag "$fixture_image" -
fi

script=$(cat <<'INNER'
set -euo pipefail
umask 022
shim=/tmp/shim
mkdir -p "$shim" /tmp/log /usr/local/libexec /etc/nginx && chmod 1777 /tmp/log
install -m 0755 /src/worker/rootfs/usr/local/sbin/openhands-overlay /usr/local/sbin/openhands-overlay
userdel -r ubuntu 2>/dev/null || true; useradd -m -u 1000 -s /bin/bash agent
mkdir -p /etc/openhands && printf 'openhands-worker 9.9.9-test\n' > /etc/openhands/release
printf '#!/bin/sh\nexit 0\n' > /usr/local/libexec/openhands-rbw-pinentry
chmod 0755 /usr/local/libexec/openhands-rbw-pinentry

openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=towerr.example -days 1 \
  -keyout /tmp/fixture.key -out /tmp/fixture.crt >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=other.example -days 1 \
  -keyout /tmp/other.key -out /tmp/other.crt >/dev/null 2>&1
printf '%064d' 7 > /tmp/fixture.api
printf 'hunter2' > /tmp/fixture.master

cat > "$shim/rbw" <<'EOF'
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
      "get --field notes 11111111-1111-1111-1111-111111111111") cat /tmp/fixture.crt ;;
      "get --field notes 22222222-2222-2222-2222-222222222222") cat /tmp/fixture.key ;;
      "get --field notes 33333333-3333-3333-3333-333333333333") cat /tmp/other.key ;;
      "get 44444444-4444-4444-4444-444444444444") cat /tmp/fixture.api; echo ;;
      "get 55555555-5555-5555-5555-555555555555") printf 'ghp_FIXTURETOKEN0000000000000000000000\n' ;;
      *) echo "unknown item $*" >&2; exit 1 ;;
    esac ;;
  *) echo "unexpected rbw $*" >&2; exit 1 ;;
esac
EOF

cat > "$shim/systemd-run" <<'EOF'
#!/bin/sh
echo "systemd-run $*" >> /tmp/log/systemd-run
creds=$(mktemp -d)
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet|--pipe|--wait|--collect) shift ;;
    -E) export "$2"; shift 2 ;;
    -p)
      case "$2" in
        LoadCredential=*) spec=${2#LoadCredential=}; cp "${spec#*:}" "$creds/${spec%%:*}" ;;
        *) echo "unexpected property $2" >&2; exit 1 ;;
      esac
      shift 2 ;;
    *) break ;;
  esac
done
CREDENTIALS_DIRECTORY=$creds exec "$@"
EOF

cat > "$shim/systemd-ask-password" <<'EOF'
#!/bin/sh
cat /tmp/fixture.master
EOF

cat > "$shim/nginx" <<'EOF'
#!/bin/sh
test "$1" = -t || exit 1
test -r /etc/nginx/tls/tls.crt && test -r /etc/nginx/tls/tls.key
EOF

cat > "$shim/git" <<'EOF'
#!/bin/sh
echo "git $*" >> /tmp/log/git
EOF

cat > "$shim/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> /tmp/log/systemctl
case "$1" in
  enable|daemon-reload|try-restart) exit 0 ;;
  is-active) printf 'active\nactive\n' ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$shim"/*
export PATH="$shim:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"

run() { openhands-overlay "$@"; }

if run verify >/dev/null 2>&1; then echo 'verify must fail before secrets exist'; exit 1; fi
if run enable >/dev/null 2>&1; then echo 'enable must fail before secrets exist'; exit 1; fi
if run secrets --vault-url http://vault.example --email a@b --crt-id 11111111-1111-1111-1111-111111111111 --key-id 22222222-2222-2222-2222-222222222222 --api-id 44444444-4444-4444-4444-444444444444 >/dev/null 2>&1; then echo 'plain HTTP vault must be rejected'; exit 1; fi
if run secrets --vault-url https://vault.example --email a@b --crt-id nope --key-id 22222222-2222-2222-2222-222222222222 --api-id 44444444-4444-4444-4444-444444444444 >/dev/null 2>&1; then echo 'non-UUID item id must be rejected'; exit 1; fi
test ! -e /tmp/log/systemd-run

output=$(run secrets --vault-url https://vault.example --email a@b \
  --crt-id 11111111-1111-1111-1111-111111111111 \
  --key-id 22222222-2222-2222-2222-222222222222 \
  --api-id 44444444-4444-4444-4444-444444444444)
printf '%s\n' "$output" | grep -Fq 'overlay verified'
printf '%s\n' "$output" | grep -Fq 'CN = towerr.example' || printf '%s\n' "$output" | grep -Fq 'CN=towerr.example'
if printf '%s\n' "$output" | grep -Eq 'PRIVATE KEY|0000000'; then echo 'secret material leaked to stdout'; exit 1; fi

test "$(stat -c '%U:%G %a' /etc/nginx/tls/tls.crt)" = 'root:root 644'
test "$(stat -c '%U:%G %a' /etc/nginx/tls/tls.key)" = 'root:root 600'
test "$(stat -c '%U:%G %a' /etc/credstore/local_backend_api_key)" = 'root:root 600'
test "$(stat -c '%U:%G %a' /etc/credstore)" = 'root:root 700'
cmp -s /tmp/fixture.crt /etc/nginx/tls/tls.crt
cmp -s /tmp/fixture.key /etc/nginx/tls/tls.key
test "$(cat /etc/credstore/local_backend_api_key)" = "$(cat /tmp/fixture.api)"
test ! -e /run/openhands-rbw-master
grep -Fq 'LoadCredential=rbw_master:/run/openhands-rbw-master' /tmp/log/systemd-run
test "$(grep -c '^rbw login$' /tmp/log/rbw)" = 1
test "$(tail -n 1 /tmp/log/rbw)" = 'rbw purge'
grep -n '^rbw ' /tmp/log/rbw | grep -F 'rbw config set pinentry /usr/local/libexec/openhands-rbw-pinentry' >/dev/null
login_line=$(grep -n '^rbw login$' /tmp/log/rbw | cut -d: -f1)
first_get=$(grep -n '^rbw get ' /tmp/log/rbw | head -n 1 | cut -d: -f1)
test "$login_line" -lt "$first_get"

run enable | grep -Fq 'active'
grep -Fq 'systemctl enable --now nginx.service agent-canvas.service' /tmp/log/systemctl

if run origin http://orc.example >/dev/null 2>&1; then echo 'plain HTTP origin must be rejected'; exit 1; fi
if run origin 'https://orc.example/path' >/dev/null 2>&1; then echo 'origin with a path must be rejected'; exit 1; fi
test ! -e /etc/systemd/system/agent-canvas.service.d/10-overlay.conf
run origin https://orc.example | grep -Fq 'origin https://orc.example'
test "$(stat -c '%U:%G %a' /etc/systemd/system/agent-canvas.service.d/10-overlay.conf)" = 'root:root 644'
grep -Fxq 'Environment=OH_ALLOW_CORS_ORIGINS_0=https://orc.example' /etc/systemd/system/agent-canvas.service.d/10-overlay.conf
grep -Fq 'systemctl daemon-reload' /tmp/log/systemctl
grep -Fq 'systemctl try-restart agent-canvas.service' /tmp/log/systemctl
run origin https://orc.example https://second.example >/dev/null
grep -Fxq 'Environment=OH_ALLOW_CORS_ORIGINS_1=https://second.example' /etc/systemd/system/agent-canvas.service.d/10-overlay.conf
test "$(grep -c '^Environment=OH_ALLOW_CORS_ORIGINS_' /etc/systemd/system/agent-canvas.service.d/10-overlay.conf)" = 2

if run github >/dev/null 2>&1; then echo 'github requires --pat-id'; exit 1; fi
if run github --pat-id nope >/dev/null 2>&1; then echo 'github must reject a non-UUID id'; exit 1; fi
gh_out=$(run github --pat-id 55555555-5555-5555-5555-555555555555)
printf '%s\n' "$gh_out" | grep -Fq 'github credential installed for agent'
if printf '%s\n' "$gh_out" | grep -Fq 'ghp_'; then echo 'token leaked to stdout'; exit 1; fi
test "$(stat -c '%U:%G %a' /home/agent/.git-credentials)" = 'agent:agent 600'
grep -Fxq 'https://x-access-token:ghp_FIXTURETOKEN0000000000000000000000@github.com' /home/agent/.git-credentials
grep -Fq 'git config --global credential.helper store' /tmp/log/git
test "$(grep -c '^rbw login$' /tmp/log/rbw)" = 2
test "$(tail -n 1 /tmp/log/rbw)" = 'rbw purge'
run status | grep -Fq 'release openhands-worker 9.9.9-test'

run secrets --vault-url https://vault.example --email a@b \
  --crt-id 11111111-1111-1111-1111-111111111111 \
  --key-id 33333333-3333-3333-3333-333333333333 \
  --api-id 44444444-4444-4444-4444-444444444444 >/dev/null 2>/tmp/mismatch || true
grep -Fq 'private key does not match certificate' /tmp/mismatch
if run enable >/dev/null 2>&1; then echo 'enable must refuse a mismatched key'; exit 1; fi
echo 'overlay tests passed'
INNER
)

docker run --rm \
  --volume "$repo_root:/src:ro" \
  "$fixture_image" bash -c "$script"
