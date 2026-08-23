#!/usr/bin/env bash
set -euo pipefail

export HOME=/opt/devbox
cd "$HOME"

echo "dotfiles ${DOTFILES_REF} @ ${DOTFILES_COMMIT}"
git clone --depth 1 --branch "$DOTFILES_REF" "$DOTFILES_REPO" "$HOME/dotfiles"

if [ "$DOTFILES_COMMIT" != unknown ]; then
  git -C "$HOME/dotfiles" fetch --quiet --depth 1 origin "$DOTFILES_COMMIT"
  git -C "$HOME/dotfiles" checkout --quiet FETCH_HEAD
fi
git -C "$HOME/dotfiles" rev-parse HEAD

bash "$HOME/dotfiles/scripts/install-omni-latest.sh"
"$HOME/.local/bin/omni" --version
OMNI_HOSTNAME=devbox "$HOME/.local/bin/omni" --config "$HOME/dotfiles/dotfiles/omni/.config/omni/settings.json" settings show --format json >/dev/null
