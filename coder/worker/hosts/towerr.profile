# Non-secret host facts for the towerr desktop. No credentials belong here.

DISTRO_NAME=coder-worker
UBUNTU_DISTRIBUTION=Ubuntu-26.04

VAULT_URL=https://vlt.h-cloud.io
VAULT_EMAIL=coder@harke.me
VAULT_ITEM_CA=coder-worker docker ca
VAULT_ITEM_SERVER_CERT=coder-worker docker server cert
VAULT_ITEM_SERVER_KEY=coder-worker docker server key
VAULT_ITEM_LAN_CA=lan root ca
VAULT_ITEM_WORKSPACE_ENV=coder-worker workspace env

DOCKER_PORT=2376
FIREWALL_REMOTE_ADDRESSES=10.254.0.10,10.254.0.11,10.254.0.20,10.254.0.99
