#!/usr/bin/env bash
set -euo pipefail

cat > /etc/dpkg/dpkg.cfg.d/01-devbox-nodoc <<'EOF'
path-exclude /usr/share/doc/*
path-include /usr/share/doc/*/copyright
path-exclude /usr/share/man/*
path-exclude /usr/share/info/*
path-exclude /usr/share/locale/*
path-include /usr/share/locale/locale.alias
EOF

apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates curl git gnupg jq less locales ncurses-bin openssh-client openssl \
  pkg-config procps stow sudo unzip xz-utils zsh libssl-dev
rm -rf /var/lib/apt/lists/*

groupadd --gid "$DEVBOX_GID" "$DEVBOX_USER"
useradd --uid "$DEVBOX_UID" --gid "$DEVBOX_GID" --create-home --shell /bin/zsh "$DEVBOX_USER"
echo "$DEVBOX_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$DEVBOX_USER"
chmod 0440 "/etc/sudoers.d/90-$DEVBOX_USER"

install -d -o "$DEVBOX_USER" -g "$DEVBOX_GID" -m 755 /opt/devbox
