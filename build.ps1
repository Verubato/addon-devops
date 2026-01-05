$ErrorActionPreference = "Stop"

# locate the toc file in src
$tocFiles = Get-ChildItem -Path "..\src" -Filter "*.toc" -File

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
Copy-Item "..\src\*" $addonFolderName -Recurse -Force

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

# create the zip file
Compress-Archive -Path $addonFolderName -DestinationPath $zipFileName

# remove the temp folder
Remove-Item -Recurse -Force $addonFolderName
