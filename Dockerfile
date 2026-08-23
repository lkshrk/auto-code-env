# syntax=docker/dockerfile:1.7

ARG DEBIAN_IMAGE=debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258

FROM scratch AS runtime-files
COPY --chmod=0755 bin/auto-code-entrypoint bin/auto-code-health bin/auto-code-init bin/auto-code-sshd bin/docker bin/pnpm bin/pnpx bin/ssh-secret-run /usr/local/bin/

FROM ${DEBIAN_IMAGE} AS base

ARG DEBIAN_IMAGE
ARG TARGETARCH
ARG OMNI_VERSION=0.9.32
ARG OMNI_AMD64_SHA256=9d2369d5f73622834fb8cf7f15baf2ac5417274a9f49856cf380a8758ad8dbaf
ARG OMNI_ARM64_SHA256=64c9e1997b5b5a48a0067344bb154c61d90db0b560a6cddc978ba3d3f3c441cb
ARG DOCKER_VERSION=29.7.2
ARG DOCKER_AMD64_SHA256=803d433f226db4776e1768fd319fc6c6e4935a456acf84fcc0080818b854bc8f
ARG DOCKER_ARM64_SHA256=43d143448adf2c2787704e7d7704fd6d62d367a54c5edaef0a3f75509cb0938d
ARG BUILDX_VERSION=0.36.1
ARG BUILDX_AMD64_SHA256=48af8a397ebd60178778bf63611dbcebe5f5e7a9be90eb9147b24b9587455778
ARG BUILDX_ARM64_SHA256=5d0cafd9d16afe1a0f0d9529885344ace2cc99efdd531b6c783c5455a6001569
ARG COMPOSE_VERSION=2.39.2
ARG COMPOSE_AMD64_SHA256=a55a8cd4ef103aac282812554e531aac8df7e914a287ee81e14d695556a22902
ARG COMPOSE_ARM64_SHA256=54488fffb60782f3c8787a48b95ed15f49f5a3a85f4105304bd46db5edd9db61

ENV DEBIAN_FRONTEND=noninteractive HOME=/opt/auto-code-env USER=dev \
    PATH=/opt/auto-code-env/.local/bin:/opt/auto-code-env/.bun/bin:/opt/auto-code-env/.cargo/bin:/opt/auto-code-env/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

