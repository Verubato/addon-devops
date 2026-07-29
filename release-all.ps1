<#
release-all.ps1

Bumps every addon in the parent folder (D:\repos) to a new WoW patch and
publishes each one to CurseForge + GitHub.

For each repo that has build\publish.ps1:
  1. git pull --ff-only
  2. Update the build submodule to the latest addon-devops commit
     (falls back to copying the scripts if build is a plain folder)
  3. TOC: replace the old Interface number with the new one, or append the
     new number to the list when -OldGameVersion is omitted
  4. TOC: bump the addon version (patch by default)
  5. changelog.md: prepend a "## <version>" entry containing the message
     (publish.ps1 uses that entry as the GitHub release notes)
  6. git commit (only the files above) + push
  7. build\build.ps1  -> <version>.zip
  8. build\publish.ps1 -> CurseForge upload + GitHub release

Because the addons consume these scripts through the build submodule, this
repo (AddonDevOps) must be committed and pushed before a real run; the
script checks and refuses to start otherwise.

Repos whose TOC already has the new interface (and, in replace mode, not
the old one) skip steps 3-6 and go straight to build + publish, so the
script is safe to re-run after a partial failure. Note: a re-run of a repo that already
uploaded to CurseForge will upload a duplicate file there; use
publish.ps1 -SkipCurseForge manually for that case.

Usage:
  .\release-all.ps1 -OldGameVersion 12.0.7 -NewGameVersion 12.1 -DryRun
  .\release-all.ps1 -OldGameVersion 12.0.7 -NewGameVersion 12.1
  .\release-all.ps1 -NewGameVersion 12.1                # append 12.1, keep existing numbers
  .\release-all.ps1 -OldGameVersion 120007 -NewGameVersion 120100 -Message "12.1 support."
  .\release-all.ps1 -OldGameVersion 12.0.7 -NewGameVersion 12.1 -Include MiniCC, FrameSort

Required environment variables: CF_API_KEY, CF_UPLOAD_TOKEN, GITHUB_TOKEN (or GH_TOKEN)
#>

[CmdletBinding()]
param(
    # Game versions in dotted ("12.0.7") or interface ("120007") form.
    # With -OldGameVersion the old number is replaced by the new one;
    # without it the new number is appended to the existing Interface list.
    [string]$OldGameVersion,
    [Parameter(Mandatory)][string]$NewGameVersion,

    # Changelog entry + commit message; defaults to "<new game version> version support"
    [string]$Message,

    # Repo folder names to include/exclude; default is every repo with build\publish.ps1
    [string[]]$Include,
    [string[]]$Exclude,

    [ValidateSet("patch","minor")]
    [string]$VersionBump = "patch",

    [ValidateSet("release","beta","alpha")]
    [string]$ReleaseType = "release",

    # Show what would change without touching anything
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$reposRoot   = Split-Path $PSScriptRoot -Parent
$syncScripts = @("build.ps1", "deps.ps1", "install-luacheck.ps1", "lint.ps1", "publish.ps1")

# ---------------- Helpers ----------------

function ConvertTo-InterfaceNumber {
    param([Parameter(Mandatory)][string]$GameVersion)

    if ($GameVersion -match '^\d{5,6}$') {
        return $GameVersion
    }

    $m = [regex]::Match($GameVersion, '^(\d+)\.(\d+)(?:\.(\d+))?$')
    if (-not $m.Success) {
        throw ("Invalid game version '{0}'. Use dotted (12.1) or interface (120100) form." -f $GameVersion)
    }

    $major = [int]$m.Groups[1].Value
    $minor = [int]$m.Groups[2].Value
    $patch = 0
    if ($m.Groups[3].Success) { $patch = [int]$m.Groups[3].Value }

    return ("{0}{1:00}{2:00}" -f $major, $minor, $patch)
}

function ConvertTo-DottedGameVersion {
    param([Parameter(Mandatory)][string]$Interface)

    $n = [int]$Interface
    $major = [math]::Floor($n / 10000)
    $minor = [math]::Floor(($n % 10000) / 100)
    $patch = $n % 100

    if ($patch -eq 0) {
        return ("{0}.{1}" -f $major, $minor)
    }

    return ("{0}.{1}.{2}" -f $major, $minor, $patch)
}

function Invoke-Git {
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

    $text = (@($out) | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0) {
        throw ("git {0} failed: {1}" -f (($GitArgs -join " ")), $text)
    }

    return $text
}

# Get-Content -Raw decodes BOM-less files as ANSI on Windows PowerShell, which
# mangles the UTF-8 localized Notes lines in TOCs; ReadAllText defaults to UTF-8
function Read-TextFile {
    param([Parameter(Mandatory)][string]$Path)

    return [IO.File]::ReadAllText($Path)
}

function Write-TextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    # Preserve the file's existing BOM (or lack of one)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF

    $encoding = New-Object System.Text.UTF8Encoding($hasBom)
    [IO.File]::WriteAllText($Path, $Content, $encoding)
}

