# Docker Desktop + WSL2 deployment research

## Bottom line

Use Docker Desktop with its WSL2 backend and run the published image as a normal Linux container. Use named volumes for `/home/pilot` and `/workspace`, and a user-defined bridge network for a private container address. Do not use `172.16.20.0/24` for that bridge: it is the real VLAN 10 LAN and Docker Desktop does not put Windows containers directly on that VLAN.

The hard requirement “the dev container may start Docker workloads, but those workloads must not be able to reach Windows files” has two viable levels:

1. Best practical fit: Docker Business + Enhanced Container Isolation (ECI), with an image allowlist and Docker-socket command policy. ECI blocks socket mounts by default, and administrators can allow only the signed/pinned dev image and restrict Docker API commands.
2. Stronger separation: do not expose the Docker Desktop socket; use a separate Docker daemon (DinD or a remote Linux daemon). This costs complexity and is only needed if socket/API access must be completely independent of the host daemon.

Without ECI, mounting `/var/run/docker.sock` gives the container Docker-daemon control. A Compose file that omits Windows bind mounts is not a security policy: a process with daemon access can request a later container with a Windows bind mount. Docker’s own socket controls are therefore the relevant solution, not a wrapper around the CLI.

## Verified facts

- Docker Desktop’s WSL2 backend runs Docker in its own `docker-desktop` WSL distribution. WSL integration is explicitly enabled per distribution. Docker says the integration remains within WSL’s security model; WSL files are still accessible to Windows through `\\wsl$`. [Docker Desktop WSL 2 backend](https://docs.docker.com/desktop/features/wsl/)
- Containers do not automatically see Windows files. Docker documents that host files become available only when the directory is shared in Docker Desktop and explicitly bind-mounted. Use named volumes instead; Docker manages them and they are independent of the host directory layout. [Container security FAQ](https://docs.docker.com/security/faqs/containers/), [Volumes](https://docs.docker.com/engine/storage/volumes/)
- Named volumes persist across container replacement and can be inspected/exported in Docker Desktop. They are the right storage for the image’s home, caches, and repositories when Windows filesystem access is not wanted. [Docker Desktop volumes](https://docs.docker.com/desktop/use-desktop/volumes/)
- A user-defined bridge gives containers an interface and address in its configured IPv4 subnet, blocks access from unrelated Docker networks, and masquerades outbound traffic. The address is Docker-internal, not a physical LAN address. [Bridge network driver](https://docs.docker.com/engine/network/drivers/bridge/)
- Docker Desktop’s macvlan driver is not supported on Windows, Docker Desktop for Windows, or Docker Engine on Windows. Therefore a container cannot receive a real VLAN 10 address such as `172.16.20.130` using macvlan on this setup. [Macvlan driver](https://docs.docker.com/engine/network/drivers/macvlan/)
- ECI is a Docker Business feature. On WSL2 it requires WSL 2.6 or later. ECI uses a user namespace/Sysbox runtime and protects containers from breaching the Docker Desktop VM. [ECI](https://docs.docker.com/enterprise/security/hardened-desktop/enhanced-container-isolation), [Docker Desktop settings](https://docs.docker.com/desktop/settings-and-maintenance/settings/)
- ECI blocks Docker socket bind mounts by default. Docker Business administrators can allow specific image references (including digests) and restrict Docker commands with an allowlist or denylist. This is the documented way to support trusted tooling such as Testcontainers while retaining control. [ECI socket exceptions](https://docs.docker.com/enterprise/security/hardened-desktop/enhanced-container-isolation/config/), [ECI FAQ](https://docs.docker.com/enterprise/security/hardened-desktop/enhanced-container-isolation/faq/)
- ECI’s bind-mount protection is not a blanket “no Windows files” rule: Docker says host directory mounts configured in Docker Desktop remain allowed. The administrator must therefore share no Windows directories and use named volumes only. [ECI FAQ](https://docs.docker.com/enterprise/security/hardened-desktop/enhanced-container-isolation/faq/)
- WSL2 default networking is NAT. Mirrored mode shares the Windows IP/network stack and is the wrong choice when the goal is a distinct private container address. WSL’s own NAT address is not the Docker container’s address and does not make the container a VLAN peer. [WSL networking](https://learn.microsoft.com/en-us/windows/wsl/networking)

## Recommended deployment shape

```yaml
services:
  dev:
    image: ghcr.io/lkshrk/auto-code-env:dev-both-latest
    command: sleep infinity
    init: true
    tty: true
    stdin_open: true
    working_dir: /workspace
    volumes:
      - auto-code-home:/home/pilot
      - auto-code-workspace:/workspace
      - /var/run/docker.sock:/var/run/docker.sock # only with ECI policy, if Docker access is required
    networks:
      devnet:
        ipv4_address: 10.203.0.10

volumes:
  auto-code-home:
  auto-code-workspace:

networks:
  devnet:
    ipam:
      config:
        - subnet: 10.203.0.0/24
```

Choose an unused RFC1918 subnet; verify it does not overlap the LAN, VPN, WSL, or existing Docker networks. The `10.203.0.10` address is only for other containers and Docker’s internal bridge. Outbound access to VLAN 10 (`172.16.20.0/24`) is NATed through Docker Desktop/Windows; the container is not directly addressable from that VLAN.

For ECI, lock an administrator policy that:

- enables ECI;
- allows only the exact `ghcr.io/lkshrk/auto-code-env:...@sha256:...` image to mount the Docker socket (or a tightly controlled derived-image rule);
- permits only the Docker API command families actually needed (`container*`, perhaps `network*`, `volume*`), and denies `build`, `push`, `system*`, and any unnecessary image operations;
- shares no Windows directories in Docker Desktop settings.

Do not claim that ECI turns Docker daemon access into a perfect least-privilege API: Docker’s documented controls are image and command-family policies, not a per-container “may create containers but may never specify a host bind source” rule. If that exact guarantee is required, use a separate Linux daemon (DinD or remote) and do not mount Docker Desktop’s socket.

## Corrections to earlier advice

- A fixed `172.29.x.x`/`10.x.x.x` address is a Docker bridge address, not a VLAN address and not a separate physical adapter.
- `network_mode: host` is not appropriate for this isolation goal; it removes the private bridge namespace.
- Docker Desktop WSL2 does not require installing Docker Engine inside the application WSL distribution. Docker Desktop supplies the daemon; WSL integration supplies the CLI/context.
- WSL2 “own distro as imported rootfs” is unnecessary for this requirement and does not solve the Docker-socket authority problem.
- A real address in VLAN 10 requires a Linux Docker host with a supported macvlan/ipvlan setup (and network equipment configured accordingly), not Docker Desktop for Windows.

## Decision

Implement the ordinary Docker Desktop/WSL2 deployment with named volumes and a private user-defined bridge. If the user has Docker Business, add the ECI administrator policy and allow the image’s socket access under digest pinning. If Docker Business is unavailable and “Docker workloads cannot access Windows files” is a hard security boundary, use a separate Linux daemon instead of exposing Docker Desktop’s socket.
