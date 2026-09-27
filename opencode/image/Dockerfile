FROM ghcr.io/anomalyco/opencode:1.18.32@sha256:b3ce2a73474c57d19abb8c1e9d955c66066b4263e8f15167ba6e6c5ddf9a7ee0

# OpenCode resolves projects through the git binary; the upstream image has none.
RUN apk add --no-cache git

COPY plugins/coder-workspace.ts /opt/opencode/plugins/coder-workspace.ts
