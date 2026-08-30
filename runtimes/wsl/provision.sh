#!/bin/bash
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
set -euo pipefail
umask 022

readonly NODE_VERSION=24.20.0
readonly NODE_DIRECTORY="node-v${NODE_VERSION}-linux-x64"
readonly NODE_ARCHIVE="${NODE_DIRECTORY}.tar.xz"
readonly OPENHANDS_ROOT=/opt/openhands
readonly NODE_HOME="${OPENHANDS_ROOT}/${NODE_DIRECTORY}"
readonly NODE_BINARY="${NODE_HOME}/bin/node"
readonly NPM_CLI="${NODE_HOME}/lib/node_modules/npm/bin/npm-cli.js"
readonly NPX_CLI="${NODE_HOME}/lib/node_modules/npm/bin/npx-cli.js"
readonly NODE_MANIFEST=.openhands-manifest
readonly UV_VERSION=0.12.7
readonly UV_DIRECTORY=uv-x86_64-unknown-linux-gnu
readonly UV_ARCHIVE="${UV_DIRECTORY}.tar.gz"
readonly UV_TARGET=x86_64-unknown-linux-gnu

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
    local entry name uid gid home shell

    entry=$(/usr/bin/getent passwd agent) || fail 'agent account is missing'
    IFS=: read -r name _ uid gid _ home shell <<< "$entry"
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

generate_node_manifest() {
    local root=$1
    local output=$2
    local paths_file sorted_file path relative metadata mode uid gid hash_output hash target

    paths_file=$(/usr/bin/mktemp "$node_stage_root/manifest-paths.XXXXXX") || fail 'unable to create manifest path list'
    register_cleanup "$paths_file"
    sorted_file=$(/usr/bin/mktemp "$node_stage_root/manifest-sorted.XXXXXX") || fail 'unable to create sorted manifest path list'
    register_cleanup "$sorted_file"
    run_clean /usr/bin/find "$root" -mindepth 1 ! -path "$root/$NODE_MANIFEST" -print0 > "$paths_file" ||
        fail 'unable to list Node.js files'
    run_clean /usr/bin/sort -z -- "$paths_file" > "$sorted_file" || fail 'unable to sort Node.js files'
    : > "$output" || fail 'unable to create Node.js manifest'

    while IFS= read -r -d '' path; do
        relative=${path#"$root/"}
        [[ $relative != *$'\t'* && $relative != *$'\n'* ]] || fail "unsupported Node.js path: $relative"
        metadata=$(run_clean /usr/bin/stat -c '%a %u %g' -- "$path") || fail "unable to inspect Node.js path: $relative"
        IFS=' ' read -r mode uid gid <<< "$metadata"
        [ "$uid:$gid" = '0:0' ] || fail "invalid Node.js ownership: $relative"

        if [ -L "$path" ]; then
            target=$(run_clean /usr/bin/readlink "$path") || fail "unable to read Node.js symlink: $relative"
            [[ $target != *$'\t'* && $target != *$'\n'* ]] || fail "unsupported Node.js symlink: $relative"
            printf 'L\t%s\t%s\t%s\n' "$mode" "$target" "$relative" >> "$output"
        elif [ -d "$path" ]; then
            (( (8#$mode & 0022) == 0 )) || fail "writable Node.js directory: $relative"
            printf 'D\t%s\t%s\n' "$mode" "$relative" >> "$output"
        elif [ -f "$path" ]; then
            (( (8#$mode & 0022) == 0 )) || fail "writable Node.js file: $relative"
            hash_output=$(run_clean /usr/bin/sha256sum -- "$path") || fail "unable to hash Node.js file: $relative"
            hash=${hash_output:0:64}
            [[ $hash =~ ^[0-9a-f]{64}$ ]] || fail "invalid Node.js hash: $relative"
            printf 'F\t%s\t%s\t%s\n' "$mode" "$hash" "$relative" >> "$output"
        else
            fail "unsupported Node.js file type: $relative"
        fi
    done < "$sorted_file"
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
    assert_safe_tree_links "$staged_node_home"
    assert_root_nonwritable_file "$staged_node_home/bin/node"
    assert_root_nonwritable_file "$staged_node_home/lib/node_modules/npm/bin/npm-cli.js"
    assert_root_nonwritable_file "$staged_node_home/lib/node_modules/npm/bin/npx-cli.js"

    if path_exists "$staged_node_home/$NODE_MANIFEST"; then
        fail 'Node.js archive contains reserved manifest'
    fi
    staged_node_manifest="$node_stage_root/$NODE_MANIFEST"
    generate_node_manifest "$staged_node_home" "$staged_node_manifest"
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
    local current_manifest

    assert_exact_root_directory "$NODE_HOME"
    assert_root_file "$NODE_HOME/$NODE_MANIFEST" 644
    /usr/bin/cmp -s "$NODE_HOME/$NODE_MANIFEST" "$staged_node_manifest" || fail 'foreign Node.js manifest'
    assert_safe_tree_links "$NODE_HOME"

    current_manifest=$(/usr/bin/mktemp "$node_stage_root/installed-manifest.XXXXXX")
    register_cleanup "$current_manifest"
    generate_node_manifest "$NODE_HOME" "$current_manifest"
    /usr/bin/cmp -s "$current_manifest" "$staged_node_manifest" || fail 'invalid Node.js installation'
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

if [ "${WSL_DISTRO_NAME:-}" != 'openhands-worker' ]; then
    fail 'provisioning must run in openhands-worker'
fi

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

install_wsl_config

if [ "$(/usr/bin/uname -m)" != 'x86_64' ]; then
    fail 'unsupported architecture: only x86_64 is supported'
fi
preflight_tool_paths
/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get update
/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive \
    /usr/bin/apt-get install -y --no-install-recommends ca-certificates curl xz-utils
stage_toolchain
validate_existing_tool_paths
commit_toolchain
verify_toolchain
