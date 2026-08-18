<#
Publish.ps1

Zero-configuration CurseForge + Wago + GitHub publisher.

Assumptions:
- Script lives in build/Release/
- changelog.md lives in the addon root, two levels up
    - The first "## <version>" heading is the latest release and must match the TOC version
- Exactly one .toc exists in ../../src/
- TOC contains:
    ## X-Curse-Project-ID: <id>
    ## X-Wago-ID: <id>            (only when publishing to Wago)
    ## Version: <version>
    ## Interface: <interface list>
- Zip file exists in current working directory and is named:
    <Version>.zip
- DisplayName is the version only
- Repo has a GitHub "origin" remote; the release tag is the version (e.g. 4.6.3)

Auth:
- Read API (for game versions): uses CurseForge Core API
    - Header: x-api-key
    - Key from -ApiKey or CF_API_KEY env var
- Upload API (for uploading zip): uses CurseForge Upload API
    - Header: X-Api-Token
    - Token from CF_UPLOAD_TOKEN env var
- Wago upload: token from WAGO_API_TOKEN env var
    - Header: Authorization: Bearer <token>
    - Key from https://addons.wago.io/account/apikeys
- GitHub release: token from GITHUB_TOKEN (or GH_TOKEN) env var
    - Needs "repo" scope (classic) or "Contents: read and write" (fine-grained)
#>

[CmdletBinding()]
param(
    # Optional; falls back to CF_API_KEY
    [string]$ApiKey,

    [ValidateSet("release","beta","alpha")]
    [string]$ReleaseType = "release",

    [switch]$SkipCurseForge,
    [switch]$SkipWago,
    [switch]$SkipGitHub,

    # Runs every check and lookup but sends nothing that creates a release.
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------- Discovery ----------------

function Find-TocFile {
    # Two levels up: this script sits in <addon>/build/Release/.
    $srcDir = Join-Path $PSScriptRoot "..\..\src" | Resolve-Path -ErrorAction Stop
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
    # The addon root, two levels up from build/Release/
    $parentDir = Resolve-Path (Join-Path $PSScriptRoot "..\..")

    $path = Join-Path $parentDir "changelog.md"

    if (Test-Path -LiteralPath $path) {
        Write-Host ("Using changelog: {0}" -f $path)
        # ReadAllText defaults to UTF-8; Get-Content -Raw would decode BOM-less files as ANSI
        return [IO.File]::ReadAllText($path)
    }

    throw "No changelog.md found in parent directory"
}

function Get-LatestChangelogSection {
    param(
        [Parameter(Mandatory)]
        [string]$Changelog
    )

    $lines = $Changelog -split "`r?`n"

    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^##\s+\S') { $start = $i; break }
    }

    if ($start -lt 0) {
        throw "No '## <version>' heading found in changelog.md"
    }

    $end = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^##\s+\S') { $end = $i; break }
    }

    $heading = ($lines[$start] -replace '^##\s+', '').Trim()

    $body = ""
    if ($start + 1 -le $end - 1) {
        $body = ($lines[($start + 1)..($end - 1)] -join "`n").Trim()
    }

    if ($body -eq "") {
        $body = $heading
    }

    return [pscustomobject]@{
        Heading = $heading
        Body    = $body
    }
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

