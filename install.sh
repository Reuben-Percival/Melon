#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BIN_NAME="${BIN_NAME:-melon}"
PREFIX="${PREFIX:-/usr/local}"
DEST="$PREFIX/bin/$BIN_NAME"
SKIP_BUILD="${SKIP_BUILD:-0}"
NO_SUDO="${NO_SUDO:-0}"

if [[ "$SKIP_BUILD" != "1" ]]; then
  echo "Building $BIN_NAME (ReleaseSafe)..."
  if [[ -n "${ZIG_GLOBAL_CACHE_DIR:-}" ]]; then
    zig build -Doptimize=ReleaseSafe
  else
    ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build -Doptimize=ReleaseSafe
  fi
else
  echo "Skipping build (SKIP_BUILD=1)"
fi

SRC="zig-out/bin/$BIN_NAME"
if [[ ! -x "$SRC" ]]; then
  echo "error: expected built binary at $SRC"
  exit 1
fi

echo "Installing to $DEST"
if install -Dm755 "$SRC" "$DEST" 2>/dev/null; then
  echo "Installed: $DEST"
else
  if [[ "$NO_SUDO" == "1" ]]; then
    echo "error: failed to install to $DEST (NO_SUDO=1)"
    exit 1
  fi
  echo "No write permission for $PREFIX, retrying with sudo..."
  sudo install -Dm755 "$SRC" "$DEST"
  echo "Installed: $DEST"
fi
