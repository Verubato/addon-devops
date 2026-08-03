# Ask luarocks what paths Lua needs. It prints shell-specific assignments: "set X=..." on
# Windows and "export X='...'" on POSIX, so both forms are accepted.
$lrPaths = luarocks path --lua-version 5.1

function Get-LuaRocksPath([string] $name) {
    $match = $lrPaths | Select-String "^(?:set|export)\s+$name=(.*)$"

    if (-not $match) {
        return $null
    }

    return $match.Matches[0].Groups[1].Value.Trim().TrimEnd(';').Trim("'").Trim('"')
}

# Only assign when a value was actually parsed. Assigning an empty string wipes Lua's built-in
# search path, which hid a correctly installed rock and reported it as "module 'lfs' not found".
$luaPath = Get-LuaRocksPath 'LUA_PATH'
$luaCPath = Get-LuaRocksPath 'LUA_CPATH'

if ($luaPath) { $env:LUA_PATH = $luaPath }
if ($luaCPath) { $env:LUA_CPATH = $luaCPath }

lua "$PSScriptRoot/Linter.lua"
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