function Get-TocWagoProjectId {
    param([Parameter(Mandatory)][string]$TocPath)

    $raw = Get-TocLineValue -TocPath $TocPath -Key "X-Wago-ID"

    if ($raw -notmatch '^[A-Za-z0-9]+$') {
        throw ("Invalid X-Wago-ID '{0}' in TOC ({1})" -f $raw, $TocPath)
    }

    return $raw
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

# ---------------- Multipart ----------------

function New-MultipartFormBody {
    param(
        [Parameter(Mandatory)][string]$Boundary,
        [Parameter(Mandatory)][string]$MetadataJson,
        [Parameter(Mandatory)][string]$ZipPath,

        # CurseForge wants the metadata part typed, Wago's parser matches curl's -F, which
        # sends a string field with no content type at all.
        [string]$MetadataContentType
    )

    if (!(Test-Path -LiteralPath $ZipPath)) {
        throw ("Zip not found: {0}" -f $ZipPath)
    }

    $fileName = [IO.Path]::GetFileName($ZipPath)

    # UTF8 WITHOUT BOM: a BOM before the boundary breaks multipart parsing
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $ms = New-Object IO.MemoryStream
    $writer = New-Object IO.StreamWriter($ms, $utf8NoBom)

    $writer.Write("--$Boundary`r`n")
    $writer.Write("Content-Disposition: form-data; name=`"metadata`"`r`n")
    if ($MetadataContentType) {
        $writer.Write("Content-Type: $MetadataContentType`r`n")
    }
    $writer.Write("`r`n")
    $writer.Write($MetadataJson)
    $writer.Write("`r`n")

    $writer.Write("--$Boundary`r`n")
    $writer.Write(("Content-Disposition: form-data; name=`"file`"; filename=`"{0}`"`r`n" -f $fileName))
    $writer.Write("Content-Type: application/zip`r`n`r`n")
    $writer.Flush()

    $bytes = [IO.File]::ReadAllBytes($ZipPath)
    $ms.Write($bytes, 0, $bytes.Length) | Out-Null

    $writer.Write("`r`n--$Boundary--`r`n")
    $writer.Flush()

    # The comma matters: a returned array is unrolled into Object[], and Invoke-RestMethod
    # sends anything that is not byte[] as text, which UTF-8 expands the zip and corrupts it.
    return , $ms.ToArray()
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

    $boundary = "----cf{0}" -f ([Guid]::NewGuid().ToString("N"))

    # Upload API expects 'gameVersions' (IDs)
    $metadata = @{
        changelog     = $Changelog
        changelogType = $ChangelogFormat
        displayName   = $DisplayName
        releaseType   = $ReleaseType
        gameVersions  = $GameVersionIds
    } | ConvertTo-Json -Depth 6

    $bodyBytes = New-MultipartFormBody -Boundary $boundary -MetadataJson $metadata -ZipPath $ZipPath `
        -MetadataContentType "application/json; charset=utf-8"

    # Build upload headers (clone + set content-type/length)
    $uploadHeaders = @{}
    foreach ($k in $Headers.Keys) { $uploadHeaders[$k] = $Headers[$k] }

    $uploadHeaders["Content-Type"] = "multipart/form-data; boundary=$boundary"
    $uploadHeaders["Content-Length"] = $bodyBytes.Length

    $uri = "https://wow.curseforge.com/api/projects/{0}/upload-file" -f $ProjectId
    Write-Host ("Uploading '{0}' to CurseForge project {1} ..." -f $ZipPath, $ProjectId)

    # Send raw bytes (safe + predictable)
    return Invoke-RestMethod -Method Post -Uri $uri -Headers $uploadHeaders -Body $bodyBytes -ErrorAction Stop
}

# ---------------- Wago ----------------

function Convert-InterfaceToWagoFlavor {
    param([Parameter(Mandatory)][int]$Interface)

    $major = [math]::Floor($Interface / 10000)
    $minor = [math]::Floor(($Interface % 10000) / 100)
    $patch = $Interface % 100

    # Wago lists 3.80.x under both wotlk and titan. Calling it titan leaves the wotlk field
    # free for the 3.4.x Wrath Classic client, so a TOC covering both keeps both.
    $flavor = switch ($major) {
        1 { "classic" }
        2 { "bc" }
        3 { if ($minor -ge 80) { "titan" } else { "wotlk" } }
        4 { "cata" }
        5 { "mop" }
        default { if ($major -ge 9) { "retail" } else { $null } }
    }

    if (-not $flavor) { return $null }

    return [pscustomobject]@{
        Flavor    = $flavor
        Patch     = ("{0}.{1}.{2}" -f $major, $minor, $patch)
        Interface = $Interface
    }
}

function Get-WagoPatchesFromToc {
    param([Parameter(Mandatory)][string]$TocPath)

    $interfaces = Get-TocInterfaceNumbers -TocPath $TocPath

    # Public endpoint, no auth. It is the only list of patches Wago will accept.
    $data = Invoke-RestMethod -Method Get -Uri "https://addons.wago.io/api/data/game" `
        -Headers @{ "Accept" = "application/json" } -ErrorAction Stop

    if (-not $data.patches) {
        throw "Wago game data returned no patches"
    }

    $byFlavor = @{}
    foreach ($i in $interfaces) {
        $mapped = Convert-InterfaceToWagoFlavor -Interface $i
        if (-not $mapped) {
            Write-Warning ("Interface {0} maps to no Wago flavor; skipping." -f $i)
            continue
        }

        if (-not $byFlavor.ContainsKey($mapped.Flavor)) {
            $byFlavor[$mapped.Flavor] = New-Object System.Collections.Generic.List[object]
        }

        [void]$byFlavor[$mapped.Flavor].Add($mapped)
    }

    # One patch per flavor, the newest of ours that Wago still lists.
    $patches = @{}
    foreach ($flavor in $byFlavor.Keys) {
        $known = @()
        if ($data.patches.PSObject.Properties.Name -contains $flavor) {
            $known = @($data.patches.$flavor)
        }

        $pick = @($byFlavor[$flavor] | Sort-Object -Property Interface -Descending |
            Where-Object { $known -contains $_.Patch }) | Select-Object -First 1

        if ($pick) {
            $patches[$flavor] = $pick.Patch
        } else {
            $ours = ($byFlavor[$flavor] | ForEach-Object { $_.Patch }) -join ", "
            Write-Warning ("Wago knows no '{0}' patch matching {1}; skipping that flavor." -f $flavor, $ours)
        }
    }

    if ($patches.Count -eq 0) {
        throw "No TOC Interface numbers matched a patch Wago accepts"
    }

    return $patches
}

