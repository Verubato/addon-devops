$ErrorActionPreference = "Stop"

$addonFolderName = Split-Path (Split-Path $PSScriptRoot -Parent) -Leaf

# remove any old remnants
Remove-Item -Recurse $addonFolderName -ErrorAction SilentlyContinue

# create the host folder
New-Item -ItemType Directory $addonFolderName | Out-Null

# copy the addon files
cp ..\src\* $addonFolderName -Recurse

# extract the version number
$regex = Get-Content "$($addonFolderName)\*.toc" | sls "(?<=Version: ).*" 
if (!$regex) { 
    Write-Error "Failed to extract version number"
}

$version = $regex.Matches[0].Value
$zipFileName = "$($version).zip"

# remove the previous build zip file (if exists)
Remove-Item $zipFileName -ErrorAction SilentlyContinue

# create the zip file
Compress-Archive -Path $addonFolderName -DestinationPath $zipFileName

# remove the temp folder
Remove-Item -Recurse $addonFolderName
