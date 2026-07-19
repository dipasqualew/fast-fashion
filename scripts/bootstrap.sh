#!/usr/bin/env bash
# Idempotent dev environment setup.
# WoW runs Lua 5.1, and homebrew-core no longer ships lua@5.1, so we build the
# rocks against luajit (5.1 semantics). Rocks installed under a 5.x interpreter
# will not behave like the game client.
set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1; }

if ! need brew; then
    echo "!! this script assumes Homebrew; install luajit + luarocks manually" >&2
    exit 1
fi

LUA_DIR="$(brew --prefix)/opt/luajit"
[ -d "$LUA_DIR" ] || { echo "==> installing luajit"; brew install luajit; }
need luarocks || { echo "==> installing luarocks"; brew install luarocks; }

for rock in busted luacheck; do
    if ! luarocks --lua-version 5.1 --lua-dir "$LUA_DIR" show "$rock" >/dev/null 2>&1; then
        echo "==> installing $rock (lua 5.1)"
        luarocks --lua-version 5.1 --lua-dir "$LUA_DIR" install --local "$rock"
    fi
done

echo "==> done. If busted/luacheck are not on PATH, add to your shell profile:"
echo '    eval "$(luarocks --lua-version 5.1 path --bin)"'
