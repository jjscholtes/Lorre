#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  CURRENT_DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
  if [[ -d "$XCODE_DEVELOPER_DIR" ]]; then
    if [[ -z "$CURRENT_DEV_DIR" || "$CURRENT_DEV_DIR" == /Library/Developer/CommandLineTools* ]]; then
      export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
      echo "Using Xcode toolchain for tests: $DEVELOPER_DIR" >&2
    fi
  fi
fi

export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$ROOT_DIR/.build/module-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"

cd "$ROOT_DIR"
exec swift test "$@"
