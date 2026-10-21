# publish-release.ps1 - publish a Windows release from a folder of built files,
# without GitHub Actions. Run it on a computer where `gh auth login` is done.
#
#   .\publish-release.ps1 -Version 1.16.2 -Target <full commit id> -Files <folder>
#
# <folder> holds TypeLeast-<v>-Windows-x64-Setup.exe, ...-Portable.zip and
# release-notes-windows.md (from package-wine.sh or package.ps1).
#
# The release is tagged windows-v<v> and, by default, marked "latest" so the
# release page shows it first. So that the latest release offers both systems,
# the current Mac files are copied in from -MacTag (-NoMac leaves them out). The Mac app's updater reads
# the latest tag; "windows-v…" never counts as a newer Mac version, so Mac users
# are not offered a Windows release. The Windows app finds its update by asset name.
param(
    [Parameter(Mandatory)] [string]$Version,
    [Parameter(Mandatory)] [string]$Target,
    [Parameter(Mandatory)] [string]$Files,
    [string]$MacTag = "v1.16.0",
    [string]$Repo = "FlaxXTT/Typeleast",
    [switch]$NotLatest,
    [switch]$NoMac
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

gh auth status | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Run gh auth login first" }

$tag = "windows-v$Version"
$setup = Join-Path $Files "TypeLeast-$Version-Windows-x64-Setup.exe"
$portable = Join-Path $Files "TypeLeast-$Version-Windows-x64-Portable.zip"
$notes = Join-Path $Files "release-notes-windows.md"
foreach ($f in $setup, $portable, $notes) { if (-not (Test-Path $f)) { throw "Missing $f" } }

# The current Mac files and their recorded checksums.
$work = Join-Path ([IO.Path]::GetTempPath()) ("typeleast-release-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory $work | Out-Null
try {
    $mac = @()
    if (-not $NoMac) {
        gh release download $MacTag --repo $Repo --dir $work --pattern "*-macOS-*" --pattern "SHA256SUMS.txt"
        if ($LASTEXITCODE -ne 0) { throw "Could not download the Mac files of $MacTag" }
        $mac = @(Get-ChildItem $work -File | Where-Object Name -like "*-macOS-*")
        if ($mac.Count -eq 0) { throw "$MacTag has no Mac files" }
    }

    # One checksum list for every file in the release: Windows computed here, Mac as recorded at its release.
    $sums = @()
    foreach ($f in $setup, $portable) { $sums += "{0}  {1}" -f (Get-FileHash $f -Algorithm SHA256).Hash.ToLowerInvariant(), (Split-Path $f -Leaf) }
    $recorded = if ($mac.Count -gt 0) { Get-Content (Join-Path $work "SHA256SUMS.txt") } else { @() }
    foreach ($m in $mac) {
        $line = $recorded | Where-Object { $_ -match "\s\*?$([regex]::Escape($m.Name))$" } | Select-Object -First 1
        if (-not $line) { throw "No recorded checksum for $($m.Name)" }
        $sums += $line
    }
    $sumsFile = Join-Path $work "SHA256SUMS.txt"
    Set-Content -Path $sumsFile -Value $sums -Encoding ascii

    $ghArgs = @("release", "create", $tag, $setup, $portable) + @($mac.FullName) + @($sumsFile,
        "--repo", $Repo, "--target", $Target, "--title", $(if ($NoMac) { "TypeLeast $Version (Windows)" } else { "TypeLeast $Version (Windows) · Mac $($MacTag.TrimStart('v'))" }),
        "--notes-file", $notes)
    $ghArgs += if ($NotLatest) { "--latest=false" } else { "--latest" }
    gh @ghArgs
    if ($LASTEXITCODE -ne 0) { throw "gh release create failed" }
    Write-Host "Published $tag"
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
