# Builds the Windows release and its installer:
#     powershell -ExecutionPolicy Bypass -File packaging\windows\build-installer.ps1 [-SkipBuild]
# Needs Flutter, Visual Studio 2022 (Desktop development with C++) and Inno Setup 6
# (winget install JRSoftware.InnoSetup). Writes build\installer\AnyPS5-Desktop-Setup-<version>-x64.exe.
param([switch]$SkipBuild)
$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $root

$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9][^+\s]*)').Matches[0].Groups[1].Value
if (-not $SkipBuild) {
  flutter build windows --release
  if ($LASTEXITCODE) { throw "flutter build windows failed ($LASTEXITCODE)" }
}
$release = Join-Path $root "build\windows\x64\runner\Release"
if (-not (Test-Path (Join-Path $release "anyps5_desktop.exe"))) { throw "no release build in $release" }
if (-not (Test-Path (Join-Path $release "SDL2.dll"))) { throw "no SDL2.dll in ${release}: the package would ship without SDL2 controller support" }

$iscc = @(
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup 6 not found: winget install JRSoftware.InnoSetup" }

# A nightly's version (0.1.21-nightly.20261109.1): the file's version property takes numbers only.
$numbers = ($version -split '-')[0]
& $iscc /Q "/DAppVersion=$version" "/DFileVersion=$numbers" "/DSourceDir=$release" "/DOutputDir=$(Join-Path $root 'build\installer')" (Join-Path $PSScriptRoot "AnyPS5-Desktop.iss")
if ($LASTEXITCODE) { throw "ISCC failed ($LASTEXITCODE)" }
Get-Item (Join-Path $root "build\installer\AnyPS5-Desktop-Setup-$version-x64.exe")
