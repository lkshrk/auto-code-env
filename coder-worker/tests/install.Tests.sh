#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
overlay="$repo_root/coder-worker/wsl/coder-worker-overlay"
fixture_image=auto-code-env-coder-worker-fixture:ubuntu-26.04

test -f "$overlay"
test ! -e "$repo_root/coder-worker/wsl/setup.sh"
grep -Fq 'set -euo pipefail' "$overlay"
grep -Eq '^readonly DOCKER_GPG_SHA256=[0-9a-f]{64}$' "$overlay"
grep -Eq "^readonly DOCKER_CE_VERSION='5:[0-9.]+-[0-9]+~ubuntu\.[0-9.]+~[a-z]+'$" "$overlay"
grep -Eq "^readonly CONTAINERD_VERSION='[0-9.]+-[0-9]+~ubuntu\.[0-9.]+~[a-z]+'$" "$overlay"
grep -Eq '^readonly RBW_PACKAGE_VERSION=[0-9.]+-[0-9]+$' "$overlay"
if grep -Eq ':latest|=latest| latest$' "$overlay"; then echo 'the overlay must not use a latest tag'; exit 1; fi
if grep -n 2375 "$overlay" | grep -qvE '^[0-9]+:readonly PLAINTEXT_PORT=2375$'; then
  echo 'the overlay may mention 2375 only as the plaintext port constant it refuses'; exit 1
fi
grep -Fq '%U:%G %04a' "$overlay"

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
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

mkdir -p /root/coder-worker
install -m 0644 /src/coder-worker/wsl/coder-worker-overlay /root/coder-worker/coder-worker-overlay
install -m 0644 /src/coder-worker/hosts/towerr.profile /root/coder-worker/profile
run_install() { bash /root/coder-worker/coder-worker-overlay install --profile /root/coder-worker/profile; }

run_install > /tmp/setup1.log
grep -Fq 'docker is not running yet' /tmp/setup1.log
grep -Fq 'systemd is not running yet' /tmp/setup1.log

test "$(stat -c '%U:%G %a' /etc/wsl.conf)" = 'root:root 644'
grep -Fxq 'systemd=true' /etc/wsl.conf
grep -Fxq 'default=root' /etc/wsl.conf
grep -A1 -Fx '[interop]' /etc/wsl.conf | grep -Fxq 'enabled=false'
grep -A1 -Fx '[automount]' /etc/wsl.conf | grep -Fxq 'enabled=false'

test "$(stat -c '%U:%G %a' /etc/docker)" = 'root:root 755'
test "$(stat -c '%U:%G %a' /etc/docker/tls)" = 'root:root 700'
test "$(stat -c '%U:%G %a' /etc/ssl/lan)" = 'root:root 755'
test "$(stat -c '%U:%G %a' /etc/docker/daemon.json)" = 'root:root 644'
python3 -c 'import json; json.load(open("/etc/docker/daemon.json"))'
python3 - <<'PY'
import json
config = json.load(open("/etc/docker/daemon.json"))
assert config["hosts"] == ["fd://", "tcp://0.0.0.0:2376"], config["hosts"]
assert config["tls"] is True and config["tlsverify"] is True
assert config["tlscacert"] == "/etc/docker/tls/ca.pem"
assert config["tlscert"] == "/etc/docker/tls/server-cert.pem"
assert config["tlskey"] == "/etc/docker/tls/server-key.pem"
assert config["log-driver"] == "local"
assert "2375" not in open("/etc/docker/daemon.json").read()
PY

grep -Fxq 'ExecStart=' /etc/systemd/system/docker.service.d/10-listeners.conf
grep -Fxq 'ExecStart=/usr/bin/dockerd' /etc/systemd/system/docker.service.d/10-listeners.conf
if grep -Fq -- '-H fd://' /etc/systemd/system/docker.service.d/10-listeners.conf; then
  echo 'the listener drop-in must not restore -H fd://'; exit 1
fi
for material in ca.pem server-cert.pem server-key.pem; do
  grep -Fxq "ConditionPathExists=/etc/docker/tls/$material" /etc/systemd/system/docker.service.d/20-require-tls.conf
done

test "$(stat -c '%U:%G %a' /etc/apt/keyrings/docker.asc)" = 'root:root 644'
cmp -s /opt/fixture/docker.asc /etc/apt/keyrings/docker.asc
grep -Fxq 'Signed-By: /etc/apt/keyrings/docker.asc' /etc/apt/sources.list.d/docker.sources
grep -Fxq 'Suites: resolute' /etc/apt/sources.list.d/docker.sources
test "$(stat -c '%U:%G %a' /usr/local/libexec/coder-worker-rbw-pinentry)" = 'root:root 755'
test "$(stat -c '%U:%G %a' /usr/local/sbin/coder-worker-overlay)" = 'root:root 755'
cmp -s /src/coder-worker/wsl/coder-worker-overlay /usr/local/sbin/coder-worker-overlay
test "$(stat -c '%U:%G %a' /etc/coder-worker/profile)" = 'root:root 644'
cmp -s /src/coder-worker/hosts/towerr.profile /etc/coder-worker/profile
grep -Fxq 'codercom/enterprise-base:ubuntu' /etc/coder-worker/images
grep -Fxq 'docker:27-dind' /etc/coder-worker/images
grep -Fq 'coder-worker ' /etc/coder-worker/release
echo 'PASS: one Linux file installs the distribution and its own copy'

grep -Fq 'docker-ce=5:' /tmp/log/apt-get
grep -Fq 'containerd.io=' /tmp/log/apt-get
grep -Fq 'rbw=' /tmp/log/apt-get
grep -Fq 'apt-mark hold docker-ce docker-ce-cli containerd.io' /tmp/log/apt-mark
test "$(cat /tmp/pkgstate/docker-ce)" = "$(sed -n "s/^readonly DOCKER_CE_VERSION='\\(.*\\)'$/\\1/p" /src/coder-worker/wsl/coder-worker-overlay)"

fixture_snapshot > /tmp/snapshot1
: > /tmp/log/apt-get
run_install > /tmp/setup2.log
fixture_snapshot > /tmp/snapshot2
diff -u /tmp/snapshot1 /tmp/snapshot2
test ! -s /tmp/log/apt-get
test ! -e /tmp/log/curl.second
echo 'PASS: the second run is a no-op'

mkdir -p /run/systemd/system
: > /tmp/log/systemctl
run_install > /tmp/setup3.log
grep -Fq 'systemctl enable docker.socket docker.service' /tmp/log/systemctl
if grep -Fq 'daemon-reload' /tmp/log/systemctl; then
  echo 'an unchanged run must not reload systemd'; exit 1
fi
echo 'PASS: docker is enabled once systemd is up'

: > /tmp/docker-up
run_install > /tmp/setup4.log
grep -Fq 'docker image pull -- codercom/enterprise-base:ubuntu' /tmp/log/docker
grep -Fq 'docker image pull -- docker:27-dind' /tmp/log/docker
echo 'PASS: workspace images are pre-pulled once docker answers'

printf 'not the docker signing key\n' > /opt/fixture/docker.asc
rm -f /etc/apt/keyrings/docker.asc
if run_install > /tmp/setup5.log 2>&1; then
  echo 'install must refuse a signing key that fails its pinned checksum'; exit 1
fi
grep -Fq 'does not match its pinned SHA-256' /tmp/setup5.log
test ! -e /etc/apt/keyrings/docker.asc
echo 'PASS: the pinned signing key checksum is enforced'
INNER
)

docker run --rm \
  --volume "$repo_root:/src:ro" \
  "$fixture_image" bash -c "$script"
echo 'install tests passed'
