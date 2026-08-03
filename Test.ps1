# Runs an addon's unit tests, if it has any.
#
# Most addons have no suite, so a missing one is reported and treated as success - that keeps the
# same workflow file usable in every repository rather than needing a per-addon variant.
#
# The runner is expected to set its own exit code: 0 when everything passed, non-zero otherwise.
# A suite that always exits 0 would make this step decorative, so the code is checked rather than
# the output.

$addonRoot = Join-Path $PSScriptRoot ".."

# Ask luarocks what paths Lua needs, in case a suite depends on a rock (FrameSort uses luaunit).
# Same both-shells parsing as Lint.ps1: "set X=..." on Windows, "export X='...'" on POSIX.
$lrPaths = luarocks path --lua-version 5.1 2>$null

function Get-LuaRocksPath([string] $name) {
    $match = $lrPaths | Select-String "^(?:set|export)\s+$name=(.*)$"

    if (-not $match) {
        return $null
    }

    return $match.Matches[0].Groups[1].Value.Trim().TrimEnd(';').Trim("'").Trim('"')
}

# Only assign when a value was parsed; an empty assignment wipes Lua's built-in search path.
$luaPath = Get-LuaRocksPath 'LUA_PATH'
$luaCPath = Get-LuaRocksPath 'LUA_CPATH'

if ($luaPath) { $env:LUA_PATH = $luaPath }
if ($luaCPath) { $env:LUA_CPATH = $luaCPath }

# Known entry points, most specific first. Each is run from the addon root so relative paths
# inside the suite resolve the same way they do locally.
$candidates = @(
    "tests/RunAll.lua",
    "tests/Test.lua",
    "test/RunAll.lua"
)

$runner = $null

foreach ($candidate in $candidates) {
    $full = Join-Path $addonRoot $candidate

    if (Test-Path $full) {
        $runner = $candidate
        break
    }
}

if (-not $runner) {
    Write-Host "[Tests] no suite found - skipping"
    exit 0
}

Push-Location $addonRoot

try {
    lua $runner
    $failed = $LASTEXITCODE -ne 0
}
finally {
    Pop-Location
}

if ($failed) {
    Write-Host "[Tests] FAILED"
    exit 1
}

Write-Host "[Tests] OK"
