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

# File layout, module-table naming and TOC load order. Load order is the one luacheck and the
# test suites both miss: a test harness loads files in its own order, so a file that reads
# addon.Core.X before the TOC loads X passes everything and only fails in game.
python "$PSScriptRoot/CheckConventions.py" (Join-Path $PSScriptRoot "..")
$conventionsFailed = $LASTEXITCODE -ne 0

if ($luacheckFailed -or $forwardRefsFailed -or $conventionsFailed) {
    exit 1
}
