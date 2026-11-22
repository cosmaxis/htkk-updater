[CmdletBinding()]
param(
    [string]$Repo = 'cosmaxis/htkk-updater',
    [string]$Ref = 'main',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$TaskName = 'HTKK Daily Updater'
$ShortcutName = 'HTKK.lnk'
$InstallRoot = Join-Path $env:ProgramData 'HtkkUpdater'
$BinDir = Join-Path $InstallRoot 'bin'
$SevenZipDir = Join-Path $InstallRoot '7z'
$LogPath = Join-Path $InstallRoot 'install.log'
$ScriptFiles = 'HtkkUpdater.psm1','Invoke-HtkkUpdate.ps1','HtkkLauncher.ps1','Install-HtkkUpdater.ps1'
$LauncherVersion = '1.1.0'
# Set at release time from the htkk-launcher.exe.sha256 published with the
# v* GitHub release. Empty string = use the PowerShell launcher.
$LauncherSha256 = '83EF8480530C9F56FB690C6AC5A1CE23DA4F30E9057F5965B06F0C74CB9F1D8A'
$SevenZipMsiUrl = 'https://www.7-zip.org/a/7z2606-x64.msi'
$SevenZipMsiSha256 = '6DC822569E777D9A3ECD5FFCBC22B55600AF87E6C5D9810A64E8566CF5A4AF9F'
$SevenZipExeSha256 = 'DC0493429FE28136FCB177A0E77C9875CBB3B0BFF5F2F8EEBA4DF302E98CEF76'
$SevenZipDllSha256 = '500DB9EB17F3C21B729BA41DD02ECFE1823DA05028C7E4BA129084CC74CC364E'

function Write-Step([string]$Message) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line -ErrorAction Stop } catch {}
}

function Test-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-FileHash([string]$Path, [string]$Sha256, [string]$Name) {
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ine $Sha256) { throw "$Name hash mismatch: expected $Sha256, got $actual" }
}

function Get-HtkkInstallDir {
    foreach ($dir in @('C:\Program Files (x86)\HTKK','C:\Program Files\HTKK')) {
        if (Test-Path -LiteralPath (Join-Path $dir 'Project\HTKK.exe.config') -PathType Leaf) { return $dir }
    }
    return $null
}

if ($Uninstall) {
    if (-not (Test-Administrator)) { throw 'Run elevated to uninstall.' }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Get-Process -Name 'htkk-launcher' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) $ShortcutName) -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'HTKK updater removed (the HTKK application itself was not touched).'
    return
}

