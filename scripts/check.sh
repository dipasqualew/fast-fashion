#!/usr/bin/env bash
# Lint + test. The single command CI and humans both run.
set -euo pipefail
cd "$(dirname "$0")/.."

eval "$(luarocks --lua-version 5.1 path --bin 2>/dev/null || true)"

echo "==> luacheck"
luacheck src Main.lua spec

echo "==> busted"
busted --verbose