function Publish-WagoZip {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][hashtable]$Patches,
        [Parameter(Mandatory)][string]$Stability,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Changelog,
        [switch]$DryRun
    )

    $metadata = [ordered]@{
        label     = $Label
        stability = $Stability
        changelog = $Changelog
    }

    foreach ($flavor in ($Patches.Keys | Sort-Object)) {
        $metadata["supported_{0}_patch" -f $flavor] = $Patches[$flavor]
    }

    $metadataJson = $metadata | ConvertTo-Json -Depth 6

    if ($DryRun) {
        Write-Host "Dry run, not uploading. Wago metadata would be:"
        Write-Host $metadataJson
        return $null
    }

    $boundary = "----wago{0}" -f ([Guid]::NewGuid().ToString("N"))
    $bodyBytes = New-MultipartFormBody -Boundary $boundary -MetadataJson $metadataJson -ZipPath $ZipPath

    # No Content-Length: the request sets it from the body, and supplying it here makes
    # Windows PowerShell 5.1 throw a protocol violation before anything is sent.
    $headers = @{
        "Authorization" = "Bearer $Token"
        "Accept"        = "application/json"
        "Content-Type"  = "multipart/form-data; boundary=$boundary"
    }

    $uri = "https://addons.wago.io/api/projects/{0}/version" -f $ProjectId
    Write-Host ("Uploading '{0}' to Wago project {1} ..." -f $ZipPath, $ProjectId)

    try {
        return Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $bodyBytes -ErrorAction Stop
    } catch {
        # Wago explains rejections in the response body, which the exception message drops.
        # PowerShell 7 puts it in ErrorDetails; 5.1 leaves it on the response stream.
        $detail = $null
        if ($_.PSObject.Properties.Name -contains "ErrorDetails" -and $_.ErrorDetails) {
            $detail = $_.ErrorDetails.Message
        }

        if (-not $detail -and $_.Exception.PSObject.Properties.Name -contains "Response" -and $_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object IO.StreamReader($stream)
                $detail = $reader.ReadToEnd()
                $reader.Dispose()
            } catch {
                $detail = $null
            }
        }

        if ($detail) {
            throw ("Wago upload failed: {0}" -f $detail)
        }

        throw
    }
}

# ---------------- GitHub Release ----------------

