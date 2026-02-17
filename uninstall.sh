#!/usr/bin/env bash
set -euo pipefail

BIN_NAME="${BIN_NAME:-melon}"
PREFIX="${PREFIX:-/usr/local}"
DEST="$PREFIX/bin/$BIN_NAME"
NO_SUDO="${NO_SUDO:-0}"
BASH_COMP="${PREFIX}/share/bash-completion/completions/melon"
ZSH_COMP="${PREFIX}/share/zsh/site-functions/_melon"
FISH_COMP="${PREFIX}/share/fish/vendor_completions.d/melon.fish"

remove_path() {
  local target="$1"
  if [[ ! -e "$target" ]]; then
    echo "Nothing to remove: $target does not exist."
    return 0
  fi

  echo "Removing $target"
  if rm -f "$target" 2>/dev/null; then
    echo "Removed: $target"
    return 0
  fi

  if [[ "$NO_SUDO" == "1" ]]; then
    echo "error: failed to remove $target (NO_SUDO=1)"
    exit 1
  fi

  echo "No write permission for $PREFIX, retrying with sudo..."
  sudo rm -f "$target"
  echo "Removed: $target"
}

remove_path "$DEST"
remove_path "$BASH_COMP"
remove_path "$ZSH_COMP"
remove_path "$FISH_COMP"
