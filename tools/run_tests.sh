#!/usr/bin/env bash
# Run every offline test (needs a Lua 5.3+ interpreter). From the project root.
set -e
LUA="$(command -v lua5.4 || command -v lua5.3 || command -v lua)"
[ -n "$LUA" ] || { echo "no lua found"; exit 1; }
echo "== strudel-lua"
"$LUA" strudel-lua/test/test_reference.lua
"$LUA" strudel-lua/test/test_units.lua
echo "== plugin"
"$LUA" tools/build.lua
for t in test_core test_sync test_v02 test_ui_bundle; do "$LUA" tools/$t.lua; done
echo "ALL TESTS PASSED"
