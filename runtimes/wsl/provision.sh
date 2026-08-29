#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

assert_safe_directory() {
    local path=$1

    if [ -L "$path" ] || { [ -e "$path" ] && [ ! -d "$path" ]; }; then
        fail "unsafe path: $path"
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

if [ "$(id -u)" -ne 0 ]; then
    fail 'provisioning must run as root'
fi

if [ "${WSL_DISTRO_NAME:-}" != 'openhands-worker' ]; then
    fail 'provisioning must run in openhands-worker'
fi

assert_safe_directory /home/agent
if ! id agent >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --user-group agent
fi
assert_agent
assert_safe_directory /home/agent
if [ "$(stat -c '%U:%G' /home/agent)" != 'agent:agent' ]; then
    fail 'agent home must be owned by agent'
fi

install -d -o agent -g agent -m 0700 /home/agent
for path in /home/agent/.openhands /home/agent/.claude /home/agent/.codex /home/agent/workspaces; do
    assert_safe_directory "$path"
done
install -d -o agent -g agent -m 0700 \
    /home/agent/.openhands \
    /home/agent/.claude \
    /home/agent/.codex \
    /home/agent/workspaces

if [ -L /etc/wsl.conf ] || [ -d /etc/wsl.conf ] || { [ -e /etc/wsl.conf ] && [ ! -f /etc/wsl.conf ]; }; then
    fail 'unsafe path: /etc/wsl.conf'
fi
asset_dir=$(dirname "$(readlink -f -- "${BASH_SOURCE[0]}")")
install -T -o root -g root -m 0644 "$asset_dir/wsl.conf" /etc/wsl.conf