if (-not (Test-Administrator)) {
    Write-Host 'Elevation required; relaunching as administrator...'
    $arg = "-NoProfile -ExecutionPolicy Bypass -Command `"irm 'https://raw.githubusercontent.com/$Repo/$Ref/Install-HtkkUpdater.ps1' | iex`""
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arg -Verb RunAs
    return
}

[IO.Directory]::CreateDirectory($BinDir) | Out-Null
Write-Step "Installing HTKK updater from $Repo@$Ref into $InstallRoot"

foreach ($file in $ScriptFiles) {
    $url = "https://raw.githubusercontent.com/$Repo/$Ref/$file"
    $target = Join-Path $BinDir $file
    Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60 -OutFile $target
    if ((Get-Item -LiteralPath $target).Length -lt 512) { throw "Downloaded $file is unexpectedly small" }
    Write-Step "Downloaded $file"
}

$sevenZipExe = Join-Path $SevenZipDir '7z.exe'
$sevenZipDll = Join-Path $SevenZipDir '7z.dll'
$need7z = -not ((Test-Path -LiteralPath $sevenZipExe -PathType Leaf) -and (Test-Path -LiteralPath $sevenZipDll -PathType Leaf) -and
    ((Get-FileHash -LiteralPath $sevenZipExe -Algorithm SHA256).Hash -ieq $SevenZipExeSha256) -and
    ((Get-FileHash -LiteralPath $sevenZipDll -Algorithm SHA256).Hash -ieq $SevenZipDllSha256))
if ($need7z) {
    $tmp = Join-Path $env:TEMP ('htkk-7z-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tmp) | Out-Null
    try {
        $msi = Join-Path $tmp '7z.msi'
        Invoke-WebRequest -Uri $SevenZipMsiUrl -UseBasicParsing -TimeoutSec 120 -OutFile $msi
        Assert-FileHash -Path $msi -Sha256 $SevenZipMsiSha256 -Name '7-Zip MSI'
        $adminTarget = Join-Path $tmp 'extracted'
        $proc = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList @('/a',('"' + $msi + '"'),'/qn',('TARGETDIR="' + $adminTarget + '"')) -Wait -PassThru
        if ($proc.ExitCode -ne 0) { throw "7-Zip extraction failed (msiexec /a exit $($proc.ExitCode))" }
        $srcExe = Get-ChildItem -LiteralPath $adminTarget -Recurse -Filter '7z.exe' -File | Select-Object -First 1
        $srcDll = Get-ChildItem -LiteralPath $adminTarget -Recurse -Filter '7z.dll' -File | Select-Object -First 1
        if (-not $srcExe -or -not $srcDll) { throw '7z.exe/7z.dll not found in official package' }
        [IO.Directory]::CreateDirectory($SevenZipDir) | Out-Null
        Copy-Item -LiteralPath $srcExe.FullName -Destination $sevenZipExe -Force
        Copy-Item -LiteralPath $srcDll.FullName -Destination $sevenZipDll -Force
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
Assert-FileHash -Path $sevenZipExe -Sha256 $SevenZipExeSha256 -Name '7z.exe'
Assert-FileHash -Path $sevenZipDll -Sha256 $SevenZipDllSha256 -Name '7z.dll'
Write-Step 'Trusted 7-Zip 26.06 verified'

Import-Module (Join-Path $BinDir 'HtkkUpdater.psm1') -Force
$installDir = Get-HtkkInstallDir
if (-not $installDir) {
    Write-Step 'HTKK not installed; installing latest release'
    $work = Join-Path $InstallRoot ('bootstrap-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($work) | Out-Null
    $installDir = 'C:\Program Files (x86)\HTKK'
    $config = @{
        InstallDirectory = $installDir
        WorkDirectory = $work
        BackupDirectory = Join-Path $work 'backup'
        RestoreVerificationDirectory = Join-Path $work 'verified'
        SevenZipPath = $sevenZipExe
        SevenZipSha256 = $SevenZipExeSha256
        SevenZipDllSha256 = $SevenZipDllSha256
        PublisherThumbprints = @('516F4A7FDA7331CC292C955E2ACF155C93D40738')
        ReleaseIndicatorPath = Join-Path $installDir 'Project\HTKK.exe.config'
        ReleaseIndicatorVerified = $true
        ProcessNames = @('HTKK','Client_VersionUpdate')
        DataPaths = @($installDir)
        MaxArchiveBytes = 1073741824
        MaxExtractedBytes = 4294967296
        MaxArchiveEntries = 30000
    }
    try {
        Assert-HtkkNotRunning $config
        $release = Get-HtkkRelease $config
        $archive = Join-Path $work 'release.archive'
        Save-HtkkDownload -Uri $release.Uri -Path $archive -MaxBytes ([long]$config.MaxArchiveBytes)
        $extracted = Join-Path $work 'extracted'
        Expand-HtkkArchive -Config $config -Archive $archive -Destination $extracted
        $msiPath = Assert-HtkkSignatures -Config $config -Directory $extracted
        Write-Step "Installing HTKK $($release.Version)"
        $log = Join-Path $work 'msiexec.log'
        $proc = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList @('/i',('"' + $msiPath + '"'),'/qn','/norestart','/l*v',('"' + $log + '"')) -Wait -PassThru
        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) { throw "HTKK install failed (msiexec exit $($proc.ExitCode)); log: $log" }
        $installed = Get-HtkkInstalledVersion $config
        if ($installed -ne $release.Version) { throw "Installed version $installed does not match expected $($release.Version)" }
        Write-Step "HTKK $installed installed"
        if ($proc.ExitCode -eq 3010) { Write-Step 'Reboot required to finish HTKK install' }
    } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
} else {
    Write-Step "HTKK found at $installDir"
}

$action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $BinDir 'Invoke-HtkkUpdate.ps1') + '"')
$trigger = New-ScheduledTaskTrigger -Daily -At '09:00'
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Description 'Checks the official HTKK page daily and updates the installed application to the latest signed release.' -Force | Out-Null
Write-Step "Scheduled task '$TaskName' registered (daily 09:00, SYSTEM)"

# Native launcher: only enabled once $LauncherSha256 is pinned at release time.
$launcherExe = Join-Path $BinDir 'htkk-launcher.exe'
$launcherOk = $false
if ($LauncherSha256) {
    try {
        Get-Process -Name 'htkk-launcher' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $launcherUrl = "https://github.com/$Repo/releases/download/v$LauncherVersion/htkk-launcher.exe"
        Invoke-WebRequest -Uri $launcherUrl -UseBasicParsing -TimeoutSec 60 -OutFile $launcherExe
        Assert-FileHash -Path $launcherExe -Sha256 $LauncherSha256 -Name 'htkk-launcher.exe'
        $launcherOk = $true
        Write-Step "Native launcher $LauncherVersion downloaded and verified"
    } catch {
        Remove-Item -LiteralPath $launcherExe -Force -ErrorAction SilentlyContinue
        Write-Step "Warning: native launcher unavailable ($($_.Exception.Message)); using the PowerShell launcher"
    }
} else {
    Write-Step 'Warning: $LauncherSha256 is empty; using the PowerShell launcher'
}

$desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
$shortcutPath = Join-Path $desktop $ShortcutName
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
if ($launcherOk) {
    $shortcut.TargetPath = $launcherExe
    $shortcut.Arguments = ''
} else {
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $BinDir 'HtkkLauncher.ps1') + '"'
}
$shortcut.WorkingDirectory = $BinDir
$exe = Join-Path $installDir 'Project\HTKK.exe'
if (Test-Path -LiteralPath $exe -PathType Leaf) { $shortcut.IconLocation = "$exe,0" }
$shortcut.Description = 'HTKK launcher with live update status'
$shortcut.Save()
Write-Step "Desktop shortcut '$ShortcutName' created for all users"

$migrated = Join-Path $env:LOCALAPPDATA 'HtkkUpdater\last-result.json'
if (Test-Path -LiteralPath $migrated -PathType Leaf) {
    try { Copy-Item -LiteralPath $migrated -Destination (Join-Path $InstallRoot 'last-result.json') -Force } catch {}
}

Write-Step 'Install complete: double-click the HTKK desktop icon to open the launcher; updates run daily at 09:00.'
Write-Host ''
Write-Host 'Done. HTKK auto-updater installed: daily 09:00 updates, HTKK desktop launcher created.' -ForegroundColor Green
