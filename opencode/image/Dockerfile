FROM ghcr.io/anomalyco/opencode:2.0.18@sha256:aa0e5ac93543f24c99dfcc72a6ea7df335faec131dafc16f7607a2c7d3173d28

# OpenCode resolves projects through the git binary; the upstream image has none.
RUN apk add --no-cache git

COPY plugins/coder-workspace.ts /opt/opencode/plugins/coder-workspace.ts
