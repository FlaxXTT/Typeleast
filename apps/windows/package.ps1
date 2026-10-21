# package.ps1 - build the Windows 11 release of TypeLeast (x64):
#   dist\TypeLeast-<version>-Windows-x64-Setup.exe     installer (no admin rights)
#   dist\TypeLeast-<version>-Windows-x64-Portable.zip  unzip and run TypeLeast.exe
#
# Everything the app runs is inside: TypeLeast.exe (self-contained .NET), the
# local service with sherpa-onnx for Windows, and an official Node.js checked
# against the SHA-256 list nodejs.org publishes. Only the speech model (about
# 241 MB) is downloaded by the app on first use.
#
# Needs: .NET 8 SDK, Node.js 22+ (for npm), Inno Setup 6 (iscc) for the installer.
param(
    [string]$NodeVersion = "24.21.0",
    [string]$OutDir = "$PSScriptRoot\dist"
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = Resolve-Path "$PSScriptRoot\..\.."
$version = ([xml](Get-Content "$PSScriptRoot\Directory.Build.props")).Project.PropertyGroup.Version
$stage = Join-Path $OutDir "stage"
$work = Join-Path $OutDir "work"
Remove-Item -Recurse -Force $stage, $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage, $work, $OutDir | Out-Null
Write-Host "== TypeLeast $version for Windows x64, Node.js $NodeVersion =="

# 1. The app: one self-contained TypeLeast.exe.
dotnet publish "$PSScriptRoot\TypeLeast\TypeLeast.csproj" -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=none -o $stage
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

# 2. The local service with its Windows dependencies (sherpa-onnx-win-x64).
$service = Join-Path $root "service"
Push-Location $service
npm ci --omit=dev --no-audit --no-fund
if ($LASTEXITCODE -ne 0) { throw "npm ci failed" }
Pop-Location
$svcOut = Join-Path $stage "service"
New-Item -ItemType Directory -Force $svcOut | Out-Null
Copy-Item -Recurse "$service\bin", "$service\lib", "$service\node_modules" $svcOut
Copy-Item "$service\package.json" $svcOut
# sherpa-onnx's DLLs use the Visual C++ runtime; ship it beside them so a fresh
# Windows without the redistributable still loads them (app-local deployment).
$sherpaDir = Join-Path $svcOut "node_modules\sherpa-onnx-win-x64"
foreach ($dll in "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll") {
    $sys = Join-Path $env:WINDIR "System32\$dll"
    if ((Test-Path $sys) -and -not (Test-Path (Join-Path $sherpaDir $dll))) { Copy-Item $sys $sherpaDir }
}

# 3. Node.js, verified against nodejs.org's SHA-256 list.
$zipName = "node-v$NodeVersion-win-x64.zip"
$base = "https://nodejs.org/dist/v$NodeVersion"
Invoke-WebRequest "$base/$zipName" -OutFile (Join-Path $work $zipName)
Invoke-WebRequest "$base/SHASUMS256.txt" -OutFile (Join-Path $work "SHASUMS256.txt")
$expected = (Get-Content (Join-Path $work "SHASUMS256.txt") | Where-Object { $_ -match " $([regex]::Escape($zipName))$" }).Split(" ")[0]
$actual = (Get-FileHash (Join-Path $work $zipName) -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expected -ne $actual) { throw "Node.js checksum mismatch: $actual != $expected" }
Expand-Archive (Join-Path $work $zipName) -DestinationPath $work
$nodeOut = Join-Path $stage "node"
New-Item -ItemType Directory -Force $nodeOut | Out-Null
Copy-Item (Join-Path $work "node-v$NodeVersion-win-x64\node.exe") $nodeOut
Copy-Item (Join-Path $work "node-v$NodeVersion-win-x64\LICENSE") $nodeOut
Write-Host "node   : $zipName (sha256 verified)"
Copy-Item (Join-Path $root "LICENSE"), (Join-Path $root "THIRD-PARTY-NOTICES.md") $stage

# 4. Smoke test: the bundled Node.js starts the bundled service and it answers.
$state = Join-Path $work "state"
$p = Start-Process -FilePath (Join-Path $nodeOut "node.exe") -ArgumentList @("`"$svcOut\bin\typeleast-service.mjs`"", "--state-dir", "`"$state`"", "--models-dir", "`"$work\models`"") `
    -RedirectStandardOutput (Join-Path $work "service.out") -RedirectStandardError (Join-Path $work "service.err") -PassThru -WindowStyle Hidden
$ready = $null
for ($i = 0; $i -lt 50 -and -not $ready; $i++) {
    Start-Sleep -Milliseconds 200
    $line = Get-Content (Join-Path $work "service.out") -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($line) { $ready = $line | ConvertFrom-Json }
}
if (-not $ready) { Stop-Process $p -Force; Get-Content (Join-Path $work "service.err"); throw "bundled service did not start" }
$token = (Get-Content (Join-Path $state "api-token")).Trim()
$health = Invoke-RestMethod "http://127.0.0.1:$($ready.port)/api/voice-polish/health" -Headers @{ Authorization = "Bearer $token" }
Stop-Process $p -Force
if ($health.service -ne "typeleast") { throw "unexpected health answer" }
Write-Host "smoke  : bundled service answered (speech phase: $($health.speech.phase))"

# 5. Portable zip and installer.
$name = "TypeLeast-$version-Windows-x64"
$zip = Join-Path $OutDir "$name-Portable.zip"
Remove-Item $zip -ErrorAction SilentlyContinue
Compress-Archive -Path "$stage\*" -DestinationPath $zip
$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup 6 (ISCC.exe) not found" }
& $iscc "/DAppVersion=$version" "/DSourceDir=$stage" "/DOutputDir=$OutDir" "$PSScriptRoot\installer\TypeLeast.iss"
if ($LASTEXITCODE -ne 0) { throw "iscc failed" }
Get-ChildItem $OutDir -File | ForEach-Object { "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name }
Write-Host "package.ps1: done -> $OutDir"
