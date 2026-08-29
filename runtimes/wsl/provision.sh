#!/usr/bin/env bash
set -euo pipefail

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

if [ -L /etc/wsl.conf ] || [ -d /etc/wsl.conf ] || { [ -e /etc/wsl.conf ] && [ ! -f /etc/wsl.conf ]; }; then
    fail 'unsafe path: /etc/wsl.conf'
fi
install -T -o root -g root -m 0644 "$config_path" /etc/wsl.conf
