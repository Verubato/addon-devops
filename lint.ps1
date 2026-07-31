# Ask luarocks what paths Lua needs
$lrPaths = luarocks path --lua-version 5.1
# Emit as lines like: set LUA_PATH=... and set LUA_CPATH=...
$env:LUA_PATH  = ($lrPaths | Select-String '^set LUA_PATH=').Line -replace '^set LUA_PATH=',''
$env:LUA_CPATH = ($lrPaths | Select-String '^set LUA_CPATH=').Line -replace '^set LUA_CPATH=',''

lua linter.lua
$luacheckFailed = $LASTEXITCODE -ne 0

# Lua binds names inside a function body at compile time, so a local function referenced above
# its own declaration silently becomes a nil global read. Luacheck can't see it - every addon's
# .luacheckrc suppresses undefined globals, because addons legitimately read WoW globals - and it
# only errors on the code path that hits it, which the tests may never reach.
python "$PSScriptRoot/CheckForwardRefs.py"
$forwardRefsFailed = $LASTEXITCODE -ne 0

if ($luacheckFailed -or $forwardRefsFailed) {
    exit 1
}
