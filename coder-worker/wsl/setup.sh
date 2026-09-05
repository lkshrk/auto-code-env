#!/bin/bash
# shellcheck disable=SC2016
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
umask 022

readonly SETUP_VERSION=1.0.0
readonly UBUNTU_CODENAME=resolute
readonly UBUNTU_VERSION_ID=26.04
readonly DOCKER_GPG_URL=https://download.docker.com/linux/ubuntu/gpg
readonly DOCKER_GPG_SHA256=1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570
readonly DOCKER_REPOSITORY_URL=https://download.docker.com/linux/ubuntu
readonly DOCKER_KEYRING=/etc/apt/keyrings/docker.asc
readonly DOCKER_SOURCES=/etc/apt/sources.list.d/docker.sources
readonly DOCKER_CE_VERSION='5:29.8.0-1~ubuntu.26.04~resolute'
readonly DOCKER_CLI_VERSION='5:29.8.0-1~ubuntu.26.04~resolute'
readonly CONTAINERD_VERSION='2.3.4-2~ubuntu.26.04~resolute'
readonly RBW_PACKAGE_VERSION=1.13.2-7
readonly DOCKER_TLS_DIRECTORY=/etc/docker/tls
readonly LAN_CA_DIRECTORY=/etc/ssl/lan
readonly CONFIG_DIRECTORY=/etc/coder-worker
readonly IMAGE_LIST="${CONFIG_DIRECTORY}/images"
readonly RELEASE_MARKER="${CONFIG_DIRECTORY}/release"
readonly OVERLAY=/usr/local/sbin/coder-worker-overlay
readonly PINENTRY_DIRECTORY=/usr/local/libexec
readonly PINENTRY="${PINENTRY_DIRECTORY}/coder-worker-rbw-pinentry"
readonly DROPIN_DIRECTORY=/etc/systemd/system/docker.service.d
readonly -a WORKSPACE_IMAGES=(
    'codercom/enterprise-base:ubuntu'
    'docker:27-dind'
)
readonly -a BASE_PACKAGES=(ca-certificates curl openssl python3 iproute2)

script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly script_directory
needs_daemon_reload=0

fail() {
    printf 'coder-worker-setup: %s\n' "$1" >&2
    exit 1
}

