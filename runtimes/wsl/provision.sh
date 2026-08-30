#!/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
umask 022

readonly NODE_VERSION=24.20.0
readonly OPENHANDS_ROOT=/opt/openhands
readonly OPENHANDS_ETC=/etc/openhands
readonly NODE_MANIFEST=.openhands-manifest
readonly AGENT_PREFIX=/home/agent/.local
readonly NPM_CACHE=/home/agent/.cache/npm
readonly NPM_GLOBALCONFIG="${OPENHANDS_ETC}/npmrc"
readonly AGENT_BIN="${AGENT_PREFIX}/bin"
readonly CLAUDE_CODE_PACKAGE='@anthropic-ai/claude-code@2.1.251'
readonly -a AGENT_PACKAGES=(
    '@openhands/agent-canvas@1.16.0'
    '@agentclientprotocol/claude-agent-acp@0.63.0'
    '@agentclientprotocol/codex-acp@1.1.7'
    '@anthropic-ai/claude-code@2.1.251'
    '@openai/codex@0.151.0'
)
readonly -a AGENT_NO_SCRIPT_PACKAGES=(
    '@openhands/agent-canvas@1.16.0'
    '@agentclientprotocol/claude-agent-acp@0.63.0'
    '@agentclientprotocol/codex-acp@1.1.7'
    '@openai/codex@0.151.0'
)
readonly UV_VERSION=0.12.7
readonly RBW_PACKAGE_VERSION=1.13.2-7
readonly RBW_BINARY=/usr/bin/rbw
readonly RBW_PINENTRY_DIRECTORY=/usr/local/libexec
readonly RBW_PINENTRY="${RBW_PINENTRY_DIRECTORY}/openhands-rbw-pinentry"
readonly PYTHON_PACKAGE=python3-minimal
readonly PYTHON_STDLIB_PACKAGE=python3
readonly PYTHON_BINARY=/usr/bin/python3

node_stage_root=
staged_node_home=
staged_node_manifest=
uv_stage_root=
staged_uv_directory=
cleanup_paths=()

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

run_clean() {
    /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

run_agent_clean() {
    /usr/sbin/runuser -u agent -- /usr/bin/env -i HOME=/home/agent \
        PATH=/usr/local/bin:/usr/bin:/bin NPM_CONFIG_USERCONFIG=/dev/null \
        NPM_CONFIG_GLOBALCONFIG="$NPM_GLOBALCONFIG" "$@"
}

path_exists() {
    [ -e "$1" ] || [ -L "$1" ]
}

register_cleanup() {
    cleanup_paths+=("$1")
}

cleanup() {
    local path

    for path in "${cleanup_paths[@]}"; do
        if path_exists "$path"; then
            /usr/bin/rm -rf -- "$path"
        fi
    done
}

assert_agent_directory() {
    local path=$1

    if [ -L "$path" ] || [ ! -d "$path" ] || [ "$(/usr/bin/stat -c '%U:%G %a' "$path")" != 'agent:agent 700' ]; then
        fail "invalid agent directory: $path"
    fi
}

assert_agent() {
    local entry name uid _gid home shell

    entry=$(/usr/bin/getent passwd agent) || fail 'agent account is missing'
    IFS=: read -r name _ uid _gid _ home shell <<< "$entry"
    case $uid in
        ''|*[!0-9]*) fail 'agent UID is invalid' ;;
    esac
    if [ "$name" != 'agent' ] || [ "$home" != '/home/agent' ] || [ "$shell" != '/bin/bash' ] || [ "$uid" -eq 0 ] ||
        [ "$(/usr/bin/id -gn agent)" != 'agent' ] || [ "$(/usr/bin/id -nG agent)" != 'agent' ]; then
        fail 'agent account does not match the runtime contract'
    fi
}

resolve_assets() {
    local payload_path

    if ! script_path=$(/usr/bin/readlink -f -- "${BASH_SOURCE[0]}"); then
        fail 'unable to resolve provisioning script'
    fi
    if [ -z "$script_path" ] || [ ! -f "$script_path" ]; then
        fail 'provisioning script must be a regular file'
    fi
    asset_dir=$(/usr/bin/dirname "$script_path")
    payload_path="$asset_dir/wsl.conf"
    if [ -L "$payload_path" ] || [ ! -f "$payload_path" ]; then
        fail 'wsl.conf must be a regular sibling file'
    fi
    if ! config_path=$(/usr/bin/readlink -f -- "$payload_path"); then
        fail 'unable to resolve wsl.conf'
    fi
    if [ -z "$config_path" ] || [ ! -f "$config_path" ] || [ "$(/usr/bin/dirname "$config_path")" != "$asset_dir" ]; then
        fail 'wsl.conf must resolve to the provisioning script directory'
    fi
}

ensure_private_directory() {
    local path=$1

    if path_exists "$path"; then
        assert_agent_directory "$path"
        return
    fi
    /usr/sbin/runuser -u agent -- /usr/bin/mkdir -m 0700 -- "$path"
    assert_agent_directory "$path"
}

