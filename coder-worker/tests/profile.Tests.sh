#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
hosts="$repo_root/coder-worker/hosts"
fixture_image=auto-code-env-coder-worker-fixture:ubuntu-26.04

test -d "$hosts"
shopt -s nullglob
profiles=("$hosts"/*.profile)
shopt -u nullglob
test "${#profiles[@]}" -gt 0

for committed in "${profiles[@]}"; do
  if grep -Eqi '^[A-Za-z0-9_]*(PASSWORD|PASSWD|SECRET|TOKEN|CREDENTIAL|PRIVATE|PASSPHRASE|APIKEY)[A-Za-z0-9_]*=' "$committed"; then
    echo "$committed names a secret"; exit 1
  fi
  if grep -Eq '^[A-Za-z0-9_]*(^|_)KEY(_|=)' "$committed" && ! grep -Eq '^VAULT_ITEM_' "$committed"; then
    echo "$committed names a key"; exit 1
  fi
  if grep -Eq -- '-----BEGIN|ghp_|github_pat_|[A-Za-z0-9+/=_-]{40,}' "$committed"; then
    echo "$committed contains something shaped like a credential"; exit 1
  fi
done
echo 'PASS: no committed host profile carries a secret'

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
overlay=/src/coder-worker/wsl/coder-worker-overlay
good=/src/coder-worker/hosts/towerr.profile

refuse() {
  message=$1
  shift
  if bash "$overlay" install --profile /tmp/bad.env > /tmp/bad.log 2>&1; then
    echo "the profile parser accepted: $message"; exit 1
  fi
  grep -Fq "$*" /tmp/bad.log || { echo "wrong error for $message:"; cat /tmp/bad.log; exit 1; }
  test ! -e /etc/wsl.conf
  test ! -e /etc/coder-worker/profile
}

cp "$good" /tmp/bad.env
printf 'VAULT_PASSWORD=hunter2\n' >> /tmp/bad.env
refuse 'a password key' 'names a secret'

cp "$good" /tmp/bad.env
printf 'GITHUB_TOKEN=x\n' >> /tmp/bad.env
refuse 'a token key' 'names a secret'

cp "$good" /tmp/bad.env
printf 'SIGNING_KEY=x\n' >> /tmp/bad.env
refuse 'a key key' 'names a secret'

cp "$good" /tmp/bad.env
printf 'DOCKER_HOSTNAME=towerr\n' >> /tmp/bad.env
refuse 'an unknown key' 'unknown key DOCKER_HOSTNAME'

cp "$good" /tmp/bad.env
printf 'DISTRO_NAME=other\n' >> /tmp/bad.env
refuse 'a repeated key' 'repeats DISTRO_NAME'

sed 's|^VAULT_URL=.*|VAULT_URL=-----BEGIN CERTIFICATE-----|' "$good" > /tmp/bad.env
refuse 'PEM material in a value' 'looks like a credential'

sed 's|^VAULT_FOLDER=.*|VAULT_FOLDER=ghp_0123456789012345678901234567890123456789|' "$good" > /tmp/bad.env
refuse 'a token in a value' 'looks like a credential'

sed 's|^VAULT_URL=.*|VAULT_URL=http://vlt.h-cloud.io|' "$good" > /tmp/bad.env
refuse 'a plain HTTP vault URL' 'invalid value for VAULT_URL'

sed 's|^DOCKER_PORT=.*|DOCKER_PORT=2375|' "$good" > /tmp/bad.env
refuse 'the plaintext docker port' 'invalid value for DOCKER_PORT'

sed 's|^FIREWALL_REMOTE_ADDRESSES=.*|FIREWALL_REMOTE_ADDRESSES=Any|' "$good" > /tmp/bad.env
refuse 'an Any firewall source' 'invalid value for FIREWALL_REMOTE_ADDRESSES'

sed 's|^DISTRO_NAME=.*|DISTRO NAME=coder-worker|' "$good" > /tmp/bad.env
refuse 'a line that is not NAME=value' 'is not NAME=value'

for required in DISTRO_NAME UBUNTU_DISTRIBUTION VAULT_URL VAULT_EMAIL VAULT_ITEM_CA \
  VAULT_ITEM_SERVER_CERT VAULT_ITEM_SERVER_KEY DOCKER_PORT FIREWALL_REMOTE_ADDRESSES; do
  grep -v "^$required=" "$good" > /tmp/bad.env
  refuse "a profile without $required" "is missing $required"
done

for bad in 999.999.999.999 10.254.0.256 10.254.0 10.254.0.10/33 10.254.0.10,300.1.1.1; do
  sed "s|^FIREWALL_REMOTE_ADDRESSES=.*|FIREWALL_REMOTE_ADDRESSES=$bad|" "$good" > /tmp/bad.env
  refuse "the firewall source $bad" 'invalid value for FIREWALL_REMOTE_ADDRESSES'
done

ln -sf "$good" /tmp/link.env
if bash "$overlay" install --profile /tmp/link.env > /tmp/link.log 2>&1; then
  echo 'the profile parser followed a symbolic link'; exit 1
fi
grep -Fq 'is a symbolic link' /tmp/link.log
echo 'PASS: the profile parser refuses secrets, unknown keys and unsafe values'

for committed in /src/coder-worker/hosts/*.profile; do
  if bash "$overlay" secrets --profile "$committed" > /tmp/committed.log 2>&1; then
    echo "$committed reached the vault without a pinentry helper"; exit 1
  fi
  grep -Fq 'pinentry helper missing' /tmp/committed.log ||
    { echo "$committed did not parse:"; cat /tmp/committed.log; exit 1; }
done
echo 'PASS: every committed host profile parses and drives secrets'
INNER
)

docker run --rm \
  --volume "$repo_root:/src:ro" \
  "$fixture_image" bash -c "$script"
echo 'profile tests passed'
