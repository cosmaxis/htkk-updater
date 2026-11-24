#Requires -Version 5.1
<#
.SYNOPSIS
  Injects icon + application manifest resources into a compiled httk-launcher.exe
  using Win32 BeginUpdateResource/UpdateResource — no resource compiler needed.
  Equivalent to what `embed-resource`/windres would link from httk-launcher.rc.
#>
param(
  [Parameter(Mandatory = $true)][string]$ExePath,
  [string]$IcoPath = "$PSScriptRoot\assets\httk.ico",
  [string]$ManifestPath = "$PSScriptRoot\app.manifest",
  [string]$Version = '1.1.5.0'
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ExePath)) { throw "exe not found: $ExePath" }
if (-not (Test-Path $IcoPath)) { throw "ico not found: $IcoPath" }
if (-not (Test-Path $ManifestPath)) { throw "manifest not found: $ManifestPath" }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ResUpdate {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern IntPtr BeginUpdateResourceW(string pFileName, bool bDeleteExistingResources);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool UpdateResourceW(IntPtr hUpdate, IntPtr lpType, IntPtr lpName, ushort wLanguage, byte[] lpData, uint cbData);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool EndUpdateResourceW(IntPtr hUpdate, bool fDiscard);
}
'@

# --- Parse ICO -------------------------------------------------------
$icoBytes = [System.IO.File]::ReadAllBytes($IcoPath)
$ms = New-Object System.IO.MemoryStream(,$icoBytes)
$br = New-Object System.IO.BinaryReader($ms)
if ($br.ReadUInt16() -ne 0 -or $br.ReadUInt16() -ne 1) { throw "not a valid ICO" }
$count = $br.ReadUInt16()
Write-Host "ICO frames: $count"
$frames = @()
for ($i = 0; $i -lt $count; $i++) {
  $entry = @{
    w = $br.ReadByte(); h = $br.ReadByte(); cc = $br.ReadByte(); res = $br.ReadByte()
    planes = $br.ReadUInt16(); bitcount = $br.ReadUInt16()
    size = $br.ReadUInt32(); offset = $br.ReadUInt32()
  }
  $entry.data = $icoBytes[$entry.offset..($entry.offset + $entry.size - 1)]
  $frames += $entry
}

