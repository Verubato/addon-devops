<#
publish.ps1

Zero-configuration CurseForge publisher.

Assumptions:
- Script lives in build/
- changelog.md lives in the parent directory
- Exactly one .toc exists in ../src/
- TOC contains:
    ## X-Curse-Project-ID: <id>
    ## Version: <version>
    ## Interface: <interface list>
- Zip file exists in current working directory and is named:
    <Version>.zip
- DisplayName is the version only

Auth:
- Read API (for game versions): uses CurseForge Core API
    - Header: x-api-key
    - Key from -ApiKey or CF_API_KEY env var
- Upload API (for uploading zip): uses CurseForge Upload API
    - Header: X-Api-Token
    - Token from CF_UPLOAD_TOKEN env var
#>

[CmdletBinding()]
param(
    # Optional; falls back to CF_API_KEY
    [string]$ApiKey,

    [ValidateSet("release","beta","alpha")]
    [string]$ReleaseType = "release"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------- Discovery ----------------

function Find-TocFile {
    $srcDir = Join-Path $PSScriptRoot "..\src" | Resolve-Path -ErrorAction Stop
    $srcDirPath = $srcDir.Path

    $tocs = @(Get-ChildItem -LiteralPath $srcDirPath -Filter *.toc -File -ErrorAction Stop)

    if ($tocs.Count -eq 0) {
        throw ("No .toc file found in {0}" -f $srcDirPath)
    }

    if ($tocs.Count -gt 1) {
        $names = $tocs | ForEach-Object Name | Sort-Object
        throw ("Multiple .toc files found in {0}: {1}" -f $srcDirPath, ($names -join ", "))
    }

    return $tocs[0].FullName
}

function Find-ZipForVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Version
    )

    $zipName = "{0}.zip" -f $Version
    $zipPath = Join-Path (Get-Location).Path $zipName

    if (!(Test-Path -LiteralPath $zipPath)) {
        throw ("Expected zip '{0}' not found in {1}" -f $zipName, (Get-Location).Path)
    }

    return (Resolve-Path -LiteralPath $zipPath -ErrorAction Stop).Path
}

function Get-Changelog {
    # Parent directory of the script (e.g. repo root)
    $parentDir = Resolve-Path (Join-Path $PSScriptRoot "..")

    $path = Join-Path $parentDir "changelog.md"

    if (Test-Path -LiteralPath $path) {
        Write-Host ("Using changelog: {0}" -f $path)
        return Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    }

    throw "No changelog.md found in parent directory"
}

# ---------------- TOC Parsing ----------------

function Get-TocLineValue {
    param(
        [Parameter(Mandatory)]
        [string]$TocPath,

        [Parameter(Mandatory)]
        [string]$Key
    )

    if (!(Test-Path -LiteralPath $TocPath)) {
        throw ("TOC not found: {0}" -f $TocPath)
    }

    $keyEsc = [regex]::Escape($Key)
    $regex = "^\s*##\s*{0}\s*:\s*(.+?)\s*$" -f $keyEsc

    $line = Get-Content -LiteralPath $TocPath -ErrorAction Stop |
        Where-Object { $_ -match $regex } |
        Select-Object -First 1

    if (-not $line) {
        throw ("Missing '## {0}:' in TOC ({1})" -f $Key, $TocPath)
    }

    $m = [regex]::Match($line, $regex)
    if (-not $m.Success) {
        throw ("Failed to parse '## {0}:' line in TOC ({1}): {2}" -f $Key, $TocPath, $line)
    }

    $value = $m.Groups[1].Value.Trim()
    if ($value -eq "") {
        throw ("Parsed empty value for '## {0}:' in TOC ({1})" -f $Key, $TocPath)
    }

    return $value
}

function Get-TocAddonVersion {
    param([Parameter(Mandatory)][string]$TocPath)
    return Get-TocLineValue -TocPath $TocPath -Key "Version"
}

function Get-TocCurseProjectId {
    param([Parameter(Mandatory)][string]$TocPath)

    $raw = Get-TocLineValue -TocPath $TocPath -Key "X-Curse-Project-ID"

    $m = [regex]::Match($raw, '^\d+$')
    if (-not $m.Success) {
        throw ("Invalid X-Curse-Project-ID '{0}' in TOC ({1})" -f $raw, $TocPath)
    }

    $id = [int]$raw
    if ($id -le 0) {
        throw ("Invalid X-Curse-Project-ID '{0}' (<=0) in TOC ({1})" -f $raw, $TocPath)
    }

    return $id
}

