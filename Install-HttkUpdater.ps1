[CmdletBinding()]
param(
    [string]$Repo = 'cosmaxis/httk-updater',
    [string]$Ref = 'main',
    # When set, install files from this local directory (bundled-installer mode)
    # instead of downloading them from GitHub. Expected layout: the four script
    # files and httk-launcher.exe at the top level, optional 7z\7z.exe+7z.dll.
    [string]$PayloadDir,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$TaskName = 'HTTK Daily Updater'
$ShortcutName = 'HTTK.lnk'
$InstallRoot = Join-Path $env:ProgramData 'HttkUpdater'
$BinDir = Join-Path $InstallRoot 'bin'
$SevenZipDir = Join-Path $InstallRoot '7z'
$LogPath = Join-Path $InstallRoot 'install.log'
$ScriptFiles = 'HttkUpdater.psm1','Invoke-HttkUpdate.ps1','HttkLauncher.ps1','Install-HttkUpdater.ps1'
$LauncherVersion = '1.2.1'
# Set at release time from the httk-launcher.exe.sha256 published with the
# v* GitHub release. Empty string = use the PowerShell launcher.
$LauncherSha256 = '6C17E3F6459C1680ACB90B0C0940437104EC6546D74C25B8E6350A36147272CB'
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

function Get-HttkInstallDir {
    foreach ($dir in @('C:\Program Files (x86)\HTKK','C:\Program Files\HTKK')) {
        if (Test-Path -LiteralPath (Join-Path $dir 'Project\HTKK.exe.config') -PathType Leaf) { return $dir }
    }
    return $null
}

if ($Uninstall) {
    if (-not (Test-Administrator)) { throw 'Run elevated to uninstall.' }
    # Cover both generations: pre-1.2.0 used 'HTKK Daily Updater'/'HTKK.lnk'/'HtkkUpdater'.
    foreach ($tn in @($TaskName,'HTKK Daily Updater')) {
        Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
    }
    Get-Process -Name 'httk-launcher','htkk-launcher' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($d in @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('Desktop'))) {
        foreach ($lnk in @($ShortcutName,'HTKK.lnk')) {
            Remove-Item -LiteralPath (Join-Path $d $lnk) -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($root in @($InstallRoot,(Join-Path $env:ProgramData 'HtkkUpdater'))) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'HTTK updater removed (the HTTK application itself was not touched).'
    return
}

if (-not (Test-Administrator)) {
    Write-Host 'Elevation required; relaunching as administrator...'
    if ($PSCommandPath) {
        $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Repo `"$Repo`" -Ref `"$Ref`""
        if ($PayloadDir) { $arg += " -PayloadDir `"$PayloadDir`"" }
        if ($Uninstall) { $arg += ' -Uninstall' }
    } else {
        $arg = "-NoProfile -ExecutionPolicy Bypass -Command `"irm 'https://raw.githubusercontent.com/$Repo/$Ref/Install-HttkUpdater.ps1' | iex`""
    }
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arg -Verb RunAs
    return
}

[IO.Directory]::CreateDirectory($BinDir) | Out-Null

# Migrate a pre-1.2.0 install (HtkkUpdater naming): carry over 7-Zip, the last
# run result and the install log, then drop the old task/shortcuts/dir.
$legacyRoot = Join-Path $env:ProgramData 'HtkkUpdater'
if (Test-Path -LiteralPath $legacyRoot) {
    Get-Process -Name 'htkk-launcher' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'HTKK Daily Updater' -Confirm:$false -ErrorAction SilentlyContinue
    foreach ($d in @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('Desktop'))) {
        Remove-Item -LiteralPath (Join-Path $d 'HTKK.lnk') -Force -ErrorAction SilentlyContinue
    }
    foreach ($f in @('last-result.json','install.log')) {
        $src = Join-Path $legacyRoot $f
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            try { Copy-Item -LiteralPath $src -Destination (Join-Path $InstallRoot $f) -Force } catch {}
        }
    }
    $legacy7z = Join-Path $legacyRoot '7z'
    if (Test-Path -LiteralPath (Join-Path $legacy7z '7z.exe') -PathType Leaf) {
        [IO.Directory]::CreateDirectory($SevenZipDir) | Out-Null
        try {
            Copy-Item -LiteralPath (Join-Path $legacy7z '7z.exe') -Destination (Join-Path $SevenZipDir '7z.exe') -Force
            Copy-Item -LiteralPath (Join-Path $legacy7z '7z.dll') -Destination (Join-Path $SevenZipDir '7z.dll') -Force
        } catch {}
    }
    # NOTE: $legacyRoot is NOT removed here — a -PayloadDir inside it (Inno
    # upgrade path) would delete the payload mid-install. Removed at the end.
    Write-Step 'Migrated previous HtkkUpdater install (data, task, shortcuts)'
}

if ($PayloadDir) {
    Write-Step "Installing HTTK updater from local payload $PayloadDir into $InstallRoot"
} else {
    Write-Step "Installing HTTK updater from $Repo@$Ref into $InstallRoot"
}

foreach ($file in $ScriptFiles) {
    $target = Join-Path $BinDir $file
    if ($PayloadDir) {
        $src = Join-Path $PayloadDir $file
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "Payload is missing $file" }
        if ($src -ine $target) { Copy-Item -LiteralPath $src -Destination $target -Force }
        Write-Step "Installed $file from local payload"
    } else {
        $url = "https://raw.githubusercontent.com/$Repo/$Ref/$file"
        Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60 -OutFile $target
        if ((Get-Item -LiteralPath $target).Length -lt 512) { throw "Downloaded $file is unexpectedly small" }
        Write-Step "Downloaded $file"
    }
}

$sevenZipExe = Join-Path $SevenZipDir '7z.exe'
$sevenZipDll = Join-Path $SevenZipDir '7z.dll'
# Payload 7z lives either inside PayloadDir or as its sibling (Inno stages
# payload\bin\* -> {app}\bin and payload\7z\* -> {app}\7z). The sibling IS the
# destination dir in that layout, so it is skipped — the need7z check below
# already sees the files present and hash-verifies them.
$payloadSevenZip = $null
if ($PayloadDir) {
    foreach ($cand in @((Join-Path $PayloadDir '7z'), (Join-Path (Split-Path $PayloadDir -Parent) '7z'))) {
        if ([IO.Path]::GetFullPath($cand) -ieq [IO.Path]::GetFullPath($SevenZipDir)) { continue }
        if (Test-Path -LiteralPath (Join-Path $cand '7z.exe') -PathType Leaf) { $payloadSevenZip = $cand; break }
    }
}
if ($payloadSevenZip -and (Test-Path -LiteralPath (Join-Path $payloadSevenZip '7z.exe') -PathType Leaf)) {
    [IO.Directory]::CreateDirectory($SevenZipDir) | Out-Null
    Copy-Item -LiteralPath (Join-Path $payloadSevenZip '7z.exe') -Destination $sevenZipExe -Force
    Copy-Item -LiteralPath (Join-Path $payloadSevenZip '7z.dll') -Destination $sevenZipDll -Force
    $need7z = $false
    Write-Step 'Installed 7-Zip from local payload'
} else {
    $need7z = -not ((Test-Path -LiteralPath $sevenZipExe -PathType Leaf) -and (Test-Path -LiteralPath $sevenZipDll -PathType Leaf) -and
        ((Get-FileHash -LiteralPath $sevenZipExe -Algorithm SHA256).Hash -ieq $SevenZipExeSha256) -and
        ((Get-FileHash -LiteralPath $sevenZipDll -Algorithm SHA256).Hash -ieq $SevenZipDllSha256))
}
if ($need7z) {
    $tmp = Join-Path $env:TEMP ('httk-7z-' + [guid]::NewGuid().ToString('N'))
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

Import-Module (Join-Path $BinDir 'HttkUpdater.psm1') -Force
$installDir = Get-HttkInstallDir
if (-not $installDir) {
    Write-Step 'HTTK not installed; installing latest release'
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
        Assert-HttkNotRunning $config
        $release = Get-HttkRelease $config
        $archive = Join-Path $work 'release.archive'
        Save-HttkDownload -Uri $release.Uri -Path $archive -MaxBytes ([long]$config.MaxArchiveBytes)
        $extracted = Join-Path $work 'extracted'
        Expand-HttkArchive -Config $config -Archive $archive -Destination $extracted
        $msiPath = Assert-HttkSignatures -Config $config -Directory $extracted
        Write-Step "Installing HTTK $($release.Version)"
        $log = Join-Path $work 'msiexec.log'
        $proc = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList @('/i',('"' + $msiPath + '"'),'/qn','/norestart','/l*v',('"' + $log + '"')) -Wait -PassThru
        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) { throw "HTTK install failed (msiexec exit $($proc.ExitCode)); log: $log" }
        $installed = Get-HttkInstalledVersion $config
        if ($installed -ne $release.Version) { throw "Installed version $installed does not match expected $($release.Version)" }
        Write-Step "HTTK $installed installed"
        if ($proc.ExitCode -eq 3010) { Write-Step 'Reboot required to finish HTTK install' }
    } finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
} else {
    Write-Step "HTTK found at $installDir"
}

$action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $BinDir 'Invoke-HttkUpdate.ps1') + '"')
$trigger = New-ScheduledTaskTrigger -Daily -At '09:00'
# Run as the installing user (S4U = even when not logged in; Highest = elevated).
# On hardened Windows builds SYSTEM-principal tasks are admin-only, which would
# hide the task from the launcher's status view and manual run button.
$userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$principal = New-ScheduledTaskPrincipal -UserId $userSid -LogonType S4U -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Description 'Checks the official HTTK page daily and updates the installed application to the latest signed release.' -Force | Out-Null
Write-Step "Scheduled task '$TaskName' registered (daily 09:00, runs as $env:USERNAME)"

# Native launcher: only enabled once $LauncherSha256 is pinned at release time.
$launcherExe = Join-Path $BinDir 'httk-launcher.exe'
$launcherOk = $false
$shaToCheck = $LauncherSha256
if ($LauncherSha256) {
    try {
        Get-Process -Name 'httk-launcher' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        if ($PayloadDir) {
            $src = Join-Path $PayloadDir 'httk-launcher.exe'
            if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw 'payload is missing httk-launcher.exe' }
            if ($src -ine $launcherExe) { Copy-Item -LiteralPath $src -Destination $launcherExe -Force }
            Write-Step "Native launcher $LauncherVersion installed from local payload"
        } else {
            $launcherUrl = "https://github.com/$Repo/releases/download/v$LauncherVersion/httk-launcher.exe"
            Invoke-WebRequest -Uri $launcherUrl -UseBasicParsing -TimeoutSec 60 -OutFile $launcherExe
            Write-Step "Native launcher $LauncherVersion downloaded"
            # Prefer the .sha256 published alongside the exe: CI rebuilds produce a
            # different (also valid) hash than the one pinned at commit time.
            try {
                $shaText = (Invoke-WebRequest -Uri "$launcherUrl.sha256" -UseBasicParsing -TimeoutSec 30).Content
                $expected = ($shaText -split '\s+')[0]
                if ($expected -match '^[0-9A-Fa-f]{64}$') { $shaToCheck = $expected }
            } catch { }
        }
        Assert-FileHash -Path $launcherExe -Sha256 $shaToCheck -Name 'httk-launcher.exe'
        $launcherOk = $true
        Write-Step 'Native launcher hash verified'
    } catch {
        Remove-Item -LiteralPath $launcherExe -Force -ErrorAction SilentlyContinue
        Write-Step "Warning: native launcher unavailable ($($_.Exception.Message)); using the PowerShell launcher"
    }
} else {
    Write-Step 'Warning: $LauncherSha256 is empty; using the PowerShell launcher'
}

$desktops = @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('Desktop')) | Select-Object -Unique
$shell = New-Object -ComObject WScript.Shell
foreach ($desktop in $desktops) {
    $shortcutPath = Join-Path $desktop $ShortcutName
    $shortcut = $shell.CreateShortcut($shortcutPath)
    if ($launcherOk) {
        $shortcut.TargetPath = $launcherExe
        $shortcut.Arguments = ''
    } else {
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $BinDir 'HttkLauncher.ps1') + '"'
    }
    $shortcut.WorkingDirectory = $BinDir
    if ($launcherOk) {
        $shortcut.IconLocation = "$launcherExe,0"
    } else {
        $exe = Join-Path $installDir 'Project\HTKK.exe'
        if (Test-Path -LiteralPath $exe -PathType Leaf) { $shortcut.IconLocation = "$exe,0" }
    }
    $shortcut.Description = 'HTTK launcher with live update status'
    $shortcut.Save()
    Write-Step "Desktop shortcut '$ShortcutName' created at $shortcutPath"
}

# Legacy WinForms-era location; only fills in when nothing was migrated above.
$migrated = Join-Path $env:LOCALAPPDATA 'HtkkUpdater\last-result.json'
$destResult = Join-Path $InstallRoot 'last-result.json'
if ((Test-Path -LiteralPath $migrated -PathType Leaf) -and -not (Test-Path -LiteralPath $destResult -PathType Leaf)) {
    try { Copy-Item -LiteralPath $migrated -Destination $destResult -Force } catch {}
}

if (Test-Path -LiteralPath $legacyRoot) {
    Remove-Item -LiteralPath $legacyRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Step 'Install complete: double-click the HTTK desktop icon to open the launcher; updates run daily at 09:00.'
Write-Host ''
Write-Host 'Done. HTTK auto-updater installed: daily 09:00 updates, HTTK desktop launcher created.' -ForegroundColor Green