RUN case "$TARGETARCH" in \
      amd64) omni_arch=x86_64; omni_sha="$OMNI_AMD64_SHA256"; docker_arch=x86_64; docker_sha="$DOCKER_AMD64_SHA256"; buildx_arch=amd64; buildx_sha="$BUILDX_AMD64_SHA256"; compose_arch=x86_64; compose_sha="$COMPOSE_AMD64_SHA256" ;; \
      arm64) omni_arch=arm64; omni_sha="$OMNI_ARM64_SHA256"; docker_arch=aarch64; docker_sha="$DOCKER_ARM64_SHA256"; buildx_arch=arm64; buildx_sha="$BUILDX_ARM64_SHA256"; compose_arch=aarch64; compose_sha="$COMPOSE_ARM64_SHA256" ;; \
      *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; esac \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gh git jq libssl-dev make ncurses-bin openssh-client openssl pkg-config stow sudo tar unzip util-linux xz-utils zsh \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 1000 dev && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash dev \
 && install -d -o dev -g dev -m 0755 \
      /opt/auto-code-env \
      /opt/auto-code-env/.cache \
      /opt/auto-code-env/.npm \
      /opt/auto-code-env/.nvm \
      /opt/auto-code-env/.nvm/.cache \
      /opt/auto-code-env/.bun \
      /opt/auto-code-env/.bun/install \
      /opt/auto-code-env/.bun/install/cache \
      /opt/auto-code-env/go \
      /opt/auto-code-env/go/pkg \
      /opt/auto-code-env/go/pkg/mod \
 && install -d -m 0755 /usr/local/lib/docker/cli-plugins \
 && printf 'dev ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/dev && chmod 0440 /etc/sudoers.d/dev \
 && curl -fsSL "https://github.com/lkshrk/omni/releases/download/v${OMNI_VERSION}/omni_linux_${omni_arch}.tar.gz" -o /tmp/omni.tar.gz \
 && echo "$omni_sha  /tmp/omni.tar.gz" | sha256sum -c - && tar -xzf /tmp/omni.tar.gz -C /tmp && install -m 0755 /tmp/omni /usr/local/bin/omni \
 && curl -fsSL "https://download.docker.com/linux/static/stable/${docker_arch}/docker-${DOCKER_VERSION}.tgz" -o /tmp/docker.tgz \
 && echo "$docker_sha  /tmp/docker.tgz" | sha256sum -c - && tar -xzf /tmp/docker.tgz -C /tmp docker/docker && install -m 0755 /tmp/docker/docker /usr/local/bin/docker \
 && curl -fsSL "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}/buildx-v${BUILDX_VERSION}.linux-${buildx_arch}" -o /usr/local/lib/docker/cli-plugins/docker-buildx \
 && echo "$buildx_sha  /usr/local/lib/docker/cli-plugins/docker-buildx" | sha256sum -c - && chmod 0755 /usr/local/lib/docker/cli-plugins/docker-buildx \
 && curl -fsSL "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-linux-${compose_arch}" -o /usr/local/lib/docker/cli-plugins/docker-compose \
 && echo "$compose_sha  /usr/local/lib/docker/cli-plugins/docker-compose" | sha256sum -c - && chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose \
 && rm -rf /tmp/omni /tmp/omni.tar.gz /tmp/docker /tmp/docker.tgz \
 && install -d -m 0755 /usr/local/share/auto-code-env \
 && printf '%s\n' "TARGETARCH=${TARGETARCH}" "DEBIAN_IMAGE=${DEBIAN_IMAGE}" "OMNI_VERSION=${OMNI_VERSION}" "DOCKER_VERSION=${DOCKER_VERSION}" "BUILDX_VERSION=${BUILDX_VERSION}" "COMPOSE_VERSION=${COMPOSE_VERSION}" > /usr/local/share/auto-code-env/versions.env \
 && chown -R dev:dev /home/dev /opt/auto-code-env

FROM base AS dotfiles
ARG DOTFILES_REPO=https://github.com/lkshrk/dotfiles.git
ARG DOTFILES_REF=main
ARG DOTFILES_COMMIT=53b04d9df0682991c4d7e010b937a4fce29413fb
RUN git init /opt/dotfiles && cd /opt/dotfiles && git remote add origin "$DOTFILES_REPO" \
 && git fetch --depth=1 origin "$DOTFILES_COMMIT" \
 && git checkout --detach FETCH_HEAD && test "$(git rev-parse HEAD)" = "$DOTFILES_COMMIT" \
 && chown -R dev:dev /opt/dotfiles \
 && printf '%s\n' "DOTFILES_REPO=${DOTFILES_REPO}" "DOTFILES_REF=${DOTFILES_REF}" "DOTFILES_COMMIT=${DOTFILES_COMMIT}" > /opt/dotfiles-versions.env

