# Ask luarocks what paths Lua needs
$lrPaths = luarocks path --lua-version 5.1
# Emit as lines like: set LUA_PATH=... and set LUA_CPATH=...
$env:LUA_PATH  = ($lrPaths | Select-String '^set LUA_PATH=').Line -replace '^set LUA_PATH=',''
$env:LUA_CPATH = ($lrPaths | Select-String '^set LUA_CPATH=').Line -replace '^set LUA_CPATH=',''

lua linter.lua