# Brings <repo>\build up to date with this repo's remote (submodule) or working
# copy (plain folder). Returns the paths to stage, or an empty array if current.
function Sync-BuildScripts {
    param([Parameter(Mandatory)][string]$RepoPath)

    $buildStage = Invoke-Git -RepoPath $RepoPath -GitArgs @("ls-files", "--stage", "--", "build")
    if ($buildStage -match '^160000') {
        # build is a submodule of addon-devops: advance it to the remote tip
        Invoke-Git -RepoPath $RepoPath -GitArgs @("submodule", "update", "--init", "--remote", "--", "build") | Out-Null
    }
    else {
        foreach ($script in $syncScripts) {
            $src = Join-Path $PSScriptRoot $script
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $RepoPath "build\$script") -Force
            }
        }
    }

    $dirty = Invoke-Git -RepoPath $RepoPath -GitArgs @("status", "--porcelain", "--", "build")
    if ($dirty.Trim() -eq "") {
        return @()
    }

    return @("build")
}

function Get-TocUpdatePlan {
    param(
        [Parameter(Mandatory)][string]$TocPath,

        # Empty = append mode: keep existing numbers and add the new one
        [string]$OldInterface = "",

        [Parameter(Mandatory)][string]$NewInterface,
        [Parameter(Mandatory)][string]$VersionBump
    )

    $raw = Read-TextFile -Path $TocPath

    $ifaceMatch = [regex]::Match($raw, '(?m)^##[ \t]*Interface:[ \t]*([^\r\n]+)')
    if (-not $ifaceMatch.Success) {
        throw ("No '## Interface:' line found in {0}" -f $TocPath)
    }

    $entries = @($ifaceMatch.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
    $hasOld = $OldInterface -ne "" -and $entries -contains $OldInterface
    $hasNew = $entries -contains $NewInterface

    $verMatch = [regex]::Match($raw, '(?m)^##[ \t]*Version:[ \t]*([^\r\n]+)')
    if (-not $verMatch.Success) {
        throw ("No '## Version:' line found in {0}" -f $TocPath)
    }

    $oldVersion = $verMatch.Groups[1].Value.Trim()

    # Already on the new patch (and old one removed, in replace mode) -> nothing to edit (resume case)
    if ($hasNew -and -not $hasOld) {
        return [pscustomobject]@{
            AlreadyUpdated = $true
            OldVersion     = $oldVersion
            NewVersion     = $oldVersion
            OldLine        = $ifaceMatch.Value
            NewLine        = $ifaceMatch.Value
            NewContent     = $raw
        }
    }

    if ($OldInterface -eq "") {
        # Append mode: keep everything, add the new number at the end
        $mapped = $entries + @($NewInterface)
    }
    else {
        # Replace mode: map old -> new; if old was absent, prepend new
        $mapped = @($entries | ForEach-Object { if ($_ -eq $OldInterface) { $NewInterface } else { $_ } })
        if (-not $hasOld) {
            $mapped = @($NewInterface) + $mapped
        }
    }

    $seen = @{}
    $deduped = @($mapped | Where-Object { -not $seen.ContainsKey($_) -and ($seen[$_] = $true) })

    # Largest (newest) interface first
    $sorted = @($deduped | Sort-Object { [int]$_ } -Descending)

    $newLine = "## Interface: " + ($sorted -join ", ")

    $vm = [regex]::Match($oldVersion, '^(\d+)\.(\d+)\.(\d+)$')
    if (-not $vm.Success) {
        throw ("Version '{0}' in {1} is not in X.Y.Z form" -f $oldVersion, $TocPath)
    }

    $vMajor = [int]$vm.Groups[1].Value
    $vMinor = [int]$vm.Groups[2].Value
    $vPatch = [int]$vm.Groups[3].Value

    if ($VersionBump -eq "minor") {
        $vMinor++
        $vPatch = 0
    } else {
        $vPatch++
    }

    $newVersion = "{0}.{1}.{2}" -f $vMajor, $vMinor, $vPatch

    $newContent = ([regex]([regex]::Escape($ifaceMatch.Value))).Replace($raw, $newLine, 1)
    $newContent = ([regex]([regex]::Escape($verMatch.Value))).Replace($newContent, "## Version: $newVersion", 1)

    return [pscustomobject]@{
        AlreadyUpdated = $false
        OldVersion     = $oldVersion
        NewVersion     = $newVersion
        OldLine        = $ifaceMatch.Value
        NewLine        = $newLine
        NewContent     = $newContent
    }
}

function Add-ChangelogEntry {
    param(
        [Parameter(Mandatory)][string]$ChangelogPath,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$EntryText
    )

    $raw = Read-TextFile -Path $ChangelogPath

    $nl = "`n"
    if ($raw -match "`r`n") { $nl = "`r`n" }

    # Entry already present -> nothing to do (resume case)
    if ($raw -match ('(?m)^##[ \t]*' + [regex]::Escape($Version) + '[ \t]*$')) {
        return
    }

    $entry = "## {0}{1}{1}{2}{1}{1}" -f $Version, $nl, $EntryText

    $firstHeading = [regex]::Match($raw, '(?m)^##[ \t]*\S')
    if ($firstHeading.Success) {
        $raw = $raw.Insert($firstHeading.Index, $entry)
    } else {
        if ($raw.Length -gt 0 -and -not $raw.EndsWith("`n")) { $raw += $nl }
        $raw += $nl + $entry
    }

    Write-TextFile -Path $ChangelogPath -Content $raw
}

# ---------------- Main ----------------

$newInterface = ConvertTo-InterfaceNumber -GameVersion $NewGameVersion

$oldInterface = ""
if ($OldGameVersion -and $OldGameVersion.Trim() -ne "") {
    $oldInterface = ConvertTo-InterfaceNumber -GameVersion $OldGameVersion

    if ($oldInterface -eq $newInterface) {
        throw "Old and new game versions are the same."
    }
}

if (-not $Message -or $Message.Trim() -eq "") {
    $Message = "{0} version support" -f (ConvertTo-DottedGameVersion -Interface $newInterface)
}

if (-not $DryRun) {
    $missing = @()
    if (-not $env:CF_API_KEY) { $missing += "CF_API_KEY" }
    if (-not $env:CF_UPLOAD_TOKEN) { $missing += "CF_UPLOAD_TOKEN" }
    if (-not $env:GITHUB_TOKEN -and -not $env:GH_TOKEN) { $missing += "GITHUB_TOKEN (or GH_TOKEN)" }
    if ($missing.Count -gt 0) {
        throw ("Missing required environment variables: {0}" -f ($missing -join ", "))
    }

    # The addons pull these scripts through their build submodule, which tracks
    # the REMOTE addon-devops repo - local-only changes here would be ignored
    $selfDirty = Invoke-Git -RepoPath $PSScriptRoot -GitArgs @("status", "--porcelain")
    if ($selfDirty.Trim() -ne "") {
        throw "AddonDevOps has uncommitted changes. Commit and push them first so the build submodules pick them up."
    }

    try {
        $selfAhead = [int](Invoke-Git -RepoPath $PSScriptRoot -GitArgs @("rev-list", "--count", "@{u}..HEAD")).Trim()
    } catch {
        $selfAhead = 0
    }
    if ($selfAhead -gt 0) {
        throw "AddonDevOps has unpushed commits. Push them first so the build submodules pick them up."
    }
}

$repos = @(
    Get-ChildItem -LiteralPath $reposRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "build\publish.ps1") }
)

