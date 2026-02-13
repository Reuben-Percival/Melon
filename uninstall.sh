#!/usr/bin/env bash
set -euo pipefail

BIN_NAME="${BIN_NAME:-melon}"
PREFIX="${PREFIX:-/usr/local}"
DEST="$PREFIX/bin/$BIN_NAME"

if [[ ! -e "$DEST" ]]; then
  echo "Nothing to remove: $DEST does not exist."
  exit 0
fi

echo "Removing $DEST"
if rm -f "$DEST" 2>/dev/null; then
  echo "Removed: $DEST"
else
  echo "No write permission for $PREFIX, retrying with sudo..."
  sudo rm -f "$DEST"
  echo "Removed: $DEST"
fi
