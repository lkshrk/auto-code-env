#!/bin/sh
# Sourced inside the test container by setup.Tests.sh and overlay.Tests.sh.
set -eu

FIXTURE_LOG=/tmp/log
FIXTURE_STATE=/tmp/pkgstate
FIXTURE_SHIM=/usr/bin

fixture_install_host_stubs() {
    mkdir -p "$FIXTURE_LOG" "$FIXTURE_STATE"

    cat > /usr/bin/apt-get <<'EOF'
#!/bin/sh
echo "apt-get $*" >> /tmp/log/apt-get
case "$1" in
  update) exit 0 ;;
  install)
    shift
    for arg in "$@"; do
      case "$arg" in
        -*) continue ;;
        *=*) printf '%s' "${arg#*=}" > "/tmp/pkgstate/${arg%%=*}" ;;
        *) printf 'installed' > "/tmp/pkgstate/$arg" ;;
      esac
    done
    exit 0 ;;
esac
exit 1
EOF

    cat > /usr/bin/dpkg-query <<'EOF'
#!/bin/sh
format=''
package=''
while [ $# -gt 0 ]; do
  case "$1" in
    -W) shift ;;
    -f=*) format=${1#-f=}; shift ;;
    *) package=$1; shift ;;
  esac
done
state="/tmp/pkgstate/$package"
[ -f "$state" ] || exit 1
case "$format" in
  *Version*) printf 'ii  %s' "$(cat "$state")" ;;
  *) printf 'ii ' ;;
esac
EOF

    cat > /usr/bin/apt-mark <<'EOF'
#!/bin/sh
echo "apt-mark $*" >> /tmp/log/apt-mark
exit 0
EOF

    cat > /usr/bin/dpkg <<'EOF'
#!/bin/sh
test "$1" = --print-architecture || exit 1
echo amd64
EOF

    cat > /usr/bin/curl <<'EOF'
#!/bin/sh
echo "curl $*" >> /tmp/log/curl
output=''
previous=''
for argument in "$@"; do
  [ "$previous" = --output ] && output=$argument
  previous=$argument
done
[ -n "$output" ] || exit 1
cat /opt/fixture/docker.asc > "$output"
EOF

    chmod 0755 /usr/bin/apt-get /usr/bin/dpkg-query /usr/bin/apt-mark /usr/bin/dpkg /usr/bin/curl
    for package in ca-certificates curl openssl python3 iproute2; do
        printf 'installed' > "$FIXTURE_STATE/$package"
    done
}

fixture_install_shims() {
    cat > "$FIXTURE_SHIM/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> /tmp/log/systemctl
case "$1" in
  enable|daemon-reload) exit 0 ;;
  is-active) printf 'active\nactive\n' ;;
  *) exit 1 ;;
esac
EOF

    cat > "$FIXTURE_SHIM/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >> /tmp/log/docker
case "$1" in
  info) test -f /tmp/docker-up ;;
  image) test -f /tmp/docker-up ;;
  version) echo 29.8.0 ;;
  *) exit 1 ;;
esac
EOF

    cat > "$FIXTURE_SHIM/dockerd" <<'EOF'
#!/bin/sh
echo "dockerd $*" >> /tmp/log/dockerd
test "$1" = --validate || exit 1
python3 -c 'import json; json.load(open("/etc/docker/daemon.json"))'
EOF

    cat > "$FIXTURE_SHIM/systemd-ask-password" <<'EOF'
#!/bin/sh
cat /tmp/fixture.master
EOF

    cat > "$FIXTURE_SHIM/systemd-run" <<'EOF'
#!/bin/sh
echo "systemd-run $*" >> /tmp/log/systemd-run
credentials=$(mktemp -d)
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet|--pipe|--wait|--collect) shift ;;
    -E) export "$2"; shift 2 ;;
    -p)
      case "$2" in
        LoadCredential=*) spec=${2#LoadCredential=}; cp "${spec#*:}" "$credentials/${spec%%:*}" ;;
        *) echo "unexpected property $2" >&2; exit 1 ;;
      esac
      shift 2 ;;
    *) break ;;
  esac
done
CREDENTIALS_DIRECTORY=$credentials exec "$@"
EOF

    chmod 0755 "$FIXTURE_SHIM"/systemctl "$FIXTURE_SHIM"/docker "$FIXTURE_SHIM"/dockerd \
        "$FIXTURE_SHIM"/systemd-ask-password "$FIXTURE_SHIM"/systemd-run
}

fixture_snapshot() {
    for path in /etc/wsl.conf /etc/docker/daemon.json \
        /etc/systemd/system/docker.service.d/10-listeners.conf \
        /etc/systemd/system/docker.service.d/20-require-tls.conf \
        /etc/apt/keyrings/docker.asc /etc/apt/sources.list.d/docker.sources \
        /usr/local/libexec/coder-worker-rbw-pinentry /usr/local/sbin/coder-worker-overlay \
        /etc/coder-worker/images /etc/coder-worker/release; do
        printf '%s %s %s\n' "$path" "$(stat -c '%U:%G %a %y' "$path")" "$(sha256sum < "$path" | cut -d' ' -f1)"
    done
}