run_clean() {
    /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

run_apt() {
    /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive "$@"
}

ensure_directory() {
    local mode=$1 path=$2

    if [ -L "$path" ]; then
        fail "$path is a symbolic link"
    fi
    if [ -d "$path" ]; then
        chown root:root -- "$path"
        chmod "$mode" -- "$path"
        return
    fi
    if [ -e "$path" ]; then
        fail "$path exists and is not a directory"
    fi
    install -d -o root -g root -m "$mode" -- "$path"
}

write_root_file() {
    local mode=$1 path=$2 temp

    if [ -L "$path" ]; then
        fail "$path is a symbolic link"
    fi
    temp=$(mktemp -- "${path}.XXXXXX") || fail "unable to stage $path"
    cat > "$temp"
    chown root:root -- "$temp"
    chmod "$mode" -- "$temp"
    if [ -f "$path" ] && cmp -s -- "$temp" "$path" &&
        [ "$(stat -c '%U:%G %04a' "$path")" = "root:root $mode" ]; then
        rm -f -- "$temp"
        return 1
    fi
    mv -f -- "$temp" "$path"
    return 0
}

os_release_value() {
    /usr/bin/sed -n "s/^$1=//p" /etc/os-release | /usr/bin/tr -d '"' | /usr/bin/head -n 1
}

assert_ubuntu() {
    local id version

    [ -r /etc/os-release ] || fail 'missing /etc/os-release'
    id=$(os_release_value ID)
    version=$(os_release_value VERSION_ID)
    [ "$id" = ubuntu ] || fail 'this distribution is not Ubuntu'
    [ "$version" = "$UBUNTU_VERSION_ID" ] ||
        fail "this distribution is Ubuntu $version, but the pinned package set targets $UBUNTU_VERSION_ID"
}

install_wsl_config() {
    write_root_file 0644 /etc/wsl.conf <<'CONF' || return 0
[boot]
systemd=true

[automount]
enabled=false

[interop]
enabled=false
appendWindowsPath=false

[user]
default=root
CONF
    printf 'wsl.conf updated; the distribution must be terminated for it to apply\n'
}

install_base_packages() {
    local missing=0 package

    for package in "${BASE_PACKAGES[@]}"; do
        run_clean /usr/bin/dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null |
            grep -Fqx 'ii ' || missing=1
    done
    [ "$missing" = 1 ] || return 0
    run_apt /usr/bin/apt-get update
    run_apt /usr/bin/apt-get install -y --no-install-recommends "${BASE_PACKAGES[@]}"
}

package_version_matches() {
    local package=$1 version=$2 status

    status=$(run_clean /usr/bin/dpkg-query -W -f='${db:Status-Abbrev} ${Version}' "$package" 2>/dev/null) || return 1
    [ "$status" = "ii  $version" ]
}

install_docker_repository() {
    local temp digest

    ensure_directory 0755 /etc/apt/keyrings
    if [ -f "$DOCKER_KEYRING" ]; then
        digest=$(run_clean /usr/bin/sha256sum < "$DOCKER_KEYRING" | cut -d' ' -f1)
        if [ "$digest" = "$DOCKER_GPG_SHA256" ]; then
            chown root:root -- "$DOCKER_KEYRING"
            chmod 0644 -- "$DOCKER_KEYRING"
            install_docker_sources
            return
        fi
    fi

    temp=$(mktemp -- "${DOCKER_KEYRING}.XXXXXX") || fail 'unable to stage the Docker signing key'
    if ! run_clean /usr/bin/curl --disable --fail --location --proto '=https' --proto-redir '=https' \
        --tlsv1.2 --tls-max 1.3 --cacert /etc/ssl/certs/ca-certificates.crt --retry 3 \
        --output "$temp" "$DOCKER_GPG_URL"; then
        rm -f -- "$temp"
        fail 'unable to download the Docker signing key'
    fi
    digest=$(run_clean /usr/bin/sha256sum < "$temp" | cut -d' ' -f1)
    if [ "$digest" != "$DOCKER_GPG_SHA256" ]; then
        rm -f -- "$temp"
        fail 'the Docker signing key does not match its pinned SHA-256'
    fi
    chown root:root -- "$temp"
    chmod 0644 -- "$temp"
    mv -f -- "$temp" "$DOCKER_KEYRING"
    install_docker_sources
}

install_docker_sources() {
    local architecture

    architecture=$(run_clean /usr/bin/dpkg --print-architecture) || fail 'unable to read the dpkg architecture'
    write_root_file 0644 "$DOCKER_SOURCES" <<CONF || true
Types: deb
URIs: ${DOCKER_REPOSITORY_URL}
Suites: ${UBUNTU_CODENAME}
Components: stable
Architectures: ${architecture}
Signed-By: ${DOCKER_KEYRING}
CONF
}

install_docker_packages() {
    if package_version_matches docker-ce "$DOCKER_CE_VERSION" &&
        package_version_matches docker-ce-cli "$DOCKER_CLI_VERSION" &&
        package_version_matches containerd.io "$CONTAINERD_VERSION"; then
        run_clean /usr/bin/apt-mark hold docker-ce docker-ce-cli containerd.io > /dev/null
        return
    fi
    run_apt /usr/bin/apt-get update
    run_clean /usr/bin/apt-mark unhold docker-ce docker-ce-cli containerd.io > /dev/null 2>&1 || true
    run_apt /usr/bin/apt-get install -y --no-install-recommends \
        "docker-ce=${DOCKER_CE_VERSION}" \
        "docker-ce-cli=${DOCKER_CLI_VERSION}" \
        "containerd.io=${CONTAINERD_VERSION}"
    package_version_matches docker-ce "$DOCKER_CE_VERSION" || fail 'docker-ce is not at its pinned version'
    package_version_matches docker-ce-cli "$DOCKER_CLI_VERSION" || fail 'docker-ce-cli is not at its pinned version'
    package_version_matches containerd.io "$CONTAINERD_VERSION" || fail 'containerd.io is not at its pinned version'
    run_clean /usr/bin/apt-mark hold docker-ce docker-ce-cli containerd.io > /dev/null
}

install_rbw() {
    if package_version_matches rbw "$RBW_PACKAGE_VERSION"; then
        run_clean /usr/bin/apt-mark hold rbw > /dev/null
        return
    fi
    run_apt /usr/bin/apt-get update
    run_clean /usr/bin/apt-mark unhold rbw > /dev/null 2>&1 || true
    run_apt /usr/bin/apt-get install -y --no-install-recommends "rbw=${RBW_PACKAGE_VERSION}"
    package_version_matches rbw "$RBW_PACKAGE_VERSION" || fail 'rbw is not at its pinned version'
    run_clean /usr/bin/apt-mark hold rbw > /dev/null
}

install_pinentry() {
    ensure_directory 0755 "$PINENTRY_DIRECTORY"
    write_root_file 0755 "$PINENTRY" <<'PYTHON' || true
#!/usr/bin/python3
import os
import sys
from pathlib import Path

out = sys.stdout.buffer
prompt = b""


def write(data: bytes) -> None:
    out.write(data)
    out.flush()


write(b"OK rbw credential pinentry ready\n")
for raw in sys.stdin.buffer:
    command, _, argument = raw.rstrip(b"\r\n").partition(b" ")
    if command == b"SETPROMPT":
        prompt = argument
        write(b"OK\n")
    elif command in {b"SETTITLE", b"SETDESC", b"SETERROR"}:
        write(b"OK\n")
    elif command == b"GETPIN":
        if prompt != b"Master Password":
            write(b"ERR 83886179 unexpected pinentry prompt\n")
            break
        try:
            secret = Path(os.environ["CREDENTIALS_DIRECTORY"], "rbw_master").read_bytes()
        except (KeyError, OSError):
            write(b"ERR 83886179 credential unavailable\n")
            break
        if not secret:
            write(b"ERR 83886179 empty credential\n")
            break
        write(b"D " + b"".join(f"%{byte:02X}".encode() for byte in secret) + b"\nOK\n")
        break
    elif command == b"BYE":
        write(b"OK\n")
        break
    else:
        write(b"ERR 83886179 unsupported pinentry command\n")
        break
PYTHON
}

install_overlay() {
    local source="${script_directory}/coder-worker-overlay"

    [ -f "$source" ] || fail "missing $source; copy the whole coder-worker/wsl directory into the distribution"
    write_root_file 0755 "$OVERLAY" < "$source" || true
}

install_docker_configuration() {
    ensure_directory 0755 /etc/docker
    ensure_directory 0700 "$DOCKER_TLS_DIRECTORY"
    ensure_directory 0755 "$LAN_CA_DIRECTORY"
    write_root_file 0644 /etc/docker/daemon.json <<CONF || true
{
  "hosts": ["fd://", "tcp://0.0.0.0:2376"],
  "tls": true,
  "tlsverify": true,
  "tlscacert": "${DOCKER_TLS_DIRECTORY}/ca.pem",
  "tlscert": "${DOCKER_TLS_DIRECTORY}/server-cert.pem",
  "tlskey": "${DOCKER_TLS_DIRECTORY}/server-key.pem",
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "default-address-pools": [
    {
      "base": "172.28.0.0/14",
      "size": 24
    }
  ]
}
CONF
}

install_service_dropins() {
    ensure_directory 0755 "$DROPIN_DIRECTORY"
    if write_root_file 0644 "${DROPIN_DIRECTORY}/10-listeners.conf" <<'CONF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd
CONF
    then
        needs_daemon_reload=1
    fi
    if write_root_file 0644 "${DROPIN_DIRECTORY}/20-require-tls.conf" <<CONF
[Unit]
ConditionPathExists=${DOCKER_TLS_DIRECTORY}/ca.pem
ConditionPathExists=${DOCKER_TLS_DIRECTORY}/server-cert.pem
ConditionPathExists=${DOCKER_TLS_DIRECTORY}/server-key.pem
CONF
    then
        needs_daemon_reload=1
    fi
}

install_configuration_directory() {
    local image

    ensure_directory 0755 "$CONFIG_DIRECTORY"
    {
        for image in "${WORKSPACE_IMAGES[@]}"; do
            printf '%s\n' "$image"
        done
    } | write_root_file 0644 "$IMAGE_LIST" || true
    printf 'coder-worker %s\n' "$SETUP_VERSION" | write_root_file 0644 "$RELEASE_MARKER" || true
}

systemd_running() {
    [ -d /run/systemd/system ]
}

enable_docker() {
    if ! systemd_running; then
        printf 'systemd is not running yet; terminate the distribution and run this script again\n'
        return
    fi
    if [ "$needs_daemon_reload" = 1 ]; then
        systemctl daemon-reload
    fi
    systemctl enable docker.socket docker.service > /dev/null
}

prepull_images() {
    local image

    if ! docker info > /dev/null 2>&1; then
        printf 'docker is not running yet; run "coder-worker-overlay secrets" and "enable" to pull workspace images\n'
        return
    fi
    while IFS= read -r image; do
        [ -n "$image" ] || continue
        docker image pull -- "$image"
    done < "$IMAGE_LIST"
}

[ "$(id -u)" = 0 ] || fail 'must run as root'
assert_ubuntu
install_wsl_config
install_base_packages
install_docker_repository
install_docker_packages
install_rbw
install_pinentry
install_overlay
install_docker_configuration
install_service_dropins
install_configuration_directory
enable_docker
prepull_images

printf 'coder-worker %s configured; docker stays down until %s holds ca.pem, server-cert.pem and server-key.pem\n' \
    "$SETUP_VERSION" "$DOCKER_TLS_DIRECTORY"
