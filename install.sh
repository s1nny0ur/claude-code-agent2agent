#!/bin/bash
# install.sh — Sets up claude-dev on this machine.
#
# 1. Ensures gum is installed (required for the launcher UI)
# 2. Adds a `claude-dev` shell function to your zsh profile
#
# Usage: bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$SCRIPT_DIR/launch.sh"

if [[ ! -f "$LAUNCHER" ]]; then
  echo "Error: launch.sh not found at $LAUNCHER" >&2
  exit 1
fi

# ── Ensure gum is available ───────────────────────────────────────────────────
if ! command -v gum &>/dev/null; then
  echo ""
  echo "gum is required for the launcher UI (https://github.com/charmbracelet/gum)"
  echo ""
  if command -v brew &>/dev/null; then
    read -rp "Install via Homebrew? [Y/n] " _yn
    if [[ "${_yn:-Y}" =~ ^[Yy] ]]; then
      brew install gum
    else
      echo "Skipping gum install. The launcher will not work without it." >&2
      exit 1
    fi
  elif command -v apt-get &>/dev/null; then
    read -rp "Install via apt? [Y/n] " _yn
    if [[ "${_yn:-Y}" =~ ^[Yy] ]]; then
      curl -fsSL https://repo.charm.sh/apt/gpg.key \
        | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
      echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
        | sudo tee /etc/apt/sources.list.d/charm.list
      sudo apt update && sudo apt install -y gum
    else
      echo "Skipping gum install. The launcher will not work without it." >&2
      exit 1
    fi
  else
    echo "Could not detect a supported package manager (brew/apt)." >&2
    echo "Install gum manually: https://github.com/charmbracelet/gum#installation" >&2
    exit 1
  fi
fi

echo "✓ gum $(gum --version 2>/dev/null | head -1)"

# ── Add claude-dev shell function ─────────────────────────────────────────────
if [[ -f "$HOME/.zshrc" ]]; then
  PROFILE="$HOME/.zshrc"
elif [[ -f "$HOME/.zprofile" ]]; then
  PROFILE="$HOME/.zprofile"
else
  PROFILE="$HOME/.zshrc"
fi

MARKER="# claude-dev launcher"

if grep -q "$MARKER" "$PROFILE" 2>/dev/null; then
  echo "claude-dev is already installed in $PROFILE"
  echo "To update the path, remove the block between the $MARKER comments and re-run."
  exit 0
fi

cat >> "$PROFILE" << SHELL

$MARKER
claude-dev() {
  bash "$LAUNCHER" "\$@"
}
# end claude-dev launcher
SHELL

echo "✓ claude-dev function added to $PROFILE"
echo ""
echo "Reload your shell:"
echo "  source $PROFILE"
echo ""
echo "Then run from any repo:"
echo "  claude-dev"
echo "  claude-dev --repo-a owner/fe --repo-b owner/be --features auth,payments"
echo "  claude-dev --end          # tear down the session when done"
