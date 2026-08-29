#!/usr/bin/env bash
set -euo pipefail

readonly NODE_VERSION=22.23.2
readonly NODE_ARCHIVE="node-v${NODE_VERSION}-linux-x64.tar.xz"
readonly NODE_DIRECTORY="node-v${NODE_VERSION}-linux-x64"
readonly NODE_HOME="/opt/openhands/${NODE_DIRECTORY}"
readonly UV_VERSION=0.12.7
readonly UV_ARCHIVE='uv-x86_64-unknown-linux-gnu.tar.gz'
readonly UV_DIRECTORY='uv-x86_64-unknown-linux-gnu'

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

assert_agent_directory() {
    local path=$1

    if [ -L "$path" ] || [ ! -d "$path" ] || [ "$(stat -c '%U:%G %a' "$path")" != 'agent:agent 700' ]; then
        fail "invalid agent directory: $path"
    fi
}

assert_agent() {
    local entry name password uid gid gecos home shell

    entry=$(getent passwd agent) || fail 'agent account is missing'
    IFS=: read -r name password uid gid gecos home shell <<< "$entry"
    case $uid in
        ''|*[!0-9]*) fail 'agent UID is invalid' ;;
    esac
    if [ "$name" != 'agent' ] || [ "$home" != '/home/agent' ] || [ "$shell" != '/bin/bash' ] || [ "$uid" -eq 0 ] ||
        [ "$(id -gn agent)" != 'agent' ] || [ "$(id -nG agent)" != 'agent' ]; then
        fail 'agent account does not match the runtime contract'
    fi
}

resolve_assets() {
    local payload_path

    if ! script_path=$(readlink -f -- "${BASH_SOURCE[0]}"); then
        fail 'unable to resolve provisioning script'
    fi
    if [ -z "$script_path" ] || [ ! -f "$script_path" ]; then
        fail 'provisioning script must be a regular file'
    fi
    asset_dir=$(dirname "$script_path")
    payload_path="$asset_dir/wsl.conf"
    if [ -L "$payload_path" ] || [ ! -f "$payload_path" ]; then
        fail 'wsl.conf must be a regular sibling file'
    fi
    if ! config_path=$(readlink -f -- "$payload_path"); then
        fail 'unable to resolve wsl.conf'
    fi
    if [ -z "$config_path" ] || [ ! -f "$config_path" ] || [ "$(dirname "$config_path")" != "$asset_dir" ]; then
        fail 'wsl.conf must resolve to the provisioning script directory'
    fi
}

ensure_private_directory() {
    local path=$1

    if [ -e "$path" ] || [ -L "$path" ]; then
        assert_agent_directory "$path"
        return
    fi
    runuser -u agent -- mkdir -m 0700 -- "$path"
    assert_agent_directory "$path"
}

assert_root_directory() {
    local path=$1

    if [ -L "$path" ] || [ ! -d "$path" ] || [ "$(stat -c '%U:%G %a' "$path")" != 'root:root 755' ]; then
        fail "invalid root directory: $path"
    fi
}

assert_root_file() {
    local path=$1

    if [ -L "$path" ] || [ ! -f "$path" ] || [ "$(stat -c '%U:%G %a' "$path")" != 'root:root 755' ]; then
        fail "invalid root file: $path"
    fi
}

assert_absent() {
    local path=$1

    if [ -e "$path" ] || [ -L "$path" ]; then
        fail "unsafe existing path: $path"
    fi
}

download() {
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$2" "$1"
}

assert_node_entrypoints() {
    assert_root_file /usr/local/bin/node
    cmp -s "$NODE_HOME/bin/node" /usr/local/bin/node || fail 'invalid node entry point'
    for tool in npm npx; do
        assert_root_file "/usr/local/bin/$tool"
        cmp -s "/usr/local/bin/$tool" <(printf '#!/bin/sh\nexec %s/bin/%s "$@"\n' "$NODE_HOME" "$tool") || fail "invalid $tool entry point"
    done
}

assert_node_installation() {
    assert_root_directory /opt/openhands
    assert_root_directory "$NODE_HOME"
    assert_root_file "$NODE_HOME/bin/node"
    [ "$("$NODE_HOME/bin/node" --version)" = "v$NODE_VERSION" ] || fail 'invalid Node.js installation'
    assert_node_entrypoints
    [ "$(npm --version)" = '10.9.8' ] || fail 'invalid npm installation'
    [ "$(npx --version)" = '10.9.8' ] || fail 'invalid npx installation'
}