function Invoke-GitCommand {
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string[]]$GitArgs
    )

    # Native stderr output can be promoted to errors under EAP=Stop; relax it while capturing
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & git -C $RepoPath @GitArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }

    return [pscustomobject]@{
        ExitCode = $code
        Output   = (@($out) | ForEach-Object { "$_" }) -join "`n"
    }
}

function Get-GitHubRepoInfo {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

    $r = Invoke-GitCommand -RepoPath $repoRoot -GitArgs @("remote", "get-url", "origin")
    if ($r.ExitCode -ne 0) {
        throw ("Failed to read 'origin' remote in {0}: {1}" -f $repoRoot, $r.Output)
    }

    $url = $r.Output.Trim()

    # Matches git@github.com:owner/repo.git and https://github.com/owner/repo(.git)
    $m = [regex]::Match($url, '(?i)github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$')
    if (-not $m.Success) {
        throw ("Origin remote is not a GitHub URL: {0}" -f $url)
    }

    return [pscustomobject]@{
        Owner    = $m.Groups[1].Value
        Repo     = $m.Groups[2].Value
        RepoRoot = $repoRoot
    }
}

function Test-UnpushedCommits {
    param([Parameter(Mandatory)][string]$RepoPath)

    $r = Invoke-GitCommand -RepoPath $RepoPath -GitArgs @("rev-list", "--count", "@{u}..HEAD")
    if ($r.ExitCode -ne 0) {
        # No upstream configured; can't tell
        return $false
    }

    return ([int]$r.Output.Trim() -gt 0)
}

function Publish-GitHubRelease {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Notes,
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$AssetName
    )

    $headers = @{
        "Authorization"        = "Bearer $Token"
        "Accept"               = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    $releaseUri = "https://api.github.com/repos/{0}/{1}/releases" -f $Owner, $Repo

    # Skip if a release for this tag already exists (idempotent re-runs)
    $existing = $null
    try {
        $existing = Invoke-RestMethod -Method Get -Uri ("{0}/tags/{1}" -f $releaseUri, $Tag) -Headers $headers
    } catch {
        $existing = $null
    }

    if ($existing) {
        Write-Warning ("GitHub release '{0}' already exists: {1} - skipping." -f $Tag, $existing.html_url)
        return $existing
    }

    $bodyJson = @{
        tag_name   = $Tag
        name       = $Tag
        body       = $Notes
        draft      = $false
        prerelease = $false
    } | ConvertTo-Json

    Write-Host ("Creating GitHub release {0}/{1} '{2}' ..." -f $Owner, $Repo, $Tag)

    $release = Invoke-RestMethod -Method Post -Uri $releaseUri -Headers $headers `
        -Body ([Text.Encoding]::UTF8.GetBytes($bodyJson)) `
        -ContentType "application/json; charset=utf-8" -ErrorAction Stop

    $uploadUri = "https://uploads.github.com/repos/{0}/{1}/releases/{2}/assets?name={3}" -f `
        $Owner, $Repo, $release.id, [uri]::EscapeDataString($AssetName)

    Write-Host ("Uploading asset '{0}' ..." -f $AssetName)
    Invoke-RestMethod -Method Post -Uri $uploadUri -Headers $headers `
        -ContentType "application/zip" -InFile $ZipPath -ErrorAction Stop | Out-Null

    Write-Host ("GitHub release created: {0}" -f $release.html_url)
    return $release
}

# ---------------- Main ----------------

$tocPath   = Find-TocFile
$addonName = [IO.Path]::GetFileNameWithoutExtension($tocPath)
$version   = Get-TocAddonVersion -TocPath $tocPath
$zipPath   = Find-ZipForVersion -Version $version
$changelog = Get-Changelog
$changelogFormat = "markdown"

$latestSection = Get-LatestChangelogSection -Changelog $changelog
if ($latestSection.Heading -ne $version) {
    throw ("Latest changelog heading '{0}' does not match TOC version '{1}'. Add a changelog entry for this release." -f $latestSection.Heading, $version)
}

Write-Host ("TOC:        {0}" -f $tocPath)
Write-Host ("Addon:      {0}" -f $addonName)
Write-Host ("Version:    {0}" -f $version)
Write-Host ("Zip:        {0}" -f $zipPath)