assert_agent_npm_ancestor() {
    local path=$1
    local required=$2
    local mode

    if ! path_exists "$path"; then
        [ "$required" = false ] && return
        fail "missing agent npm directory: $path"
    fi
    if [ -L "$path" ] || [ ! -d "$path" ] || [ "$(/usr/bin/stat -c '%U:%G' "$path")" != 'agent:agent' ]; then
        fail "invalid agent npm directory: $path"
    fi
    mode=$(/usr/bin/stat -c '%a' "$path")
    (( (8#$mode & 0022) == 0 )) || fail "writable agent npm directory: $path"
}

assert_agent_npm_ancestors() {
    local required=$1
    local path

    for path in "${AGENT_BIN}" "${AGENT_PREFIX}/lib" "${AGENT_PREFIX}/lib/node_modules" \
        "${AGENT_PREFIX}/lib/node_modules/@openhands" "${AGENT_PREFIX}/lib/node_modules/@agentclientprotocol" \
        "${AGENT_PREFIX}/lib/node_modules/@anthropic-ai" "${AGENT_PREFIX}/lib/node_modules/@openai"; do
        assert_agent_npm_ancestor "$path" "$required"
    done
}

assert_agent_package() {
    local package=$1
    local version=$2
    local package_dir="${AGENT_PREFIX}/lib/node_modules/${package}"
    local node_modules_dir canonical_package_dir output

    if [ -L "$package_dir" ] || [ ! -d "$package_dir" ] || [ -L "$package_dir/package.json" ] ||
        [ ! -f "$package_dir/package.json" ]; then
        fail "invalid agent package: $package"
    fi
    node_modules_dir=$(/usr/bin/readlink -f -- "${AGENT_PREFIX}/lib/node_modules") || fail "invalid agent package: $package"
    canonical_package_dir=$(/usr/bin/readlink -f -- "$package_dir") || fail "invalid agent package: $package"
    case $canonical_package_dir in
        "$node_modules_dir"/*) ;;
        *) fail "invalid agent package: $package" ;;
    esac
    # shellcheck disable=SC2016
    output=$(run_agent_clean "$NODE_BINARY" -e \
        'const packageJson = require(process.argv[1]); if (packageJson.name !== process.argv[2] || packageJson.version !== process.argv[3]) process.exit(1); process.stdout.write(`${packageJson.name}@${packageJson.version}`);' \
        "$canonical_package_dir/package.json" "$package" "$version") || fail "invalid agent package: $package"
    [ "$output" = "${package}@${version}" ] || fail "invalid agent package: $package"
}

assert_exact_agent_packages() {
    local installed
    local output

    installed=$(run_agent_clean "$NODE_BINARY" "$NPM_CLI" --prefix "$AGENT_PREFIX" --cache "$NPM_CACHE" \
        --global --depth=0 --json ls) || fail 'unable to list agent npm packages'
    # shellcheck disable=SC2016
    output=$(run_agent_clean "$NODE_BINARY" -e \
        'const expected = Object.fromEntries(process.argv.slice(2).map(spec => { const at = spec.lastIndexOf("@"); return [spec.slice(0, at), spec.slice(at + 1)]; })); const packages = JSON.parse(process.argv[1]).dependencies || {}; if (Object.keys(packages).length !== Object.keys(expected).length || Object.entries(expected).some(([name, version]) => packages[name]?.version !== version)) process.exit(1); process.stdout.write("ok");' \
        "$installed" "${AGENT_PACKAGES[@]}") || fail 'invalid agent npm package set'
    [ "$output" = ok ] || fail 'invalid agent npm package set'
}

assert_agent_bin() {
    local name=$1
    local package=$2
    local path="${AGENT_BIN}/${name}"
    local package_dir="${AGENT_PREFIX}/lib/node_modules/${package}"
    local canonical_package_dir target resolved

    if [ ! -L "$path" ] || [ "$(/usr/bin/stat -c '%U:%G' "$path")" != 'agent:agent' ]; then
        fail "invalid agent executable: $name"
    fi
    target=$(/usr/bin/readlink -- "$path") || fail "unable to read agent executable: $name"
    case $target in
        /*|*$'\t'*|*$'\n'*) fail "unsafe agent executable: $name" ;;
    esac
    canonical_package_dir=$(/usr/bin/readlink -f -- "$package_dir") || fail "invalid agent executable: $name"
    resolved=$(/usr/bin/readlink -f -- "$path") || fail "unable to resolve agent executable: $name"
    case $resolved in
        "$canonical_package_dir"/*) ;;
        *) fail "unsafe agent executable: $name" ;;
    esac
    if [ -L "$resolved" ] || [ ! -f "$resolved" ] || [ ! -x "$resolved" ] ||
        [ "$(/usr/bin/stat -c '%U:%G' "$resolved")" != 'agent:agent' ]; then
        fail "invalid agent executable: $name"
    fi
}

assert_exact_agent_bins() {
    local path name

    assert_agent_bin agent-canvas @openhands/agent-canvas
    assert_agent_bin claude-agent-acp @agentclientprotocol/claude-agent-acp
    assert_agent_bin codex-acp @agentclientprotocol/codex-acp
    assert_agent_bin claude @anthropic-ai/claude-code
    assert_agent_bin codex @openai/codex
    while IFS= read -r -d '' path; do
        name=${path##*/}
        case $name in
            agent-canvas|claude-agent-acp|codex-acp|claude|codex) ;;
            *) fail "unexpected agent executable: $name" ;;
        esac
    done < <(/usr/bin/find -P "$AGENT_BIN" -mindepth 1 -maxdepth 1 -print0)
}

