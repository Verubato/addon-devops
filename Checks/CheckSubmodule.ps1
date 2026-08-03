# Fails when an addon's pinned build submodule is behind the shared repository.
#
# Nothing otherwise notices the drift: each addon records its own gitlink, so updating
# addon-devops leaves every addon on whatever commit it was pinned to until someone bumps it by
# hand. The workflow makes that worse rather than better, because it checks the shared scripts
# out at their default branch rather than at the pinned commit - so a stale pin means CI is
# running scripts the addon has never recorded, and a path change in the shared repository
# breaks the addon without its own history showing anything.
#
# Skipped rather than failed when there is nothing to compare: not a submodule at all, tracked
# as plain files, or no checkout present.

# Two levels up: this script sits in <addon>/build/Checks/.
$addonRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")

# The commit the addon's index records for the build path.
$entry = git -C $addonRoot ls-files -s build 2>$null | Select-Object -First 1

if (-not $entry) {
    Write-Host "[Submodule] build is not a submodule here - skipping"
    exit 0
}

$fields = $entry -split '\s+'

# A gitlink is mode 160000; anything else means the scripts are committed as plain files.
if ($fields[0] -ne "160000") {
    Write-Host "[Submodule] build is tracked as plain files rather than a submodule"
    exit 0
}

$pinned = $fields[1]
$checkedOut = (git -C (Join-Path $addonRoot "build") rev-parse HEAD 2>$null)

if (-not $checkedOut) {
    Write-Host "[Submodule] no build checkout to compare against - skipping"
    exit 0
}

if ($pinned -eq $checkedOut) {
    Write-Host "[Submodule] up to date ($($pinned.Substring(0,7)))"
    exit 0
}

$message = "build is pinned to $($pinned.Substring(0,7)) but the shared repository is at $($checkedOut.Substring(0,7))"

# ::error:: surfaces as a red annotation on the run; plain text is enough locally.
if ($env:GITHUB_ACTIONS) {
    Write-Host "::error title=Build submodule is behind::$message"
}
else {
    Write-Host "[Submodule] $message"
}

exit 1