if ($Include) {
    foreach ($name in $Include) {
        if (-not ($repos | Where-Object Name -eq $name)) {
            Write-Warning ("-Include '{0}' did not match any addon repo." -f $name)
        }
    }
    $repos = @($repos | Where-Object { $Include -contains $_.Name })
}

if ($Exclude) {
    $repos = @($repos | Where-Object { $Exclude -notcontains $_.Name })
}

if ($repos.Count -eq 0) {
    throw "No addon repos found to process."
}

if ($oldInterface -eq "") {
    Write-Host ("Interface: append {0}" -f $newInterface)
} else {
    Write-Host ("Interface: {0} -> {1}" -f $oldInterface, $newInterface)
}
Write-Host ("Message:   {0}" -f $Message)
Write-Host ("Repos:     {0}" -f $repos.Count)
if ($DryRun) { Write-Host "DRY RUN - no files will be changed." -ForegroundColor Cyan }

$results = New-Object System.Collections.Generic.List[object]

foreach ($repo in $repos) {
    Write-Host ""
    Write-Host ("=" * 70)
    Write-Host $repo.Name -ForegroundColor Cyan
    Write-Host ("=" * 70)

    $step = "discover"
    $versionInfo = ""

    try {
        # Repos without a GitHub origin can't be pushed or released; skip them
        $step = "remote"
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & git -C $repo.FullName remote get-url origin *> $null
        $hasOrigin = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $prev

        if (-not $hasOrigin) {
            Write-Warning "No 'origin' remote - skipping."
            $results.Add([pscustomobject]@{ Repo = $repo.Name; Version = ""; Status = "Skipped"; Detail = "no origin remote" })
            continue
        }

        $step = "toc"
        $tocs = @(Get-ChildItem -LiteralPath (Join-Path $repo.FullName "src") -Filter *.toc -File)
        if ($tocs.Count -ne 1) {
            throw ("Expected exactly one .toc in src, found {0}" -f $tocs.Count)
        }
        $tocFile = $tocs[0]

        $plan = Get-TocUpdatePlan -TocPath $tocFile.FullName -OldInterface $oldInterface -NewInterface $newInterface -VersionBump $VersionBump
        $versionInfo = "{0} -> {1}" -f $plan.OldVersion, $plan.NewVersion

        if ($DryRun) {
            if ($plan.AlreadyUpdated) {
                Write-Host ("Already updated (version {0}); would build + publish only." -f $plan.OldVersion)
            } else {
                Write-Host ("  {0}" -f $plan.OldLine)
                Write-Host ("> {0}" -f $plan.NewLine)
                Write-Host ("Version:   {0}" -f $versionInfo)
                Write-Host ("Changelog: + ## {0} - {1}" -f $plan.NewVersion, $Message)
            }
            $results.Add([pscustomobject]@{ Repo = $repo.Name; Version = $versionInfo; Status = "DryRun"; Detail = "" })
            continue
        }

        $step = "pull"
        Invoke-Git -RepoPath $repo.FullName -GitArgs @("pull", "--ff-only") | Out-Null

        # Re-read after pull in case the TOC changed
        $step = "toc"
        $plan = Get-TocUpdatePlan -TocPath $tocFile.FullName -OldInterface $oldInterface -NewInterface $newInterface -VersionBump $VersionBump
        $versionInfo = "{0} -> {1}" -f $plan.OldVersion, $plan.NewVersion

        $step = "sync build scripts"
        $scriptPaths = @(Sync-BuildScripts -RepoPath $repo.FullName)

        if ($plan.AlreadyUpdated) {
            Write-Host ("Already updated (version {0}); building + publishing only." -f $plan.OldVersion)
            $versionInfo = $plan.OldVersion

            if ($scriptPaths.Count -gt 0) {
                $step = "commit"
                Invoke-Git -RepoPath $repo.FullName -GitArgs (@("add", "--") + $scriptPaths) | Out-Null
                Invoke-Git -RepoPath $repo.FullName -GitArgs @("commit", "-m", "Updated build scripts.") | Out-Null

                $step = "push"
                Invoke-Git -RepoPath $repo.FullName -GitArgs @("push") | Out-Null
            }
        }
        else {
            $tocRel       = "src/{0}" -f $tocFile.Name
            $changelogRel = "changelog.md"

            $dirty = Invoke-Git -RepoPath $repo.FullName -GitArgs @("status", "--porcelain", "--", $tocRel, $changelogRel)
            if ($dirty.Trim() -ne "") {
                Write-Warning ("Pre-existing uncommitted changes will be included in the release commit:`n{0}" -f $dirty)
            }

            $step = "update files"
            Write-Host ("Interface: {0} -> {1}" -f $plan.OldLine, $plan.NewLine)
            Write-Host ("Version:   {0}" -f $versionInfo)
            Write-TextFile -Path $tocFile.FullName -Content $plan.NewContent

            Add-ChangelogEntry -ChangelogPath (Join-Path $repo.FullName "changelog.md") -Version $plan.NewVersion -EntryText $Message

            $step = "commit"
            $addPaths = @($tocRel, $changelogRel) + $scriptPaths
            Invoke-Git -RepoPath $repo.FullName -GitArgs (@("add", "--") + $addPaths) | Out-Null
            Invoke-Git -RepoPath $repo.FullName -GitArgs @("commit", "-m", $Message) | Out-Null

            $step = "push"
            Invoke-Git -RepoPath $repo.FullName -GitArgs @("push") | Out-Null
        }

        Push-Location (Join-Path $repo.FullName "build")
        try {
            # Strict mode propagates to child scripts, which aren't written for it
            Set-StrictMode -Off

            $step = "build"
            & .\build.ps1

            $step = "publish"
            & .\publish.ps1 -ReleaseType $ReleaseType
        }
        finally {
            Set-StrictMode -Version Latest
            Pop-Location
        }

        $results.Add([pscustomobject]@{ Repo = $repo.Name; Version = $versionInfo; Status = "OK"; Detail = "" })
    }
    catch {
        $msg = $_.Exception.Message
        Write-Host ("FAILED at {0}: {1}" -f $step, $msg) -ForegroundColor Red
        $results.Add([pscustomobject]@{ Repo = $repo.Name; Version = $versionInfo; Status = "FAILED"; Detail = ("{0}: {1}" -f $step, $msg) })
    }
}

# ---------------- Summary ----------------

Write-Host ""
Write-Host ("=" * 70)
Write-Host "Summary"
Write-Host ("=" * 70)

foreach ($r in $results) {
    $color = switch ($r.Status) {
        "OK"      { "Green" }
        "DryRun"  { "Cyan" }
        "Skipped" { "Yellow" }
        default   { "Red" }
    }

    $line = "{0,-25} {1,-20} {2}" -f $r.Repo, $r.Version, $r.Status
    if ($r.Detail) { $line += " - " + $r.Detail }
    Write-Host $line -ForegroundColor $color
}

$failed = @($results | Where-Object Status -eq "FAILED")
Write-Host ""
Write-Host ("{0} OK, {1} failed, {2} total" -f @($results | Where-Object Status -in "OK","DryRun").Count, $failed.Count, $results.Count)

if ($failed.Count -gt 0) {
    exit 1
}
