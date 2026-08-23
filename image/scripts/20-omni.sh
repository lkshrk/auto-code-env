#!/usr/bin/env bash
set -euo pipefail

export HOME=/opt/devbox
cd "$HOME"

echo "dotfiles ${DOTFILES_REF} @ ${DOTFILES_COMMIT}"
git clone --depth 1 --branch "$DOTFILES_REF" "$DOTFILES_REPO" "$HOME/dotfiles"

bash "$HOME/dotfiles/scripts/install-omni-latest.sh"
"$HOME/.local/bin/omni" --version
OMNI_HOSTNAME=devbox "$HOME/.local/bin/omni" --config "$HOME/dotfiles/dotfiles/omni/.config/omni/settings.json" settings show --format json >/dev/null