install_node() {
    local tmp_dir node_checksum

    if [ -e "$NODE_HOME" ] || [ -L "$NODE_HOME" ]; then
        assert_node_installation
        return
    fi
    for path in /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx; do
        assert_absent "$path"
    done

    if [ ! -e /opt/openhands ] && [ ! -L /opt/openhands ]; then
        install -d -o root -g root -m 0755 /opt/openhands
    fi
    assert_root_directory /opt/openhands
    tmp_dir=$(mktemp -d /opt/openhands/.node.XXXXXX)
    (
        trap 'rm -rf -- "$tmp_dir"' EXIT
        download "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" "$tmp_dir/SHASUMS256.txt"
        download "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_ARCHIVE}" "$tmp_dir/$NODE_ARCHIVE"
        node_checksum=$(awk -v archive="$NODE_ARCHIVE" '$2 == archive { print; count++ } END { if (count != 1) exit 1 }' "$tmp_dir/SHASUMS256.txt") || fail 'Node.js checksum is missing or ambiguous'
        printf '%s\n' "$node_checksum" | (cd "$tmp_dir" && sha256sum -c -) || fail 'Node.js checksum verification failed'
        tar -xJf "$tmp_dir/$NODE_ARCHIVE" --no-same-owner --no-same-permissions --touch -C "$tmp_dir" \
            "$NODE_DIRECTORY/bin/node" \
            "$NODE_DIRECTORY/bin/npm" \
            "$NODE_DIRECTORY/bin/npx" \
            "$NODE_DIRECTORY/lib/node_modules/npm"
        assert_root_directory "$tmp_dir/$NODE_DIRECTORY"
        assert_root_file "$tmp_dir/$NODE_DIRECTORY/bin/node"
        [ "$("$tmp_dir/$NODE_DIRECTORY/bin/node" --version)" = "v$NODE_VERSION" ] || fail 'invalid Node.js archive'

        mv "$tmp_dir/$NODE_DIRECTORY" "$NODE_HOME"
        install -T -o root -g root -m 0755 "$NODE_HOME/bin/node" /usr/local/bin/node
        for tool in npm npx; do
            printf '#!/bin/sh\nexec %s/bin/%s "$@"\n' "$NODE_HOME" "$tool" | install -T -o root -g root -m 0755 /dev/stdin "/usr/local/bin/$tool"
        done
        assert_node_installation
    )
}

assert_uv_installation() {
    assert_root_file /usr/local/bin/uv
    assert_root_file /usr/local/bin/uvx
    [ "$(uv --version)" = "uv $UV_VERSION" ] || fail 'invalid uv installation'
    [ "$(uvx --version)" = "uvx $UV_VERSION" ] || fail 'invalid uvx installation'
}

install_uv() {
    local tmp_dir checksum uv_checksum

    if [ -e /usr/local/bin/uv ] || [ -L /usr/local/bin/uv ] || [ -e /usr/local/bin/uvx ] || [ -L /usr/local/bin/uvx ]; then
        assert_uv_installation
        return
    fi

    tmp_dir=$(mktemp -d)
    (
        trap 'rm -rf -- "$tmp_dir"' EXIT
        download "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${UV_ARCHIVE}.sha256" "$tmp_dir/${UV_ARCHIVE}.sha256"
        download "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${UV_ARCHIVE}" "$tmp_dir/$UV_ARCHIVE"
        checksum=$(awk 'NF { print $1; count++ } END { if (count != 1) exit 1 }' "$tmp_dir/${UV_ARCHIVE}.sha256") || fail 'uv checksum is missing or ambiguous'
        if [[ ! $checksum =~ ^[0-9a-f]{64}$ ]]; then
            fail 'uv checksum is invalid'
        fi
        uv_checksum=$(printf '%s  %s\n' "$checksum" "$UV_ARCHIVE")
        printf '%s\n' "$uv_checksum" | (cd "$tmp_dir" && sha256sum -c -) || fail 'uv checksum verification failed'
        tar -xzf "$tmp_dir/$UV_ARCHIVE" --no-same-owner --no-same-permissions --touch -C "$tmp_dir"
        assert_root_directory "$tmp_dir/$UV_DIRECTORY"
        assert_root_file "$tmp_dir/$UV_DIRECTORY/uv"
        assert_root_file "$tmp_dir/$UV_DIRECTORY/uvx"
        [ "$("$tmp_dir/$UV_DIRECTORY/uv" --version)" = "uv $UV_VERSION" ] || fail 'invalid uv archive'
        [ "$("$tmp_dir/$UV_DIRECTORY/uvx" --version)" = "uvx $UV_VERSION" ] || fail 'invalid uvx archive'
        install -T -o root -g root -m 0755 "$tmp_dir/$UV_DIRECTORY/uv" /usr/local/bin/uv
        install -T -o root -g root -m 0755 "$tmp_dir/$UV_DIRECTORY/uvx" /usr/local/bin/uvx
        assert_uv_installation
    )
}

if [ "$(id -u)" -ne 0 ]; then
    fail 'provisioning must run as root'
fi

if [ "${WSL_DISTRO_NAME:-}" != 'openhands-worker' ]; then
    fail 'provisioning must run in openhands-worker'
fi

resolve_assets
if ! id agent >/dev/null 2>&1; then
    if [ -e /home/agent ] || [ -L /home/agent ]; then
        fail 'agent home must be absent before account creation'
    fi
    useradd -K HOME_MODE=0700 -K UMASK=0077 --create-home --shell /bin/bash --user-group agent
fi
assert_agent
assert_agent_directory /home/agent
for path in /home/agent/.openhands /home/agent/.claude /home/agent/.codex /home/agent/workspaces; do
    ensure_private_directory "$path"
done

if [ "$(uname -m)" != 'x86_64' ]; then
    fail 'unsupported architecture: only x86_64 is supported'
fi
DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl xz-utils
install_node
install_uv

if [ -L /etc/wsl.conf ] || [ -d /etc/wsl.conf ] || { [ -e /etc/wsl.conf ] && [ ! -f /etc/wsl.conf ]; }; then
    fail 'unsafe path: /etc/wsl.conf'
fi
install -T -o root -g root -m 0644 "$config_path" /etc/wsl.conf
