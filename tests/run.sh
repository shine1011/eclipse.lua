#!/bin/sh
# Все офлайн-проверки одной командой: ./tests/run.sh  (из корня репозитория). Выход 0 = PASS.
set -e
cd "$(dirname "$0")/.."
luajit -bl eclipse.lua > /dev/null && echo "PASS  syntax (luajit -bl)"
luacheck . --no-color -q > /tmp/eclipse_luacheck.txt 2>&1 && echo "PASS  luacheck" || { cat /tmp/eclipse_luacheck.txt; echo "FAIL  luacheck"; exit 1; }
luajit tests/run.lua
