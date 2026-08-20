$ErrorActionPreference = "Stop"

# The addon's sources, two levels up from build/Release/. Resolved against this file rather
# than the working directory so the script can be run from anywhere; the zip it produces stays
# in the working directory, which is where Publish.ps1 looks for it.
$srcDir = Join-Path $PSScriptRoot "..\..\src"

# locate the toc file in src (@() so .Count works under a caller's strict mode)
$tocFiles = @(Get-ChildItem -Path $srcDir -Filter "*.toc" -File)

if ($tocFiles.Count -eq 0) {
    Write-Error "No .toc file found in src"
}

if ($tocFiles.Count -gt 1) {
    Write-Error "Multiple .toc files found in src; cannot determine addon name"
}

# addon folder name comes from toc filename
$addonFolderName = [System.IO.Path]::GetFileNameWithoutExtension($tocFiles[0].Name)

# remove any old remnants
Remove-Item -Recurse -Force $addonFolderName -ErrorAction SilentlyContinue

# create the host folder
New-Item -ItemType Directory $addonFolderName | Out-Null

# copy the addon files
Copy-Item (Join-Path $srcDir "*") $addonFolderName -Recurse -Force

# Extra addon folders shipped in the same zip, one per directory under compat/. Used for stubs
# that keep an old saved-variables file loading after an addon is renamed. Repos without a
# compat/ directory are unaffected.
$compatDir = Join-Path $PSScriptRoot "..\..\compat"
$zipFolders = @($addonFolderName)

if (Test-Path $compatDir) {
    # Release tooling only ever bumps the main toc, and a stub whose Interface lags gets
    # greyed out as out of date, which silently defeats the saved-variables bridge it exists
    # to be. Stamp the shipped copies with the main toc's Interface and Version so they can
    # never fall behind. ReadAllText/WriteAllText because PS 5.1 Get-Content decodes BOM-less
    # files as ANSI.
    # Resolve-Path because .NET resolves relative paths against the process working directory,
    # which PowerShell's Set-Location does not move.
    $mainToc = [System.IO.File]::ReadAllText((Resolve-Path (Join-Path $addonFolderName $tocFiles[0].Name)).Path)
    $interfaceLine = [regex]::Match($mainToc, "(?m)^## Interface:.*$").Value
    $versionLine = [regex]::Match($mainToc, "(?m)^## Version:.*$").Value

    foreach ($folder in @(Get-ChildItem -Path $compatDir -Directory)) {
        Remove-Item -Recurse -Force $folder.Name -ErrorAction SilentlyContinue
        Copy-Item $folder.FullName . -Recurse -Force
        $zipFolders += $folder.Name

        foreach ($stubToc in @(Get-ChildItem -Path $folder.Name -Filter "*.toc" -File)) {
            $text = [System.IO.File]::ReadAllText($stubToc.FullName)
            if ($interfaceLine) { $text = [regex]::Replace($text, "(?m)^## Interface:.*$", $interfaceLine) }
            if ($versionLine) { $text = [regex]::Replace($text, "(?m)^## Version:.*$", $versionLine) }
            [System.IO.File]::WriteAllText($stubToc.FullName, $text, (New-Object System.Text.UTF8Encoding($false)))
        }
    }
}

# extract the version number from the toc
$regex = Get-Content (Join-Path $addonFolderName $tocFiles[0].Name) |
    Select-String "(?<=Version:\s*).*"

if (-not $regex) {
    Write-Error "Failed to extract version number"
}

$version = $regex.Matches[0].Value.Trim()
$zipFileName = "$version.zip"

# remove the previous build zip file (if exists)
Remove-Item $zipFileName -ErrorAction SilentlyContinue

# Both Compress-Archive and ZipFile.CreateFromDirectory leave the Windows backslashes in the
# local file headers and only put forward slashes in the central directory. Windows unzippers
# read the central directory and look right, while macOS and Linux ones read the local headers
# and dump every file into a single folder with backslashes in its name. Naming each entry by
# hand is the only way to get forward slashes into both.
if (-not ("System.IO.Compression.ZipFile" -as [type])) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}

$zipPath = Join-Path (Get-Location).Path $zipFileName
$archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)

try {
    foreach ($folder in $zipFolders) {
        $root = (Resolve-Path -LiteralPath $folder).Path

        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse)) {
            $relative = $file.FullName.Substring($root.Length + 1).Replace("\", "/")
            $entryName = "$folder/$relative"

            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive,
                $file.FullName,
                $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
}
finally {
    $archive.Dispose()
}

# remove the temp folders
foreach ($folder in $zipFolders) {
    Remove-Item -Recurse -Force $folder
}