FROM base AS omni-build-config
RUN --mount=type=bind,from=dotfiles,source=/opt/dotfiles/dotfiles/omni/.config/omni/settings.json,target=/mnt/settings.json,ro \
    --mount=type=bind,from=dotfiles,source=/opt/dotfiles/dotfiles/omni/.config/omni/settings.d/tools.json,target=/mnt/tools.json,ro \
    --mount=type=bind,from=dotfiles,source=/opt/dotfiles/dotfiles/omni/.config/omni/settings.d/groups.json,target=/mnt/groups.json,ro \
    install -d -o dev -g dev -m 0755 /opt/omni-build/settings.d \
 && tmp="$(mktemp)" \
 && jq '."$include" = ["settings.d/tools.json", "settings.d/groups.json"] | .host_settings = {image: .host_settings.coder} | .hosts = {image: ["prereqs", "core", "shell", "dev", "test-tooling", "go", "python", "ts", "dev-tooling", "infra", "secrets"]}' /mnt/settings.json > "$tmp" \
 && mv "$tmp" /opt/omni-build/settings.json \
 && tmp="$(mktemp)" \
 && jq '.groups = ([.groups[] | select(.name as $name | ["prereqs", "core", "shell", "dev", "test-tooling", "go", "python", "ts", "dev-tooling", "infra", "secrets"] | index($name))] + [{"name": "image", "special": "host"}])' /mnt/groups.json > "$tmp" \
 && mv "$tmp" /opt/omni-build/settings.d/groups.json \
 && tmp="$(mktemp)" \
 && jq '.tools.docker.ignore = true' /mnt/tools.json > "$tmp" \
 && mv "$tmp" /opt/omni-build/settings.d/tools.json \
 && chown -R dev:dev /opt/omni-build \
 && touch -d '@0' /opt/omni-build /opt/omni-build/settings.d /opt/omni-build/settings.json /opt/omni-build/settings.d/tools.json /opt/omni-build/settings.d/groups.json \
 && jq -e '."$include" == ["settings.d/tools.json", "settings.d/groups.json"] and (.hosts | keys == ["image"]) and (.host_settings | keys == ["image"]) and (.host_settings.image | type == "object")' /opt/omni-build/settings.json >/dev/null \
 && test "$(jq '.groups | length' /opt/omni-build/settings.d/groups.json)" = 12 \
 && for group in prereqs core shell dev test-tooling go python ts dev-tooling infra secrets image; do jq -e --arg group "$group" 'any(.groups[]; .name == $group)' /opt/omni-build/settings.d/groups.json >/dev/null; done \
 && jq -e '.tools.docker.ignore == true' /opt/omni-build/settings.d/tools.json >/dev/null \
 && test ! -e /opt/omni-build/settings.d/agents.json \
 && test ! -e /opt/omni-build/settings.d/dots.json

FROM omni-build-config AS persona
ARG PNPM_VERSION=11.22.0
ENV COREPACK_HOME=/opt/auto-code-env/.local/share/corepack \
    OMNI_CONFIG=/opt/omni-build/settings.json \
    OMNI_HOSTNAME=image
