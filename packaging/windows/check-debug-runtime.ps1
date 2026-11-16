# Fails when a Windows bundle holds a program or library that needs the Visual C++ debug runtime
# (MSVCP140D.dll, VCRUNTIME140D.dll, ucrtbased.dll and the like). Only Visual Studio installs it,
# Microsoft does not allow it to be shipped, and Windows refuses to load what imports it on a PC
# without Visual Studio. Reads the import and delay-load tables of every .exe and .dll in the
# folder and below, and fails on a debug runtime file in the folder too:
#     powershell -ExecutionPolicy Bypass -File packaging\windows\check-debug-runtime.ps1 [-Path <folder>]
param([string]$Path = (Join-Path $PSScriptRoot "..\..\build\windows\x64\runner\Release"))
$ErrorActionPreference = "Stop"

$debugRuntime = '^(msvcp|vcruntime|msvcr|concrt|vcomp|vccorlib|vcamp)\d{2,3}(_\d)?d(_[a-z_]+)?\.dll$|^mfcm?\d{2,3}u?d\.dll$|^msvcrtd\.dll$|^ucrtbased\.dll$'

function Get-PeImports([byte[]]$bytes) {
  if ($bytes.Length -lt 64 -or [BitConverter]::ToUInt16($bytes, 0) -ne 0x5A4D) { throw "not a PE file" }
  $pe = [BitConverter]::ToInt32($bytes, 0x3C)
  if ([BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550) { throw "no PE signature" }
  $sectionCount = [BitConverter]::ToUInt16($bytes, $pe + 6)
  $optionalSize = [BitConverter]::ToUInt16($bytes, $pe + 20)
  $optional = $pe + 24
  switch ([BitConverter]::ToUInt16($bytes, $optional)) {
    0x10B { $directories = $optional + 96; $imageBase = [uint64][BitConverter]::ToUInt32($bytes, $optional + 28) }
    0x20B { $directories = $optional + 112; $imageBase = [BitConverter]::ToUInt64($bytes, $optional + 24) }
    default { throw "unknown optional header" }
  }
  $directoryCount = [BitConverter]::ToUInt32($bytes, $directories - 4)
  $headersSize = [BitConverter]::ToUInt32($bytes, $optional + 60)
  $sections = $optional + $optionalSize
  $toOffset = {
    param([uint32]$rva)
    $offset = -1
    if ($rva -lt $headersSize) { $offset = [int64]$rva }
    for ($i = 0; $offset -lt 0 -and $i -lt $sectionCount; $i++) {
      $s = $sections + 40 * $i
      $va = [BitConverter]::ToUInt32($bytes, $s + 12)
      $size = [Math]::Max([BitConverter]::ToUInt32($bytes, $s + 8), [BitConverter]::ToUInt32($bytes, $s + 16))
      if ($rva -ge $va -and $rva -lt $va + $size) { $offset = [int64]$rva - $va + [BitConverter]::ToUInt32($bytes, $s + 20) }
    }
    if ($offset -lt 0 -or $offset -ge $bytes.Length) { throw "RVA 0x{0:X} is outside the file" -f $rva }
    $offset
  }
  $readName = {
    param([uint32]$rva)
    $start = & $toOffset $rva
    $end = $start
    while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
    if ($end -ge $bytes.Length) { throw "an imported library name at RVA 0x{0:X} has no end" -f $rva }
    [Text.Encoding]::ASCII.GetString($bytes, $start, $end - $start)
  }
  $names = @()
  foreach ($table in @(@{ Index = 1; Size = 20; Name = 12; Delay = $false }, @{ Index = 13; Size = 32; Name = 4; Delay = $true })) {
    if ($table.Index -ge $directoryCount) { continue }
    $rva = [BitConverter]::ToUInt32($bytes, $directories + 8 * $table.Index)
    if ($rva -eq 0) { continue }
    $entry = & $toOffset $rva
    while ($true) {
      if ($entry + $table.Size -gt $bytes.Length) { throw "the import table at RVA 0x{0:X} has no end" -f $rva }
      $nameRva = [uint64][BitConverter]::ToUInt32($bytes, $entry + $table.Name)
      if ($nameRva -eq 0) { break }
      # Delay-load entries without the RVA attribute (bit 0), from old linkers, hold addresses.
      if ($table.Delay -and -not ([BitConverter]::ToUInt32($bytes, $entry) -band 1)) { $nameRva -= $imageBase }
      $names += & $readName ([uint32]$nameRva)
      $entry += $table.Size
    }
  }
  $names
}

$root = Resolve-Path $Path
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in ".exe", ".dll" })
if (-not $files) { throw "no .exe or .dll in $root" }
$bad = @()
foreach ($file in $files) {
  $relative = $file.FullName.Substring($root.Path.Length).TrimStart("\")
  if ($file.Name -match $debugRuntime) { $bad += "$relative is a debug runtime file" }
  foreach ($import in Get-PeImports ([IO.File]::ReadAllBytes($file.FullName))) {
    if ($import -match $debugRuntime) { $bad += "$relative imports $import" }
  }
}
if ($bad) {
  $bad | ForEach-Object { Write-Host $_ }
  throw "$($bad.Count) debug runtime use(s) in $root"
}
Write-Host "$($files.Count) programs and libraries in $root, none needs the debug runtime"