ensure_npm_global_config() {
    assert_trusted_root_directory /etc
    if path_exists "$OPENHANDS_ETC"; then
        assert_exact_root_directory "$OPENHANDS_ETC"
    else
        /usr/bin/mkdir -m 0755 -- "$OPENHANDS_ETC"
        assert_exact_root_directory "$OPENHANDS_ETC"
    fi
    if path_exists "$NPM_GLOBALCONFIG"; then
        assert_root_file "$NPM_GLOBALCONFIG" 644
        [ ! -s "$NPM_GLOBALCONFIG" ] || fail "invalid npm configuration: $NPM_GLOBALCONFIG"
    else
        /usr/bin/install -T -o root -g root -m 0644 /dev/null "$NPM_GLOBALCONFIG"
        assert_root_file "$NPM_GLOBALCONFIG" 644
    fi
}

preflight_agent_npm_paths() {
    ensure_npm_global_config
    ensure_private_directory "$AGENT_PREFIX"
    ensure_private_directory /home/agent/.cache
    ensure_private_directory "$NPM_CACHE"
    assert_agent_npm_ancestors false
}

install_agent_packages() {
    run_agent_clean "$NODE_BINARY" "$NPM_CLI" --prefix "$AGENT_PREFIX" --cache "$NPM_CACHE" \
        --global --no-audit --no-fund --no-update-notifier --ignore-scripts install \
        "${AGENT_NO_SCRIPT_PACKAGES[@]}" || fail 'agent npm installation failed'
    run_agent_clean "$NODE_BINARY" "$NPM_CLI" --prefix "$AGENT_PREFIX" --cache "$NPM_CACHE" \
        --global --no-audit --no-fund --no-update-notifier --strict-allow-scripts \
        --allow-scripts=@anthropic-ai/claude-code install "$CLAUDE_CODE_PACKAGE" || fail 'Claude Code installation failed'
}

verify_agent_packages() {
    assert_agent_directory "$AGENT_PREFIX"
    assert_agent_directory /home/agent/.cache
    assert_agent_directory "$NPM_CACHE"
    assert_agent_npm_ancestors true
    assert_exact_agent_packages
    assert_agent_package @openhands/agent-canvas 1.16.0
    assert_agent_package @agentclientprotocol/claude-agent-acp 0.63.0
    assert_agent_package @agentclientprotocol/codex-acp 1.1.7
    assert_agent_package @anthropic-ai/claude-code 2.1.251
    assert_agent_package @openai/codex 0.151.0
    assert_exact_agent_bins
    [ "$(run_agent_clean "${AGENT_BIN}/claude" --version)" = '2.1.251 (Claude Code)' ] || fail 'invalid Claude Code installation'
    [ "$(run_agent_clean "${AGENT_BIN}/codex" --version)" = 'codex-cli 0.151.0' ] || fail 'invalid Codex installation'
}

install_wsl_config() {
    if [ -L /etc/wsl.conf ] || [ -d /etc/wsl.conf ] || { [ -e /etc/wsl.conf ] && [ ! -f /etc/wsl.conf ]; }; then
        fail 'unsafe path: /etc/wsl.conf'
    fi
    /usr/bin/install -T -o root -g root -m 0644 "$config_path" /etc/wsl.conf
}