# ---------------- CurseForge upload ----------------

if ($SkipCurseForge) {
    Write-Host "Skipping CurseForge upload."
}
else {
    # Resolve read API key (param -> env var fallback)
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

    $projectId = Get-TocCurseProjectId -TocPath $tocPath
    Write-Host ("Project ID: {0}" -f $projectId)

    $gameVersionIds = Get-CurseForgeGameVersionIdsFromToc -TocPath $tocPath -Headers $readHeaders

    $result = $null
    if ($DryRun) {
        Write-Host "Dry run, not uploading to CurseForge."
    }
    else {
        $result = Publish-CurseForgeZip `
            -Headers $uploadHeaders `
            -ProjectId $projectId `
            -ZipPath $zipPath `
            -GameVersionIds $gameVersionIds `
            -ReleaseType $ReleaseType `
            -DisplayName $version `
            -Changelog $changelog `
            -ChangelogFormat $changelogFormat

        Write-Host "CurseForge upload complete."
    }

    if ($null -eq $result) {
        if (-not $DryRun) {
            Write-Host "No response payload returned."
        }
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
}

# ---------------- Wago upload ----------------

if ($SkipWago) {
    Write-Host "Skipping Wago upload."
}
else {
    $wagoToken = $env:WAGO_API_TOKEN
    if (-not $wagoToken -or $wagoToken.Trim() -eq "") {
        throw "Wago API token not provided. Set WAGO_API_TOKEN environment variable, or pass -SkipWago."
    }

    $wagoProjectId = Get-TocWagoProjectId -TocPath $tocPath
    Write-Host ("Wago ID:    {0}" -f $wagoProjectId)

    $wagoPatches = Get-WagoPatchesFromToc -TocPath $tocPath
    $summary = ($wagoPatches.Keys | Sort-Object | ForEach-Object { "{0} {1}" -f $_, $wagoPatches[$_] }) -join ", "
    Write-Host ("Wago patches:           {0}" -f $summary)

    # -ReleaseType uses CurseForge's names; Wago calls a release stable.
    $stability = if ($ReleaseType -eq "release") { "stable" } else { $ReleaseType }

    $wagoResult = Publish-WagoZip `
        -Token $wagoToken `
        -ProjectId $wagoProjectId `
        -ZipPath $zipPath `
        -Patches $wagoPatches `
        -Stability $stability `
        -Label $version `
        -Changelog $latestSection.Body `
        -DryRun:$DryRun

    if ($null -ne $wagoResult) {
        Write-Host "Wago upload complete."

        try {
            Write-Host ("Response: {0}" -f ($wagoResult | ConvertTo-Json -Depth 6 -Compress))
        } catch {
            Write-Host "Response returned (unable to serialize to JSON)."
        }
    }
}

# ---------------- GitHub release ----------------

if ($SkipGitHub) {
    Write-Host "Skipping GitHub release."
}
else {
    $githubToken = $env:GITHUB_TOKEN
    if (-not $githubToken -or $githubToken.Trim() -eq "") {
        $githubToken = $env:GH_TOKEN
    }
    if (-not $githubToken -or $githubToken.Trim() -eq "") {
        throw "GitHub token not provided. Set GITHUB_TOKEN (or GH_TOKEN) environment variable, or pass -SkipGitHub."
    }

    $repoInfo = Get-GitHubRepoInfo

    if (Test-UnpushedCommits -RepoPath $repoInfo.RepoRoot) {
        Write-Warning "Local commits are not pushed; the release tag will point at the remote HEAD, not your local HEAD."
    }

    if ($DryRun) {
        Write-Host ("Dry run, not creating GitHub release '{0}'." -f $version)
    }
    else {
        Publish-GitHubRelease `
            -Token $githubToken `
            -Owner $repoInfo.Owner `
            -Repo $repoInfo.Repo `
            -Tag $version `
            -Notes $latestSection.Body `
            -ZipPath $zipPath `
            -AssetName ("{0}-{1}.zip" -f $addonName, $version) `
            | Out-Null
    }
}

Write-Host "Publish complete."
