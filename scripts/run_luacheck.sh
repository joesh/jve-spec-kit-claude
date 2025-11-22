#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v luacheck >/dev/null 2>&1; then
  echo "luacheck not found in PATH; install via 'brew install luacheck' or your package manager." >&2
  exit 1
fi

luacheck src/lua tests