assert_trusted_root_directory() {
    local path=$1
    local mode

    if [ -L "$path" ] || [ ! -d "$path" ] || [ "$(/usr/bin/stat -c '%u:%g' "$path")" != '0:0' ]; then
        fail "invalid trusted directory: $path"
    fi
    mode=$(/usr/bin/stat -c '%a' "$path")
    case $mode in
        ''|*[!0-7]*) fail "invalid trusted directory mode: $path" ;;
    esac
    if (( (8#$mode & 0022) != 0 )); then
        fail "writable trusted directory: $path"
    fi
}

assert_exact_root_directory() {
    local path=$1

    if [ -L "$path" ] || [ ! -d "$path" ] || [ "$(/usr/bin/stat -c '%u:%g %a' "$path")" != '0:0 755' ]; then
        fail "invalid root directory: $path"
    fi
}

assert_root_file() {
    local path=$1
    local expected_mode=$2

    if [ -L "$path" ] || [ ! -f "$path" ] || [ "$(/usr/bin/stat -c '%u:%g %a' "$path")" != "0:0 $expected_mode" ]; then
        fail "invalid root file: $path"
    fi
}

assert_root_nonwritable_file() {
    local path=$1
    local mode

    if [ -L "$path" ] || [ ! -f "$path" ] || [ "$(/usr/bin/stat -c '%u:%g' "$path")" != '0:0' ]; then
        fail "invalid root file: $path"
    fi
    mode=$(/usr/bin/stat -c '%a' "$path")
    if (( (8#$mode & 0022) != 0 )); then
        fail "writable root file: $path"
    fi
}

assert_package_files() {
    local package=$1
    local verification line

    verification=$(run_clean /usr/bin/dpkg --verify "$package") || fail "unable to verify $package package"
    [ -z "$verification" ] && return
    # Ubuntu's package excludes omit docs/man; permit only those explicit missing records, never altered files.
    while IFS= read -r line; do
        [[ $line =~ ^missing[[:blank:]]+/usr/share/(man|doc)/[^[:cntrl:]]+$ ]] || fail "invalid $package package files"
    done <<< "$verification"
}

assert_rbw_package() {
    local status owner

    status=$(run_clean /usr/bin/dpkg-query -W -f="\${db:Status-Abbrev} \${Version}\\n" rbw) ||
        fail 'unable to query rbw package'
    [ "$status" = "ii  $RBW_PACKAGE_VERSION" ] || fail 'invalid rbw package'
    owner=$(run_clean /usr/bin/dpkg-query -S "$RBW_BINARY") || fail 'unable to query rbw binary owner'
    [ "$owner" = "rbw: $RBW_BINARY" ] || fail 'invalid rbw binary owner'
    assert_package_files rbw
}

assert_python_package() {
    local status stdlib_status owner target resolved

    status=$(run_clean /usr/bin/dpkg-query -W -f="\${db:Status-Abbrev}\\n" "$PYTHON_PACKAGE") ||
        fail 'unable to query python3-minimal package'
    [ "$status" = 'ii ' ] || fail 'invalid python3-minimal package'
    stdlib_status=$(run_clean /usr/bin/dpkg-query -W -f="\${db:Status-Abbrev}\\n" "$PYTHON_STDLIB_PACKAGE") ||
        fail 'unable to query python3 package'
    [ "$stdlib_status" = 'ii ' ] || fail 'invalid python3 package'
    owner=$(run_clean /usr/bin/dpkg-query -S "$PYTHON_BINARY") || fail 'unable to query python3 binary owner'
    [ "$owner" = "$PYTHON_PACKAGE: $PYTHON_BINARY" ] || fail 'invalid python3 binary owner'
    assert_package_files "$PYTHON_PACKAGE"
    assert_package_files "$PYTHON_STDLIB_PACKAGE"
    if [ -L "$PYTHON_BINARY" ]; then
        target=$(/usr/bin/readlink "$PYTHON_BINARY") || fail 'unable to read python3 entry point'
        case $target in
            python3.[0-9]*) ;;
            *) fail 'invalid python3 entry point' ;;
        esac
        [[ $target != *$'\t'* && $target != *$'\n'* ]] || fail 'invalid python3 entry point'
        resolved=$(/usr/bin/readlink -f "$PYTHON_BINARY") || fail 'unable to resolve python3 entry point'
        case $resolved in
            /usr/bin/python3.[0-9]*) ;;
            *) fail 'invalid python3 entry point' ;;
        esac
    else
        resolved=$PYTHON_BINARY
    fi
    assert_root_file "$resolved" 755
    run_clean "$PYTHON_BINARY" -I -c 'import queue' || fail 'python3 standard library is incomplete'
}

write_rbw_pinentry() {
    local temp

    for path in /usr /usr/local; do
        assert_trusted_root_directory "$path"
    done
    if path_exists "$RBW_PINENTRY_DIRECTORY"; then
        assert_exact_root_directory "$RBW_PINENTRY_DIRECTORY"
    else
        /usr/bin/mkdir -m 0755 -- "$RBW_PINENTRY_DIRECTORY"
        assert_exact_root_directory "$RBW_PINENTRY_DIRECTORY"
    fi

    temp=$(/usr/bin/mktemp "${RBW_PINENTRY_DIRECTORY}/.openhands-rbw-pinentry.XXXXXX") ||
        fail 'unable to stage rbw pinentry'
    register_cleanup "$temp"
    /usr/bin/cat > "$temp" <<'PYTHON'
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
    /usr/bin/chown root:root "$temp"
    /usr/bin/chmod 0755 "$temp"
    if path_exists "$RBW_PINENTRY"; then
        assert_root_file "$RBW_PINENTRY" 755
        /usr/bin/cmp -s "$RBW_PINENTRY" "$temp" || fail 'foreign rbw pinentry'
    else
        /usr/bin/mv -T -n -- "$temp" "$RBW_PINENTRY"
        if path_exists "$temp"; then
            assert_root_file "$RBW_PINENTRY" 755
            /usr/bin/cmp -s "$RBW_PINENTRY" "$temp" || fail 'foreign rbw pinentry'
            /usr/bin/rm -f -- "$temp"
        fi
    fi
    assert_root_file "$RBW_PINENTRY" 755
}

verify_rbw() {
    assert_rbw_package
    assert_root_file "$RBW_BINARY" 755
    [ "$(run_clean "$RBW_BINARY" --version)" = 'rbw 1.13.2' ] || fail 'invalid rbw installation'
    assert_python_package
    write_rbw_pinentry
}

print_wrapper() {
    local cli=$1

    printf '#!/bin/sh\nexec %s %s "$@"\n' "$NODE_BINARY" "$cli"
}

assert_uv_version() {
    local name=$1
    local binary=$2
    local context=$3
    local output prefix metadata

    output=$(run_clean "$binary" --version)
    prefix="$name $UV_VERSION ("
    if [[ $output == *$'\n'* ]] || [[ $output != "$prefix"* ]] || [[ $output != *')' ]]; then
        fail "invalid $name $context"
    fi

    metadata=${output#"$prefix"}
    metadata=${metadata%')'}
    if [[ $metadata == *'('* ]] || [[ $metadata == *')'* ]]; then
        fail "invalid $name $context"
    fi
    case $metadata in
        "$UV_TARGET"|*" $UV_TARGET") ;;
        *) fail "invalid $name $context" ;;
    esac
}

