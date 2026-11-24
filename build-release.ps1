#Requires -Version 5.1
<#
.SYNOPSIS
  Production release pipeline for HTTK Updater.
  1. cargo build --release (launcher)
  2. inject icon + manifest + version info (embed-resources.ps1 — no windres needed)
  3. pin $LauncherVersion/$LauncherSha256 in Install-HttkUpdater.ps1
  4. stage installer\payload\ (bin + 7z)
  5. compile Inno Setup -> dist\httk-updater-setup-<ver>.exe
.EXAMPLE
  .\build-release.ps1
  .\build-release.ps1 -SkipInno   # just build + embed + stage
#>
[CmdletBinding()]
param(
  [switch]$SkipInno
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$launcher = Join-Path $root 'launcher'
$installerDir = Join-Path $root 'installer'
$payloadDir = Join-Path $installerDir 'payload'
$distDir = Join-Path $root 'dist'

# --- version from Cargo.toml -------------------------------------------------
$cargo = Get-Content (Join-Path $launcher 'Cargo.toml') -Raw
if ($cargo -notmatch '(?m)^version\s*=\s*"([0-9.]+)"') { throw 'version not found in Cargo.toml' }
$version = $Matches[1]
$version4 = if (($version -split '\.').Count -eq 3) { "$version.0" } else { $version }
Write-Host "==> Building HTTK Updater $version" -ForegroundColor Cyan

# --- 1. cargo build ----------------------------------------------------------
# Resource compiler: embed_resource probes RC/$RC_<target>/x86_64-w64-mingw32-windres.
# A local MinGW64 (windres) makes the .rc embed icon+manifest natively; the
# post-build step below adds version info regardless of toolchain.
$mingw = "$env:USERPROFILE\mingw64\bin"
if (Test-Path (Join-Path $mingw 'windres.exe')) {
  $env:PATH = "$mingw;$env:PATH"
  $env:RC = 'windres'
}
Push-Location $launcher
try {
  cargo build --release
  if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }
} finally { Pop-Location }
$exe = Join-Path $launcher 'target\release\httk-launcher.exe'

# --- 2. embed resources ------------------------------------------------------
& (Join-Path $launcher 'embed-resources.ps1') -ExePath $exe `
  -IcoPath (Join-Path $launcher 'assets\httk.ico') `
  -ManifestPath (Join-Path $launcher 'app.manifest') `
  -Version $version4
if ((Get-Item $exe).VersionInfo.FileVersion -ne $version4) { throw 'version info not embedded' }
Write-Host "==> Resources embedded (icon + manifest + $version4)" -ForegroundColor Cyan

# --- 3. pin version + hash ---------------------------------------------------
$sha = (Get-FileHash $exe -Algorithm SHA256).Hash
$installPs1 = Join-Path $root 'Install-HttkUpdater.ps1'
$text = Get-Content $installPs1 -Raw
$text = $text -replace "(LauncherVersion\s*=\s*')[0-9.]+'", "`${1}$version'"
$text = $text -replace "(LauncherSha256\s*=\s*')[0-9A-Fa-f]+'", "`${1}$sha'"
Set-Content -LiteralPath $installPs1 -Value $text -NoNewline -Encoding UTF8
$parseErrs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($installPs1, [ref]$null, [ref]$parseErrs)
if ($parseErrs) { throw "Install-HttkUpdater.ps1 broken after pinning: $($parseErrs[0].Message)" }
Write-Host "==> Pinned launcher $version sha256=$($sha.Substring(0,16))..." -ForegroundColor Cyan

# --- 4. stage payload --------------------------------------------------------
if (Test-Path $payloadDir) { Remove-Item $payloadDir -Recurse -Force }
$bin = New-Item -ItemType Directory -Path (Join-Path $payloadDir 'bin') -Force
$seven = New-Item -ItemType Directory -Path (Join-Path $payloadDir '7z') -Force
Copy-Item $exe (Join-Path $bin 'httk-launcher.exe')
foreach ($f in 'HttkUpdater.psm1','Invoke-HttkUpdate.ps1','HttkLauncher.ps1','Install-HttkUpdater.ps1') {
  Copy-Item (Join-Path $root $f) (Join-Path $bin $f)
}
# 7z: reuse the already-verified local copy (current or pre-1.2.0 dir), else fetch
$local7z = @('HttkUpdater\7z','HtkkUpdater\7z') | ForEach-Object { Join-Path $env:ProgramData $_ } | Where-Object { Test-Path (Join-Path $_ '7z.exe') } | Select-Object -First 1
$exeSha7z = 'DC0493429FE28136FCB177A0E77C9875CBB3B0BFF5F2F8EEBA4DF302E98CEF76'
$dllSha7z = '500DB9EB17F3C21B729BA41DD02ECFE1823DA05028C7E4BA129084CC74CC364E'
if ((Test-Path "$local7z\7z.exe") -and ((Get-FileHash "$local7z\7z.exe").Hash -ieq $exeSha7z) -and ((Get-FileHash "$local7z\7z.dll").Hash -ieq $dllSha7z)) {
  Copy-Item "$local7z\7z.exe","$local7z\7z.dll" $seven
} else {
  Write-Host '==> Fetching 7-Zip 26.06 for payload'
  $tmp = Join-Path $env:TEMP ('httk-7z-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $msi = Join-Path $tmp '7z.msi'
    Invoke-WebRequest -Uri 'https://www.7-zip.org/a/7z2606-x64.msi' -UseBasicParsing -TimeoutSec 120 -OutFile $msi
    if ((Get-FileHash $msi).Hash -ine '6DC822569E777D9A3ECD5FFCBC22B55600AF87E6C5D9810A64E8566CF5A4AF9F') { throw '7z msi hash mismatch' }
    $ext = Join-Path $tmp 'x'
    $p = Start-Process msiexec.exe -ArgumentList '/a',"`"$msi`"",'/qn',"TARGETDIR=`"$ext`"" -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "msiexec /a exit $($p.ExitCode)" }
    Copy-Item (Get-ChildItem $ext -Recurse -Filter 7z.exe | Select-Object -First 1).FullName (Join-Path $seven '7z.exe')
    Copy-Item (Get-ChildItem $ext -Recurse -Filter 7z.dll | Select-Object -First 1).FullName (Join-Path $seven '7z.dll')
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
if ((Get-FileHash (Join-Path $seven '7z.exe')).Hash -ine $exeSha7z) { throw 'payload 7z.exe hash mismatch' }
Write-Host '==> Payload staged' -ForegroundColor Cyan

# --- 5. Inno Setup -----------------------------------------------------------
if (-not $SkipInno) {
  $iscc = Get-ChildItem "${env:ProgramFiles(x86)}\Inno Setup 6","$env:ProgramFiles\Inno Setup 6","$env:LOCALAPPDATA\Programs\Inno Setup 6" -Filter ISCC.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $iscc) { $iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source }
  if (-not $iscc) { throw 'Inno Setup (ISCC.exe) not found — install JRSoftware.InnoSetup' }
  New-Item -ItemType Directory -Path $distDir -Force | Out-Null
  & $iscc.FullName /DAppVersion=$version (Join-Path $installerDir 'httk-updater.iss') | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "ISCC failed ($LASTEXITCODE)" }
  $setup = Join-Path $distDir "httk-updater-setup-$version.exe"
  $setupSha = (Get-FileHash $setup -Algorithm SHA256).Hash
  Write-Host "==> Setup: $setup" -ForegroundColor Green
  Write-Host "    sha256: $setupSha"
}
Write-Host '==> Done' -ForegroundColor Green
