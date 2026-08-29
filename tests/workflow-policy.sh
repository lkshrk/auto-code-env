#!/usr/bin/env bash
set -euo pipefail

awk '/^  devbox-lint:/{inside=1} /^  devbox-image:/{inside=0} inside' .github/workflows/validate.yaml \
  | grep -A2 -Fx '      - uses: actions/checkout@v5' \
  | grep -Fx '          fetch-depth: 0' >/dev/null

echo ok