assert_node_link() {
    if [ ! -L /usr/local/bin/node ] || [ "$(/usr/bin/stat -c '%u:%g' /usr/local/bin/node)" != '0:0' ] ||
        [ "$(/usr/bin/readlink /usr/local/bin/node)" != "$NODE_BINARY" ]; then
        fail 'invalid node entry point'
    fi
}

assert_wrapper() {
    local name=$1
    local cli=$2
    local path="/usr/local/bin/$name"

    assert_root_file "$path" 755
    /usr/bin/cmp -s "$path" <(print_wrapper "$cli") || fail "invalid $name entry point"
}

preflight_tool_paths() {
    local path

    for path in /opt /usr/local /usr/local/bin; do
        assert_trusted_root_directory "$path"
    done

    if ! path_exists "$OPENHANDS_ROOT"; then
        /usr/bin/mkdir -m 0755 -- "$OPENHANDS_ROOT" || true
    fi
    assert_exact_root_directory "$OPENHANDS_ROOT"

    if path_exists "$NODE_HOME"; then
        assert_exact_root_directory "$NODE_HOME"
    fi
    if path_exists /usr/local/bin/node; then
        assert_node_link
    fi
    if path_exists /usr/local/bin/npm; then
        assert_root_file /usr/local/bin/npm 755
    fi
    if path_exists /usr/local/bin/npx; then
        assert_root_file /usr/local/bin/npx 755
    fi
    if path_exists /usr/local/bin/uv; then
        assert_root_file /usr/local/bin/uv 755
    fi
    if path_exists /usr/local/bin/uvx; then
        assert_root_file /usr/local/bin/uvx 755
    fi
}

download() {
    local url=$1
    local output=$2

    run_clean /usr/bin/curl --disable --fail --location --proto '=https' --proto-redir '=https' \
        --tlsv1.2 --tls-max 1.3 --cacert /etc/ssl/certs/ca-certificates.crt --retry 3 \
        --output "$output" "$url"
}

assert_safe_archive() {
    local archive=$1
    local expected_root=$2
    local members_file
    local member
    local members=0

    members_file=$(/usr/bin/mktemp "${archive}.members.XXXXXX") || fail 'unable to create archive member list'
    register_cleanup "$members_file"
    run_clean /usr/bin/tar --quoting-style=escape -tf "$archive" > "$members_file" ||
        fail "unreadable archive: $archive"
    while IFS= read -r member; do
        members=$((members + 1))
        [[ $member != *\\* ]] || fail "unsupported archive member: $member"
        case $member in
            "$expected_root"|"$expected_root/"|"$expected_root/"*) ;;
            *) fail "unsafe archive member: $member" ;;
        esac
        case "/$member/" in
            *'/../'*) fail "unsafe archive member: $member" ;;
        esac
    done < "$members_file"
    [ "$members" -gt 0 ] || fail "empty archive: $archive"
}