# --- Inject resources ------------------------------------------------
$h = [ResUpdate]::BeginUpdateResourceW((Resolve-Path $ExePath).Path, $false)
if ($h -eq [IntPtr]::Zero) { throw "BeginUpdateResource failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
try {
  $lang = 1033
  # RT_ICON (3): one resource per frame, IDs 1..N
  for ($i = 0; $i -lt $frames.Count; $i++) {
    $id = $i + 1
    if (-not [ResUpdate]::UpdateResourceW($h, [IntPtr]3, [IntPtr]$id, $lang, $frames[$i].data, [uint32]$frames[$i].data.Length)) {
      throw "UpdateResource RT_ICON #$id failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    }
  }
  # RT_GROUP_ICON (14): GRPICONDIR — header + 14-byte entries pointing at the RT_ICON IDs
  $gms = New-Object System.IO.MemoryStream
  $gw = New-Object System.IO.BinaryWriter($gms)
  $gw.Write([uint16]0); $gw.Write([uint16]1); $gw.Write([uint16]$frames.Count)
  for ($i = 0; $i -lt $frames.Count; $i++) {
    $gw.Write([byte]$frames[$i].w); $gw.Write([byte]$frames[$i].h)
    $gw.Write([byte]$frames[$i].cc); $gw.Write([byte]$frames[$i].res)
    $gw.Write([uint16]$frames[$i].planes); $gw.Write([uint16]$frames[$i].bitcount)
    $gw.Write([uint32]$frames[$i].size); $gw.Write([uint16]($i + 1))
  }
  $grp = $gms.ToArray()
  if (-not [ResUpdate]::UpdateResourceW($h, [IntPtr]14, [IntPtr]1, $lang, $grp, [uint32]$grp.Length)) {
    throw "UpdateResource RT_GROUP_ICON failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
  }
  # RT_MANIFEST (24): resource ID 1 (CREATEPROCESS_MANIFEST_RESOURCE_ID)
  $manifest = [System.IO.File]::ReadAllBytes($ManifestPath)
  if (-not [ResUpdate]::UpdateResourceW($h, [IntPtr]24, [IntPtr]1, $lang, $manifest, [uint32]$manifest.Length)) {
    throw "UpdateResource RT_MANIFEST failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
  }
  # RT_VERSION (16): VS_VERSION_INFO — file version metadata for Explorer/SmartScreen
  function Write-Padded([System.IO.BinaryWriter]$w, [int]$padTo = 4) {
    while ($w.BaseStream.Position % $padTo -ne 0) { $w.Write([byte]0) }
  }
  function Write-Block([System.IO.BinaryWriter]$w, [string]$key, [byte[]]$value, [byte[]]$children, [int]$type = 0, [int]$valueLen = -1) {
    $start = $w.BaseStream.Position
    $w.Write([uint16]0)  # wLength placeholder
    $w.Write([uint16]($(if ($valueLen -ge 0) { $valueLen } else { $value.Length })))
    $w.Write([uint16]$type)
    $kBytes = [Text.Encoding]::Unicode.GetBytes($key + "`0")
    $w.Write($kBytes)
    Write-Padded $w
    if ($value.Length -gt 0) { $w.Write($value); Write-Padded $w }
    if ($children.Length -gt 0) { $w.Write($children) }
    $end = $w.BaseStream.Position
    $w.BaseStream.Position = $start
    $w.Write([uint16]($end - $start))
    $w.BaseStream.Position = $end
  }
  $parts = $Version -split '\.' | ForEach-Object { [uint16]$_ }
  while ($parts.Count -lt 4) { $parts += [uint16]0 }
  $ffi = New-Object System.IO.MemoryStream; $fw = New-Object System.IO.BinaryWriter($ffi)
  $fw.Write([byte[]](0xBD,0x04,0xEF,0xFE)); $fw.Write([uint32]0x00010000)  # signature 0xFEEF04BD
  $fw.Write([uint32](($parts[0] -shl 16) -bor $parts[1])); $fw.Write([uint32](($parts[2] -shl 16) -bor $parts[3]))  # FileVersion
  $fw.Write([uint32](($parts[0] -shl 16) -bor $parts[1])); $fw.Write([uint32](($parts[2] -shl 16) -bor $parts[3]))  # ProductVersion
  $fw.Write([uint32]0x3F); $fw.Write([uint32]0)            # flags mask / flags
  $fw.Write([uint32]0x40004); $fw.Write([uint32]1); $fw.Write([uint32]0)  # VOS_NT_WINDOWS32, VFT_APP, subtype
  $fw.Write([uint32]0); $fw.Write([uint32]0)             # date
  $vStr = "$($parts[0]).$($parts[1]).$($parts[2]).$($parts[3])"
  $strings = [ordered]@{
    CompanyName      = 'cosmaxis'
    FileDescription  = 'HTTK Updater Launcher'
    FileVersion      = $vStr
    InternalName     = 'httk-launcher'
    LegalCopyright   = 'Copyright (c) cosmaxis'
    OriginalFilename = 'httk-launcher.exe'
    ProductName      = 'HTTK Updater'
    ProductVersion   = $vStr
  }
  $tbl = New-Object System.IO.MemoryStream; $tw = New-Object System.IO.BinaryWriter($tbl)
  foreach ($name in $strings.Keys) {
    Write-Block $tw $name ([byte[]][Text.Encoding]::Unicode.GetBytes($strings[$name] + "`0")) ([byte[]]@()) 1 ($strings[$name].Length + 1)
  }
  $tblBytes = $tbl.ToArray()
  $sfi = New-Object System.IO.MemoryStream; $sw = New-Object System.IO.BinaryWriter($sfi)
  Write-Block $sw '040904b0' ([byte[]]@()) $tblBytes
  $sfiBytes = $sfi.ToArray()
  $sfiOuter = New-Object System.IO.MemoryStream; $sow = New-Object System.IO.BinaryWriter($sfiOuter)
  Write-Block $sow 'StringFileInfo' ([byte[]]@()) $sfiBytes
  $trans = New-Object System.IO.MemoryStream; $bw = New-Object System.IO.BinaryWriter($trans)
  $bw.Write([uint16]0x0409); $bw.Write([uint16]0x04B0)   # lang en-US, cp Unicode
  $vfi = New-Object System.IO.MemoryStream; $vw = New-Object System.IO.BinaryWriter($vfi)
  Write-Block $vw 'Translation' $trans.ToArray() ([byte[]]@())
  $vfiBytes = $vfi.ToArray()
  $vfiOuter = New-Object System.IO.MemoryStream; $vow = New-Object System.IO.BinaryWriter($vfiOuter)
  Write-Block $vow 'VarFileInfo' ([byte[]]@()) $vfiBytes
  $root = New-Object System.IO.MemoryStream; $rw = New-Object System.IO.BinaryWriter($root)
  Write-Block $rw 'VS_VERSION_INFO' $ffi.ToArray() ($sfiOuter.ToArray() + $vfiOuter.ToArray())
  $ver = $root.ToArray()
  if (-not [ResUpdate]::UpdateResourceW($h, [IntPtr]16, [IntPtr]1, $lang, $ver, [uint32]$ver.Length)) {
    throw "UpdateResource RT_VERSION failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
  }
  if (-not [ResUpdate]::EndUpdateResourceW($h, $false)) {
    throw "EndUpdateResource failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
  }
  Write-Host "Injected: $($frames.Count) icon frame(s) + group icon + manifest + version $Version into $ExePath"
} catch {
  [void][ResUpdate]::EndUpdateResourceW($h, $true)  # discard on failure
  throw
}