function Get-TocInterfaceNumbers {
    param([Parameter(Mandatory)][string]$TocPath)

    $rhs = Get-TocLineValue -TocPath $TocPath -Key "Interface"
    $nums = @([regex]::Matches($rhs, '\d+') | ForEach-Object { [int]$_.Value })

    if ($nums.Count -eq 0) {
        throw ("No Interface numbers parsed from TOC ({0}) value: {1}" -f $TocPath, $rhs)
    }

    # De-dupe while preserving order
    $seen = @{}
    $unique = New-Object System.Collections.Generic.List[int]
    foreach ($n in $nums) {
        if (-not $seen.ContainsKey($n)) {
            $seen[$n] = $true
            [void]$unique.Add($n)
        }
    }

    return $unique.ToArray()
}

# ---------------- CurseForge Helpers (Read API) ----------------

function Convert-InterfaceToWowVersion {
    param([Parameter(Mandatory)][int]$Interface)

    $major = [math]::Floor($Interface / 10000)
    $minor = [math]::Floor(($Interface % 10000) / 100)
    $patch = $Interface % 100
    return ("{0}.{1}.{2}" -f $major, $minor, $patch)
}

function Invoke-CfGet {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    return Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -ErrorAction Stop
}

function Get-CurseForgeWowGameId {
    param([Parameter(Mandatory)][hashtable]$Headers)

    $resp = Invoke-CfGet -Uri "https://api.curseforge.com/v1/games?searchFilter=World%20of%20Warcraft" -Headers $Headers

    $wow = $resp.data | Where-Object name -eq "World of Warcraft" | Select-Object -First 1
    if (-not $wow) {
        throw "World of Warcraft not found in CurseForge API"
    }

    return [int]$wow.id
}

function Get-CurseForgeGameVersionIdsFromToc {
    param(
        [Parameter(Mandatory)][string]$TocPath,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $interfaces = Get-TocInterfaceNumbers -TocPath $TocPath
    $wowVersions = $interfaces | ForEach-Object { Convert-InterfaceToWowVersion -Interface $_ }

    $gameId = Get-CurseForgeWowGameId -Headers $Headers

    # v2 returns objects with ids
    $uri = "https://api.curseforge.com/v2/games/{0}/versions" -f $gameId
    $resp = Invoke-CfGet -Uri $uri -Headers $Headers

    $groups = @($resp.data)
    if ($groups.Count -eq 0) {
        throw ("CurseForge returned no version groups for gameId {0}" -f $gameId)
    }

    # Flatten nested versions: resp.data[*].versions[*]
    $allVersions = @()
    foreach ($g in $groups) {
        if ($null -ne $g -and $g.PSObject.Properties.Name -contains "versions" -and $g.versions) {
            $allVersions += @($g.versions)
        }
    }

    if ($allVersions.Count -eq 0) {
        throw "CurseForge v2 versions response contained no nested versions."
    }

    if (-not ($allVersions[0].PSObject.Properties.Name -contains "name")) {
        $sampleProps = ($allVersions[0].PSObject.Properties.Name | Sort-Object) -join ", "
        throw ("Unexpected v2 versions schema; nested version sample properties: {0}" -f $sampleProps)
    }

    $matched = New-Object System.Collections.Generic.List[object]
    foreach ($v in $wowVersions) {
        $matches = @(
            $allVersions | Where-Object {
                $_.name -eq $v -or $_.name -like ("{0}*" -f $v)
            }
        )

        if ($matches.Count -eq 0) {
            Write-Warning ("No CurseForge game versions matched '{0}'." -f $v)
        } else {
            foreach ($m in $matches) { [void]$matched.Add($m) }
        }
    }

    $ids = @($matched | Select-Object -ExpandProperty id -Unique)

    Write-Host ("TOC Interface(s):       {0}" -f ($interfaces -join ", "))
    Write-Host ("Derived WoW Version(s): {0}" -f ($wowVersions -join ", "))
    if ($ids.Count -gt 0) {
        Write-Host ("Matched gameVersionIds: {0}" -f ($ids -join ", "))
    } else {
        Write-Host "Matched gameVersionIds: (none)"
        throw "No gameVersionIds matched from TOC"
    }

    return $ids
}

# ---------------- Upload (Upload API) ----------------

function Publish-CurseForgeZip {
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][int]$ProjectId,
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][int[]]$GameVersionIds,
        [Parameter(Mandatory)][string]$ReleaseType,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter()][string]$Changelog,
        [Parameter()][string]$ChangelogFormat
    )

    if (!(Test-Path -LiteralPath $ZipPath)) {
        throw ("Zip not found: {0}" -f $ZipPath)
    }

    $boundary = "----cf{0}" -f ([Guid]::NewGuid().ToString("N"))
    $fileName = [IO.Path]::GetFileName($ZipPath)

    # Upload API expects 'gameVersions' (IDs)
    $metadata = @{
        changelog     = $Changelog
        changelogType = $ChangelogFormat
        displayName   = $DisplayName
        releaseType   = $ReleaseType
        gameVersions  = $GameVersionIds
    } | ConvertTo-Json -Depth 6

    # IMPORTANT: UTF8 WITHOUT BOM (BOM before boundary can break multipart parsing)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $ms = New-Object IO.MemoryStream
    $writer = New-Object IO.StreamWriter($ms, $utf8NoBom)

    function Write-Part([string]$s) { $writer.Write($s) }

    # metadata part
    Write-Part("--$boundary`r`n")
    Write-Part("Content-Disposition: form-data; name=`"metadata`"`r`n")
    Write-Part("Content-Type: application/json; charset=utf-8`r`n`r`n")
    Write-Part($metadata)
    Write-Part("`r`n")

    # file part
    Write-Part("--$boundary`r`n")
    Write-Part(("Content-Disposition: form-data; name=`"file`"; filename=`"{0}`"`r`n" -f $fileName))
    Write-Part("Content-Type: application/zip`r`n`r`n")
    $writer.Flush()

    # write zip bytes
    $bytes = [IO.File]::ReadAllBytes($ZipPath)
    $ms.Write($bytes, 0, $bytes.Length) | Out-Null

    # closing boundary
    $writer = New-Object IO.StreamWriter($ms, $utf8NoBom)
    Write-Part("`r`n--$boundary--`r`n")
    $writer.Flush()

    # Build upload headers (clone + set content-type/length)
    $uploadHeaders = @{}
    foreach ($k in $Headers.Keys) { $uploadHeaders[$k] = $Headers[$k] }

    $contentType = "multipart/form-data; boundary=$boundary"
    $uploadHeaders["Content-Type"] = $contentType
    $uploadHeaders["Content-Length"] = $ms.Length

    $uri = "https://wow.curseforge.com/api/projects/{0}/upload-file" -f $ProjectId
    Write-Host ("Uploading '{0}' to CurseForge project {1} ..." -f $ZipPath, $ProjectId)

    # Send raw bytes (safe + predictable)
    $bodyBytes = $ms.ToArray()
    return Invoke-RestMethod -Method Post -Uri $uri -Headers $uploadHeaders -Body $bodyBytes -ErrorAction Stop
}