assert_safe_tree_links() {
    local root=$1
    local links_file link owner target resolved

    links_file=$(/usr/bin/mktemp "$node_stage_root/tree-links.XXXXXX") || fail 'unable to create symlink list'
    register_cleanup "$links_file"
    run_clean /usr/bin/find "$root" -type l -print0 > "$links_file" || fail 'unable to list symlinks'
    while IFS= read -r -d '' link; do
        owner=$(run_clean /usr/bin/stat -c '%u:%g' "$link") || fail "unable to inspect symlink: $link"
        [ "$owner" = '0:0' ] || fail "invalid symlink owner: $link"
        target=$(run_clean /usr/bin/readlink "$link") || fail "unable to read symlink: $link"
        case $target in
            /*) fail "unsafe symlink target: $link" ;;
        esac
        [[ $target != *$'\t'* && $target != *$'\n'* ]] || fail "unsafe symlink target: $link"
        resolved=$(run_clean /usr/bin/readlink -m -- "$(/usr/bin/dirname "$link")/$target") ||
            fail "unable to resolve symlink: $link"
        case $resolved in
            "$root/"*) ;;
            *) fail "unsafe symlink target: $link" ;;
        esac
        [ -e "$link" ] || fail "dangling symlink: $link"
    done < "$links_file"
}

assert_safe_node_tree() {
    local root=$1
    local unsafe_file unsafe

    unsafe_file=$(/usr/bin/mktemp "$node_stage_root/tree-unsafe.XXXXXX") || fail 'unable to create Node.js safety scan'
    register_cleanup "$unsafe_file"
    run_clean /usr/bin/find -P "$root" -mindepth 1 ! -path "$root/$NODE_MANIFEST" \
        \( -path "*"$'\t'"*" -o -path "*"$'\n'"*" -o ! -uid 0 -o ! -gid 0 \
        -o \( \( -type f -o -type d \) -perm /022 \) \
        -o ! \( -type f -o -type d -o -type l \) \) -print0 -quit > "$unsafe_file" ||
        fail 'unable to inspect Node.js tree'
    if IFS= read -r -d '' unsafe < "$unsafe_file"; then
        fail "unsafe Node.js path: ${unsafe#"$root/"}"
    fi
    assert_safe_tree_links "$root"
}

canonical_node_digest() {
    local root=$1
    local digest_output pipeline_status

    if digest_output=$(
        set -o pipefail
        run_clean /usr/bin/tar --create --file=- --format=gnu --sort=name --mtime=@0 --numeric-owner \
            --anchored --exclude="./$NODE_MANIFEST" --directory="$root" . |
            run_clean /usr/bin/sha256sum
        pipeline_status=("${PIPESTATUS[@]}")
        [ "${pipeline_status[1]}" -eq 0 ] || exit 91
        [ "${pipeline_status[0]}" -eq 0 ] || exit 90
    ); then
        :
    else
        case $? in
            90) fail 'unable to archive Node.js tree' ;;
            91) fail 'unable to hash Node.js tree' ;;
            *) fail 'unable to compute Node.js digest' ;;
        esac
    fi
    [[ $digest_output =~ ^([0-9a-f]{64})\ \ -$ ]] || fail 'invalid Node.js digest'
    printf '%s\n' "${BASH_REMATCH[1]}"
}

write_node_manifest() {
    local root=$1
    local output=$2
    local digest temp

    digest=$(canonical_node_digest "$root")
    temp=$(/usr/bin/mktemp "${output}.XXXXXX") || fail 'unable to create Node.js manifest'
    register_cleanup "$temp"
    printf 'v2 sha256 %s\n' "$digest" > "$temp" || fail 'unable to write Node.js manifest'
    /usr/bin/chown root:root "$temp"
    /usr/bin/chmod 0644 "$temp"
    /usr/bin/mv -T -- "$temp" "$output" || fail 'unable to publish Node.js manifest'
}

node_manifest_digest() {
    local manifest=$1
    local digest
    local -a lines=()

    mapfile -t lines < "$manifest" || return 1
    if [ "${#lines[@]}" -ne 1 ] || [[ ! ${lines[0]} =~ ^v2\ sha256\ ([0-9a-f]{64})$ ]]; then
        return 1
    fi
    digest=${BASH_REMATCH[1]}
    /usr/bin/cmp -s "$manifest" <(printf 'v2 sha256 %s\n' "$digest") || return 1
    printf '%s\n' "$digest"
}

replace_node_manifest() {
    local destination="$NODE_HOME/$NODE_MANIFEST"
    local temp

    temp=$(/usr/bin/mktemp "$node_stage_root/node-manifest-replacement.XXXXXX") ||
        fail 'unable to create Node.js manifest replacement'
    register_cleanup "$temp"
    /usr/bin/install -T -o root -g root -m 0644 "$staged_node_manifest" "$temp"
    /usr/bin/mv -T -- "$temp" "$destination" || fail 'unable to replace Node.js manifest'
}

stage_node() {
    local checksums="$node_stage_root/SHASUMS256.txt"
    local archive="$node_stage_root/$NODE_ARCHIVE"
    local checksum

    download "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" "$checksums"
    download "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_ARCHIVE}" "$archive"
    checksum=$(/usr/bin/awk -v archive="$NODE_ARCHIVE" '$2 == archive { print; count++ } END { if (count != 1) exit 1 }' "$checksums") ||
        fail 'Node.js checksum is missing or ambiguous'
    printf '%s\n' "$checksum" | (cd "$node_stage_root" && run_clean /usr/bin/sha256sum -c -) ||
        fail 'Node.js checksum verification failed'

    assert_safe_archive "$archive" "$NODE_DIRECTORY"
    run_clean /usr/bin/tar -xf "$archive" --no-same-owner --no-same-permissions --delay-directory-restore -C "$node_stage_root"
    staged_node_home="$node_stage_root/$NODE_DIRECTORY"
    assert_exact_root_directory "$staged_node_home"
    assert_root_nonwritable_file "$staged_node_home/bin/node"
    assert_root_nonwritable_file "$staged_node_home/lib/node_modules/npm/bin/npm-cli.js"
    assert_root_nonwritable_file "$staged_node_home/lib/node_modules/npm/bin/npx-cli.js"

    if path_exists "$staged_node_home/$NODE_MANIFEST"; then
        fail 'Node.js archive contains reserved manifest'
    fi
    assert_safe_node_tree "$staged_node_home"
    staged_node_manifest="$node_stage_root/$NODE_MANIFEST"
    write_node_manifest "$staged_node_home" "$staged_node_manifest"
    /usr/bin/install -T -o root -g root -m 0644 "$staged_node_manifest" "$staged_node_home/$NODE_MANIFEST"

    [ "$(run_clean "$staged_node_home/bin/node" --version)" = "v$NODE_VERSION" ] || fail 'invalid Node.js archive'
    [ "$(run_clean "$staged_node_home/bin/node" "$staged_node_home/lib/node_modules/npm/bin/npm-cli.js" --version)" = '11.19.0' ] ||
        fail 'invalid npm archive'
    [ "$(run_clean "$staged_node_home/bin/node" "$staged_node_home/lib/node_modules/npm/bin/npx-cli.js" --version)" = '11.19.0' ] ||
        fail 'invalid npx archive'
}

stage_uv() {
    local checksum_file="$uv_stage_root/${UV_ARCHIVE}.sha256"
    local archive="$uv_stage_root/$UV_ARCHIVE"
    local checksum

    download "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${UV_ARCHIVE}.sha256" "$checksum_file"
    download "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${UV_ARCHIVE}" "$archive"
    checksum=$(/usr/bin/awk 'NF { print $1; count++ } END { if (count != 1) exit 1 }' "$checksum_file") ||
        fail 'uv checksum is missing or ambiguous'
    [[ $checksum =~ ^[0-9a-f]{64}$ ]] || fail 'uv checksum is invalid'
    printf '%s  %s\n' "$checksum" "$UV_ARCHIVE" | (cd "$uv_stage_root" && run_clean /usr/bin/sha256sum -c -) ||
        fail 'uv checksum verification failed'

    assert_safe_archive "$archive" "$UV_DIRECTORY"
    run_clean /usr/bin/tar -xf "$archive" --no-same-owner --no-same-permissions --delay-directory-restore -C "$uv_stage_root"
    staged_uv_directory="$uv_stage_root/$UV_DIRECTORY"
    assert_exact_root_directory "$staged_uv_directory"
    assert_safe_tree_links "$staged_uv_directory"
    assert_root_file "$staged_uv_directory/uv" 755
    assert_root_file "$staged_uv_directory/uvx" 755
    assert_uv_version uv "$staged_uv_directory/uv" archive
    assert_uv_version uvx "$staged_uv_directory/uvx" archive
}

stage_toolchain() {
    node_stage_root=$(/usr/bin/mktemp -d "$OPENHANDS_ROOT/.node-stage.XXXXXX")
    register_cleanup "$node_stage_root"
    uv_stage_root=$(/usr/bin/mktemp -d /usr/local/bin/.uv-stage.XXXXXX)
    register_cleanup "$uv_stage_root"

    stage_node
    stage_uv
}

validate_installed_node_tree() {
    local installed_digest marker_digest staged_digest replace=false

    assert_exact_root_directory "$NODE_HOME"
    assert_root_file "$NODE_HOME/$NODE_MANIFEST" 644
    staged_digest=$(node_manifest_digest "$staged_node_manifest") || fail 'invalid staged Node.js manifest'
    if marker_digest=$(node_manifest_digest "$NODE_HOME/$NODE_MANIFEST"); then
        [ "$marker_digest" = "$staged_digest" ] || fail 'foreign Node.js manifest'
    else
        replace=true
    fi
    assert_safe_node_tree "$NODE_HOME"
    installed_digest=$(canonical_node_digest "$NODE_HOME")
    [ "$installed_digest" = "$staged_digest" ] || fail 'invalid Node.js installation'
    if $replace; then
        replace_node_manifest
    fi
}

validate_existing_tool_paths() {
    if path_exists /usr/local/bin/uv; then
        /usr/bin/cmp -s /usr/local/bin/uv "$staged_uv_directory/uv" || fail 'foreign uv installation'
    fi
    if path_exists /usr/local/bin/uvx; then
        /usr/bin/cmp -s /usr/local/bin/uvx "$staged_uv_directory/uvx" || fail 'foreign uvx installation'
    fi

    if path_exists "$NODE_HOME"; then
        validate_installed_node_tree
    fi
    if path_exists /usr/local/bin/node; then
        assert_node_link
    fi
    if path_exists /usr/local/bin/npm; then
        assert_wrapper npm "$NPM_CLI"
    fi
    if path_exists /usr/local/bin/npx; then
        assert_wrapper npx "$NPX_CLI"
    fi
}

commit_node_tree() {
    if path_exists "$NODE_HOME"; then
        validate_installed_node_tree
        return
    fi

    /usr/bin/mv -T -n -- "$staged_node_home" "$NODE_HOME"
    if path_exists "$staged_node_home"; then
        validate_installed_node_tree
    else
        assert_exact_root_directory "$NODE_HOME"
    fi
}

commit_node_link() {
    local temp_directory

    if path_exists /usr/local/bin/node; then
        assert_node_link
        return
    fi

    temp_directory=$(/usr/bin/mktemp -d /usr/local/bin/.node-link.XXXXXX)
    register_cleanup "$temp_directory"
    /usr/bin/ln -s "$NODE_BINARY" "$temp_directory/node"
    /usr/bin/chown -h root:root "$temp_directory/node"
    /usr/bin/mv -T -n -- "$temp_directory/node" /usr/local/bin/node
    /usr/bin/rm -rf -- "$temp_directory"
    assert_node_link
}

commit_wrapper() {
    local name=$1
    local cli=$2
    local destination="/usr/local/bin/$name"
    local temp

    if path_exists "$destination"; then
        assert_wrapper "$name" "$cli"
        return
    fi

    temp=$(/usr/bin/mktemp "/usr/local/bin/.${name}.XXXXXX")
    register_cleanup "$temp"
    print_wrapper "$cli" > "$temp"
    /usr/bin/chown root:root "$temp"
    /usr/bin/chmod 0755 "$temp"
    /usr/bin/mv -T -n -- "$temp" "$destination"
    /usr/bin/rm -f -- "$temp"
    assert_wrapper "$name" "$cli"
}

commit_uv_binary() {
    local name=$1
    local source="$staged_uv_directory/$name"
    local destination="/usr/local/bin/$name"
    local temp

    if path_exists "$destination"; then
        assert_root_file "$destination" 755
        /usr/bin/cmp -s "$destination" "$source" || fail "foreign $name installation"
        return
    fi

    temp=$(/usr/bin/mktemp "/usr/local/bin/.${name}.XXXXXX")
    register_cleanup "$temp"
    /usr/bin/install -T -o root -g root -m 0755 "$source" "$temp"
    /usr/bin/mv -T -n -- "$temp" "$destination"
    /usr/bin/rm -f -- "$temp"
    assert_root_file "$destination" 755
    /usr/bin/cmp -s "$destination" "$source" || fail "foreign $name installation"
}

commit_toolchain() {
    commit_node_tree
    commit_node_link
    commit_wrapper npm "$NPM_CLI"
    commit_wrapper npx "$NPX_CLI"
    commit_uv_binary uv
    commit_uv_binary uvx
}

verify_toolchain() {
    validate_installed_node_tree
    assert_node_link
    assert_wrapper npm "$NPM_CLI"
    assert_wrapper npx "$NPX_CLI"
    assert_root_file /usr/local/bin/uv 755
    assert_root_file /usr/local/bin/uvx 755
    /usr/bin/cmp -s /usr/local/bin/uv "$staged_uv_directory/uv" || fail 'invalid uv installation'
    /usr/bin/cmp -s /usr/local/bin/uvx "$staged_uv_directory/uvx" || fail 'invalid uvx installation'

    [ "$(run_clean "$NODE_BINARY" --version)" = "v$NODE_VERSION" ] || fail 'invalid Node.js installation'
    [ "$(run_clean "$NODE_BINARY" "$NPM_CLI" --version)" = '11.19.0' ] || fail 'invalid npm installation'
    [ "$(run_clean "$NODE_BINARY" "$NPX_CLI" --version)" = '11.19.0' ] || fail 'invalid npx installation'
    assert_uv_version uv /usr/local/bin/uv installation
    assert_uv_version uvx /usr/local/bin/uvx installation
}

trap cleanup EXIT

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
    fail 'provisioning must run as root'
fi

if [ "${OPENHANDS_IMAGE_BUILD:-}" != 1 ] && [ "${WSL_DISTRO_NAME:-}" != 'openhands-worker' ]; then
    fail 'provisioning must run in openhands-worker'
fi

machine_arch=$(/usr/bin/uname -m)
case "$machine_arch" in
    x86_64|amd64) node_arch=x64; uv_target=x86_64-unknown-linux-gnu ;;
    aarch64|arm64) node_arch=arm64; uv_target=aarch64-unknown-linux-gnu ;;
    *) fail "unsupported architecture: $machine_arch" ;;
esac
readonly NODE_DIRECTORY="node-v${NODE_VERSION}-linux-${node_arch}"
readonly NODE_ARCHIVE="${NODE_DIRECTORY}.tar.xz"
readonly NODE_HOME="${OPENHANDS_ROOT}/${NODE_DIRECTORY}"
readonly NODE_BINARY="${NODE_HOME}/bin/node"
readonly NPM_CLI="${NODE_HOME}/lib/node_modules/npm/bin/npm-cli.js"
readonly NPX_CLI="${NODE_HOME}/lib/node_modules/npm/bin/npx-cli.js"
readonly UV_TARGET="$uv_target"
readonly UV_DIRECTORY="uv-${UV_TARGET}"
readonly UV_ARCHIVE="${UV_DIRECTORY}.tar.gz"

resolve_assets
if ! /usr/bin/id agent >/dev/null 2>&1; then
    if [ -e /home/agent ] || [ -L /home/agent ]; then
        fail 'agent home must be absent before account creation'
    fi
    /usr/sbin/useradd -K HOME_MODE=0700 -K UMASK=0077 --create-home --shell /bin/bash --user-group agent
fi
assert_agent
assert_agent_directory /home/agent
for path in /home/agent/.openhands /home/agent/.claude /home/agent/.codex /home/agent/workspaces; do
    ensure_private_directory "$path"
done

if [ "${OPENHANDS_IMAGE_BUILD:-}" != 1 ]; then
    install_wsl_config
fi
preflight_tool_paths
/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get update
/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive \
    /usr/bin/apt-get install -y --no-install-recommends ca-certificates curl xz-utils "$PYTHON_PACKAGE" "$PYTHON_STDLIB_PACKAGE" "rbw=${RBW_PACKAGE_VERSION}"
verify_rbw
stage_toolchain
validate_existing_tool_paths
commit_toolchain
verify_toolchain
preflight_agent_npm_paths
install_agent_packages
verify_agent_packages