USER dev
WORKDIR /opt/auto-code-env
RUN --mount=type=cache,target=/opt/auto-code-env/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.npm,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.nvm/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.bun/install/cache,uid=1000,gid=1000 \
    --mount=type=secret,id=GITHUB_TOKEN,required=false,uid=1000 \
    if [ -f /run/secrets/GITHUB_TOKEN ]; then export GITHUB_TOKEN="$(cat /run/secrets/GITHUB_TOKEN)"; fi \
 && sudo apt-get update && omni tools install --group prereqs --force \
 && node_bin="$(find "$HOME/.nvm/versions/node" -mindepth 3 -maxdepth 3 -type f -name node -print -quit)" && test -n "$node_bin" && node_dir="$(dirname "$node_bin")" \
 && for tool in node npm npx corepack; do sudo ln -sf "$node_dir/$tool" "/usr/local/bin/$tool"; done \
 && node_root="$(dirname "$node_dir")" && for tool in pnpm pnpx; do sudo ln -sf "$node_root/lib/node_modules/corepack/shims/$tool" "/usr/local/bin/$tool"; done \
 && corepack install --global "pnpm@${PNPM_VERSION}" \
 && omni tools install --group core --force && omni tools install --group shell --force \
 && printf '\nif [ -f "$HOME/.config/omni/settings.json" ]; then export OMNI_CONFIG="$HOME/.config/omni/settings.json"; else export OMNI_CONFIG="/opt/dotfiles/dotfiles/omni/.config/omni/settings.json"; fi\n' | sudo tee -a /etc/zsh/zshrc >/dev/null \
 && printf '%s\n' "PNPM_VERSION=${PNPM_VERSION}" | sudo tee -a /usr/local/share/auto-code-env/versions.env >/dev/null \
 && sudo usermod --shell /usr/bin/zsh dev && sudo rm -rf /var/lib/apt/lists/*

FROM persona AS common-tools
RUN --mount=type=cache,target=/opt/auto-code-env/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.npm,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.nvm/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.bun/install/cache,uid=1000,gid=1000 \
    --mount=type=secret,id=GITHUB_TOKEN,required=false,uid=1000 \
    if [ -f /run/secrets/GITHUB_TOKEN ]; then export GITHUB_TOKEN="$(cat /run/secrets/GITHUB_TOKEN)"; fi \
 && sudo apt-get update && omni tools install --group dev --force && omni tools install --group test-tooling --force

FROM common-tools AS go-tools
RUN --mount=type=cache,target=/opt/auto-code-env/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.npm,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.nvm/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.bun/install/cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/go/pkg/mod,uid=1000,gid=1000 \
    --mount=type=secret,id=GITHUB_TOKEN,required=false,uid=1000 \
    if [ -f /run/secrets/GITHUB_TOKEN ]; then export GITHUB_TOKEN="$(cat /run/secrets/GITHUB_TOKEN)"; fi \
 && omni tools install --group go --force

FROM go-tools AS python-tools
RUN --mount=type=cache,target=/opt/auto-code-env/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.npm,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.nvm/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.bun/install/cache,uid=1000,gid=1000 \
    --mount=type=secret,id=GITHUB_TOKEN,required=false,uid=1000 \
    if [ -f /run/secrets/GITHUB_TOKEN ]; then export GITHUB_TOKEN="$(cat /run/secrets/GITHUB_TOKEN)"; fi \
 && omni tools install --group python --force

FROM python-tools AS language-tools
RUN --mount=type=cache,target=/opt/auto-code-env/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.npm,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.nvm/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.bun/install/cache,uid=1000,gid=1000 \
    --mount=type=secret,id=GITHUB_TOKEN,required=false,uid=1000 \
    if [ -f /run/secrets/GITHUB_TOKEN ]; then export GITHUB_TOKEN="$(cat /run/secrets/GITHUB_TOKEN)"; fi \
 && omni tools install --group ts --force

FROM language-tools AS dev-tools
RUN --mount=type=cache,target=/opt/auto-code-env/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.npm,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.nvm/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.bun/install/cache,uid=1000,gid=1000 \
    --mount=type=secret,id=GITHUB_TOKEN,required=false,uid=1000 \
    if [ -f /run/secrets/GITHUB_TOKEN ]; then export GITHUB_TOKEN="$(cat /run/secrets/GITHUB_TOKEN)"; fi \
 && omni tools install --group dev-tooling --force
RUN --mount=type=cache,target=/opt/auto-code-env/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.npm,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.nvm/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.bun/install/cache,uid=1000,gid=1000 \
    --mount=type=secret,id=GITHUB_TOKEN,required=false,uid=1000 \
    if [ -f /run/secrets/GITHUB_TOKEN ]; then export GITHUB_TOKEN="$(cat /run/secrets/GITHUB_TOKEN)"; fi \
 && omni tools install --group infra --force \
 && sudo rm -rf /var/lib/apt/lists/*

FROM dev-tools AS runtime-system
ENV HOME=/home/dev \
    XDG_RUNTIME_DIR=/run/user/1000 \
    SSH_AUTH_SOCK=/run/user/1000/rbw/ssh-agent-socket \
    PATH=/home/dev/.local/bin:/opt/auto-code-env/.local/bin:/opt/auto-code-env/.bun/bin:/opt/auto-code-env/.cargo/bin:/opt/auto-code-env/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
RUN sudo apt-get update \
 && sudo apt-get install -y --no-install-recommends openssh-server pinentry-curses \
 && sudo rm -f /etc/ssh/ssh_host_* \
 && sudo rm -rf /var/lib/apt/lists/* /opt/omni-build \
 && sudo install -D -m 0755 /usr/local/bin/docker /usr/local/libexec/docker

FROM runtime-system AS agent-tools
ARG CLAUDE_CODE_VERSION=2.1.239
RUN --mount=type=cache,target=/opt/auto-code-env/.npm,uid=1000,gid=1000 \
    npm install --global "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && sudo ln -sf "$(npm prefix --global)/bin/claude" /usr/local/bin/claude \
 && printf '%s\n' "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}" | sudo tee -a /usr/local/share/auto-code-env/versions.env >/dev/null
ARG CODEX_VERSION=0.149.0
ARG HERDR_VERSION=0.8.2
ARG HERDR_AMD64_SHA256=976150a14d490c94b243ea2e1a7eb2dfb67f12e36b182db90936f6728e6aecf4
ARG HERDR_ARM64_SHA256=f55610658e1c2e0d2aaef730b4b2ab885f7f8ba00285ab372bfb14f2e3d5b40d
RUN --mount=type=cache,target=/opt/auto-code-env/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.npm,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.nvm/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/opt/auto-code-env/.bun/install/cache,uid=1000,gid=1000 \
    --mount=type=secret,id=GITHUB_TOKEN,required=false,uid=1000 \
    if [ -f /run/secrets/GITHUB_TOKEN ]; then export GITHUB_TOKEN="$(cat /run/secrets/GITHUB_TOKEN)"; fi \
 && npm install --global "@openai/codex@${CODEX_VERSION}" \
 && sudo ln -sf "$(npm prefix --global)/bin/codex" /usr/local/bin/codex \
 && case "$TARGETARCH" in amd64) herdr_arch=x86_64; herdr_sha="$HERDR_AMD64_SHA256" ;; arm64) herdr_arch=aarch64; herdr_sha="$HERDR_ARM64_SHA256" ;; *) exit 1 ;; esac \
 && curl -fsSL "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-${herdr_arch}" -o /tmp/herdr \
 && echo "$herdr_sha  /tmp/herdr" | sha256sum -c - \
 && sudo install -m 0755 /tmp/herdr /usr/local/bin/herdr && rm /tmp/herdr \
 && printf '%s\n' "CODEX_VERSION=${CODEX_VERSION}" "HERDR_VERSION=${HERDR_VERSION}" | sudo tee -a /usr/local/share/auto-code-env/versions.env >/dev/null

FROM persona AS rbw-source
ENV HOME=/home/dev PATH=/home/dev/.cargo/bin:${PATH}
RUN sudo apt-get update \
 && sudo apt-get install -y --no-install-recommends build-essential \
 && sudo rm -rf /var/lib/apt/lists/* \
 && mkdir -p "$HOME/.cargo/bin" "$HOME/.rustup"
RUN --mount=type=cache,target=/opt/auto-code-env/.cache,uid=1000,gid=1000 \
    --mount=type=cache,target=/home/dev/.cargo/registry,uid=1000,gid=1000 \
    --mount=type=cache,target=/home/dev/.cargo/git,uid=1000,gid=1000 \
    omni tools install cargo --force --provider script \
 && CARGO_TARGET_DIR=/opt/auto-code-env/.cache/cargo-target omni tools install --group secrets --force \
 && test -x /home/dev/.cargo/bin/rbw \
 && test -x /home/dev/.cargo/bin/rbw-agent

FROM agent-tools AS runtime-core
COPY --from=rbw-source /home/dev/.cargo/bin/rbw /home/dev/.cargo/bin/rbw-agent /usr/local/bin/
RUN rbw_version="$(rbw --version | awk '{print $2}')" \
 && printf '%s\n' "RBW_VERSION=${rbw_version}" | sudo tee -a /usr/local/share/auto-code-env/versions.env >/dev/null \
 && sudo install -d -o dev -g dev -m 0700 /home/dev/workspace \
 && sudo chown -R dev:dev /home/dev
WORKDIR /home/dev
EXPOSE 22

FROM base AS lazygit-source
ARG TARGETARCH
ARG LAZYGIT_VERSION=0.64.1
ARG LAZYGIT_AMD64_SHA256=f8ea237c41f194cd799b48505518bfdaae4edf5a2ad6bd3d898e939785ee4532
ARG LAZYGIT_ARM64_SHA256=8b7ca3b344e60340ad1f89f29b9868ee39bcaba5bb92ee818bbe65476bb8b6e7
RUN case "$TARGETARCH" in amd64) lazygit_arch=x86_64; lazygit_sha="$LAZYGIT_AMD64_SHA256" ;; arm64) lazygit_arch=arm64; lazygit_sha="$LAZYGIT_ARM64_SHA256" ;; *) exit 1 ;; esac \
 && curl -fsSL "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_linux_${lazygit_arch}.tar.gz" -o /tmp/lazygit.tar.gz \
 && echo "$lazygit_sha  /tmp/lazygit.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/lazygit.tar.gz -C /tmp lazygit \
 && install -m 0755 /tmp/lazygit /usr/local/bin/lazygit && rm /tmp/lazygit /tmp/lazygit.tar.gz

FROM base AS pilot-source
ARG TARGETARCH
ARG PILOT_VERSION=2.264.0-fork.1
ARG PILOT_AMD64_SHA256=501709602b6620cef58b29d32fb38c988af782623615a25a554081b2984b3e69
ARG PILOT_ARM64_SHA256=de6e305f4a2aec4cc0652da524dcf4f440617e5a947dbfebc1539655f497adab
RUN case "$TARGETARCH" in amd64) pilot_arch=amd64; pilot_sha="$PILOT_AMD64_SHA256" ;; arm64) pilot_arch=arm64; pilot_sha="$PILOT_ARM64_SHA256" ;; *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; esac \
 && curl -fsSL "https://github.com/lkshrk/pilot/releases/download/v${PILOT_VERSION}/pilot-linux-${pilot_arch}.tar.gz" -o /tmp/pilot.tar.gz \
 && echo "$pilot_sha  /tmp/pilot.tar.gz" | sha256sum -c - && tar -xzf /tmp/pilot.tar.gz -C /usr/local/bin pilot && chmod 0755 /usr/local/bin/pilot && rm /tmp/pilot.tar.gz

FROM scratch AS pilot-files
COPY --from=pilot-source /usr/local/bin/pilot /usr/local/bin/pilot
COPY --from=lazygit-source /usr/local/bin/lazygit /usr/local/bin/lazygit
COPY --chmod=0755 pilot/bin/ /opt/pilot/bin/

FROM runtime-core AS pilot-runtime
ARG PILOT_VERSION=2.264.0-fork.1
ARG LAZYGIT_VERSION=0.64.1
ENV PATH=/opt/pilot/bin:${PATH} REAL_GH=/usr/bin/gh
COPY --link --from=pilot-files / /
RUN printf '%s\n' "PILOT_VERSION=${PILOT_VERSION}" "LAZYGIT_VERSION=${LAZYGIT_VERSION}" | sudo tee -a /usr/local/share/auto-code-env/versions.env >/dev/null

FROM runtime-core AS hermes-runtime
ARG HERMES_VERSION=0.18.2
ARG HERMES_REF=v2026.7.7.2
ARG HERMES_COMMIT=9de9c25f620ff7f1ce0fd5457d596052d5159596
ARG HERMES_INSTALLER_SHA256=a93c65b01ea392e179cf872e182bd01a2b65c0c15f17833e9f9569033ef10e07
RUN --mount=type=cache,target=/opt/auto-code-env/.cache,uid=1000,gid=1000 \
    curl -fsSL "https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_REF}/scripts/install.sh" -o /tmp/hermes-install.sh \
 && echo "$HERMES_INSTALLER_SHA256  /tmp/hermes-install.sh" | sha256sum -c - \
 && HOME=/opt/auto-code-env HERMES_HOME=/opt/auto-code-env/.hermes bash /tmp/hermes-install.sh \
      --branch "$HERMES_REF" --commit "$HERMES_COMMIT" --hermes-home /opt/auto-code-env/.hermes --skip-setup --non-interactive \
 && rm /tmp/hermes-install.sh \
 && test "$(git -C /opt/auto-code-env/.hermes/hermes-agent rev-parse HEAD)" = "$HERMES_COMMIT" \
 && test "$(hermes --version 2>/dev/null | grep -Eo 'v?[0-9]+(\.[0-9]+){2,3}' | head -1 | sed 's/^v//')" = "$HERMES_VERSION" \
 && printf '%s\n' "HERMES_VERSION=${HERMES_VERSION}" "HERMES_REF=${HERMES_REF}" "HERMES_COMMIT=${HERMES_COMMIT}" | sudo tee -a /usr/local/share/auto-code-env/versions.env >/dev/null
ENV HERMES_HOME=/home/dev/.hermes

FROM hermes-runtime AS both-runtime
ARG PILOT_VERSION=2.264.0-fork.1
ARG LAZYGIT_VERSION=0.64.1
ENV PATH=/opt/pilot/bin:${PATH} REAL_GH=/usr/bin/gh
COPY --link --from=pilot-files / /
RUN printf '%s\n' "PILOT_VERSION=${PILOT_VERSION}" "LAZYGIT_VERSION=${LAZYGIT_VERSION}" | sudo tee -a /usr/local/share/auto-code-env/versions.env >/dev/null

FROM scratch AS final-files
COPY --from=dotfiles --chown=1000:1000 /opt/dotfiles /opt/dotfiles
COPY --from=dotfiles /opt/dotfiles-versions.env /usr/local/share/auto-code-env/dotfiles.env
COPY --from=runtime-files /usr/local/bin/ /usr/local/bin/
COPY --chmod=0644 config/ssh_config /etc/ssh/ssh_config.d/99-auto-code-env.conf
COPY --chmod=0644 config/sshd_config /etc/ssh/sshd_config.d/99-auto-code-env.conf

FROM runtime-core AS dev-full
ENV OMNI_CONFIG=/opt/dotfiles/dotfiles/omni/.config/omni/settings.json OMNI_HOSTNAME=
USER root
COPY --link --from=final-files / /
RUN chmod 0755 /etc /etc/ssh /etc/ssh/ssh_config.d /etc/ssh/sshd_config.d \
 && cat /usr/local/share/auto-code-env/dotfiles.env >> /usr/local/share/auto-code-env/versions.env \
 && rm /usr/local/share/auto-code-env/dotfiles.env \
 && usermod --password '*' dev
USER dev
ENTRYPOINT ["/usr/local/bin/auto-code-entrypoint"]
CMD ["zsh"]

FROM pilot-runtime AS dev-pilot
ENV OMNI_CONFIG=/opt/dotfiles/dotfiles/omni/.config/omni/settings.json OMNI_HOSTNAME=
USER root
COPY --link --from=final-files / /
RUN chmod 0755 /etc /etc/ssh /etc/ssh/ssh_config.d /etc/ssh/sshd_config.d \
 && cat /usr/local/share/auto-code-env/dotfiles.env >> /usr/local/share/auto-code-env/versions.env \
 && rm /usr/local/share/auto-code-env/dotfiles.env \
 && usermod --password '*' dev
USER dev
ENTRYPOINT ["/usr/local/bin/auto-code-entrypoint"]
CMD ["zsh"]

FROM hermes-runtime AS dev-hermes
ENV OMNI_CONFIG=/opt/dotfiles/dotfiles/omni/.config/omni/settings.json OMNI_HOSTNAME=
USER root
COPY --link --from=final-files / /
RUN chmod 0755 /etc /etc/ssh /etc/ssh/ssh_config.d /etc/ssh/sshd_config.d \
 && cat /usr/local/share/auto-code-env/dotfiles.env >> /usr/local/share/auto-code-env/versions.env \
 && rm /usr/local/share/auto-code-env/dotfiles.env \
 && usermod --password '*' dev
USER dev
ENTRYPOINT ["/usr/local/bin/auto-code-entrypoint"]
CMD ["zsh"]

FROM both-runtime AS dev-both
ENV OMNI_CONFIG=/opt/dotfiles/dotfiles/omni/.config/omni/settings.json OMNI_HOSTNAME=
USER root
COPY --link --from=final-files / /
RUN chmod 0755 /etc /etc/ssh /etc/ssh/ssh_config.d /etc/ssh/sshd_config.d \
 && cat /usr/local/share/auto-code-env/dotfiles.env >> /usr/local/share/auto-code-env/versions.env \
 && rm /usr/local/share/auto-code-env/dotfiles.env \
 && usermod --password '*' dev
USER dev
ENTRYPOINT ["/usr/local/bin/auto-code-entrypoint"]
CMD ["zsh"]