# ---------------- Main ----------------

# Resolve read API key (param → env var fallback)
$readApiKey = $ApiKey
if (-not $readApiKey -or $readApiKey.Trim() -eq "") {
    $readApiKey = $env:CF_API_KEY
}
if (-not $readApiKey -or $readApiKey.Trim() -eq "") {
    throw "CurseForge read API key not provided. Pass -ApiKey or set CF_API_KEY environment variable."
}

# Resolve upload token (env var only)
$uploadToken = $env:CF_UPLOAD_TOKEN
if (-not $uploadToken -or $uploadToken.Trim() -eq "") {
    throw "CurseForge upload token not provided. Set CF_UPLOAD_TOKEN environment variable."
}

$readHeaders = @{
    "x-api-key" = $readApiKey
    "Accept"    = "application/json"
}

$uploadHeaders = @{
    "X-Api-Token" = $uploadToken
    "Accept"      = "application/json"
}

$tocPath   = Find-TocFile
$version   = Get-TocAddonVersion -TocPath $tocPath
$projectId = Get-TocCurseProjectId -TocPath $tocPath
$zipPath   = Find-ZipForVersion -Version $version
$changelog = Get-Changelog
$changeLogFormat = "markdown"

Write-Host ("TOC:        {0}" -f $tocPath)
Write-Host ("Version:    {0}" -f $version)
Write-Host ("Project ID: {0}" -f $projectId)
Write-Host ("Zip:        {0}" -f $zipPath)

$gameVersionIds = Get-CurseForgeGameVersionIdsFromToc -TocPath $tocPath -Headers $readHeaders

$result = Publish-CurseForgeZip `
    -Headers $uploadHeaders `
    -ProjectId $projectId `
    -ZipPath $zipPath `
    -GameVersionIds $gameVersionIds `
    -ReleaseType $ReleaseType `
    -DisplayName $version `
    -Changelog $changelog `
    -ChangelogFormat $changelogFormat

Write-Host "Upload complete."

if ($null -eq $result) {
    Write-Host "No response payload returned."
}
elseif ($result.PSObject.Properties.Name -contains "id") {
    Write-Host ("File ID: {0}" -f $result.id)
}
else {
    try {
        $json = $result | ConvertTo-Json -Depth 6 -Compress
        Write-Host ("Response: {0}" -f $json)
    } catch {
        Write-Host "Response returned (unable to serialize to JSON)."
    }
}
