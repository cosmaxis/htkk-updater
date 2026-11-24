$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HttkUpdater.psm1') -Force
Add-Type -AssemblyName System.Net.Http
$root = Join-Path ([IO.Path]::GetTempPath()) ('httk-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$script:passed = 0
$script:failed = 0
function Test-Case($Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; "PASS $Name" } catch { $script:failed++; "FAIL ${Name}: $($_.Exception.Message)" }
}
function Expect-Throw([scriptblock]$Body) {
    $threw = $false
    try { & $Body | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw 'Expected an error' }
}
try {
    $config = @{
        InstallDirectory = Join-Path $root 'install'
        WorkDirectory = Join-Path $root 'work'
        BackupDirectory = Join-Path $root 'backup'
        RestoreVerificationDirectory = Join-Path $root 'restore'
        SevenZipPath = Join-Path $root '7z.exe'
        SevenZipSha256 = 'a' * 64
        PublisherThumbprints = @('b' * 40)
        ReleaseIndicatorPath = Join-Path $root 'install\version.txt'
        ReleaseIndicatorVerified = $true
        ProcessNames = @('httk-test-nonexistent')
        DataPaths = @((Join-Path $root 'install\data'))
        MaxArchiveBytes = 1024
        MaxExtractedBytes = 2048
        MaxArchiveEntries = 20
    }
    Test-Case 'launcher parses installed configuration' { $launcher = Join-Path $PSScriptRoot 'HttkLauncher.ps1'; $text = [IO.File]::ReadAllText($launcher); $functionText = $text.Substring($text.IndexOf('function Get-InstalledRelease'), $text.IndexOf('if ($CheckOnly)') - $text.IndexOf('function Get-InstalledRelease')); . ([scriptblock]::Create($functionText)); $p = Join-Path $root 'app.config'; [IO.File]::WriteAllText($p,'<configuration><appSettings><add key="VERSION" value="5.8.4"/></appSettings></configuration>'); if ((Get-InstalledRelease $p) -ne '5.8.4') { throw 'Wrong version' }; [IO.File]::WriteAllText($p,'<configuration><appSettings><add key="VERSION" value="5.8.4"/><add key="VERSION" value="5.8.5"/></appSettings></configuration>'); Expect-Throw { Get-InstalledRelease $p }; [IO.File]::WriteAllText($p,'<!DOCTYPE x [<!ENTITY x SYSTEM "file:///nonexistent">]><configuration/>'); Expect-Throw { Get-InstalledRelease $p } }
    Test-Case 'launcher shows task and saved error without claiming freshness' { $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'HttkLauncher.ps1')); . ([scriptblock]::Create($text.Substring($text.IndexOf('function Get-InstalledRelease'), $text.IndexOf('if ($CheckOnly)') - $text.IndexOf('function Get-InstalledRelease')))); function Get-ScheduledTask { param($TaskName) if ($TaskName -eq 'HTTK Daily Updater') { [pscustomobject]@{ State='Running'; TaskPath='\' } } else { Write-Error 'not found' -ErrorId 'ObjectNotFound' -ErrorAction Stop } }; function Get-ScheduledTaskInfo { process { [pscustomobject]@{ LastRunTime='yesterday'; LastTaskResult=1 } } }; $p = Join-Path $root 'last-result.json'; [IO.File]::WriteAllText($p,'{"Status":"Error","Stage":"ProcessCheck","Error":"Application process running: HTKK","InstalledVersion":"1.0.0","LatestVersion":"2.0.0"}'); $s = Get-LauncherStatus (Join-Path $root 'missing') $p; foreach ($value in @('Running','last task result: 1','may be stale','ProcessCheck','Application process running: HTKK','1.0.0','2.0.0')) { if (-not $s.Contains($value)) { throw "Missing: $value" } }; [IO.File]::WriteAllText($p,'{'); if ((Get-LauncherStatus (Join-Path $root 'missing') $p) -notmatch 'invalid') { throw 'Malformed result not reported' } }
    Test-Case 'XML release indicator' { $p = Join-Path $root 'version.config'; [IO.File]::WriteAllText($p,'<configuration><appSettings><add key="VERSION" value="5.8.4"/></appSettings></configuration>'); $c=$config.Clone(); $c.ReleaseIndicatorPath=$p; if ((Get-HttkInstalledVersion $c).ToString() -ne '5.8.4') { throw 'Wrong version' }; [IO.File]::WriteAllText($p,'<!DOCTYPE x [<!ENTITY x SYSTEM "file:///nonexistent">]><configuration/>'); Expect-Throw { Get-HttkInstalledVersion $c } }
    Test-Case 'valid configuration' { Assert-HttkConfig $config }
    Test-Case 'overlapping directories rejected' { $c = $config.Clone(); $c.WorkDirectory = Join-Path $c.InstallDirectory 'work'; Expect-Throw { Assert-HttkConfig $c } }
    Test-Case 'external data rejected' { $c = $config.Clone(); $c.DataPaths = @($root); Expect-Throw { Assert-HttkConfig $c } }
    Test-Case 'unverified indicator rejected' { $c = $config.Clone(); $c.ReleaseIndicatorVerified = 'true'; Expect-Throw { Assert-HttkConfig $c } }
    Test-Case 'invalid digest rejected' { $c = $config.Clone(); $c.SevenZipSha256 = 'bad'; Expect-Throw { Assert-HttkConfig $c } }
    Test-Case 'existing download survives failure' { $p = Join-Path $root 'existing'; [IO.File]::WriteAllText($p,'preserve'); Expect-Throw { Save-HttkDownload -Uri 'http://localhost/' -Path $p -MaxBytes 10 }; if ([IO.File]::ReadAllText($p) -cne 'preserve') { throw 'Existing file changed' } }
    Test-Case 'missing trusted extractor rejected' { Expect-Throw { Expand-HttkArchive -Config $config -Archive (Join-Path $root 'archive') -Destination (Join-Path $root 'extract') } }
    Test-Case 'missing data blocks backup' { [IO.Directory]::CreateDirectory($config.InstallDirectory) | Out-Null; Expect-Throw { Backup-HttkInstallation $config }; if (Test-Path -LiteralPath $config.BackupDirectory) { throw 'Backup created despite missing data' } }
    Test-Case 'backup and restore verification' { [IO.Directory]::CreateDirectory($config.DataPaths[0]) | Out-Null; [IO.File]::WriteAllText((Join-Path $config.DataPaths[0] 'sample.txt'),'synthetic'); $b = Backup-HttkInstallation $config; Compare-HttkManifest -Expected @(Get-HttkManifest $config.InstallDirectory) -Actual @(Get-HttkManifest $b.RestoreVerification); if (-not (Test-Path -LiteralPath $b.Manifest)) { throw 'Manifest missing' } }
    Test-Case 'manifest detects modification' { [IO.File]::WriteAllText((Join-Path $config.RestoreVerificationDirectory 'data\sample.txt'),'changed'); Expect-Throw { Compare-HttkManifest -Expected @(Get-HttkManifest $config.InstallDirectory) -Actual @(Get-HttkManifest $config.RestoreVerificationDirectory) } }
    Test-Case 'existing backup not overwritten' { Expect-Throw { Backup-HttkInstallation $config } }
    Test-Case 'invalid indicator rejected' { [IO.File]::WriteAllText($config.ReleaseIndicatorPath,'1.2'); Expect-Throw { Get-HttkInstalledVersion $config } }
    Test-Case 'running process blocks update' { $c = $config.Clone(); $c.ProcessNames = @((Get-Process -Id $PID).ProcessName); Expect-Throw { Assert-HttkNotRunning $c } }
    Test-Case 'missing installers rejected' { Expect-Throw { Assert-HttkSignatures -Config $config -Directory $config.InstallDirectory } }
    Test-Case 'configuration error reported safely' { $c = $config.Clone(); $c.SevenZipSha256 = 'bad'; $r = Invoke-HttkUpdate $c; if ($r.Status -ne 'Error' -or $r.Stage -ne 'Configuration' -or $r.InstallerValidated) { throw 'Unexpected result' } }
    Test-Case 'process error reported before network' { $c = $config.Clone(); $c.ProcessNames = @((Get-Process -Id $PID).ProcessName); $r = Invoke-HttkUpdate $c; if ($r.Status -ne 'Error' -or $r.Stage -ne 'ProcessCheck' -or $r.InstallerValidated) { throw 'Unexpected result' } }
    Test-Case 'download failure prevents uninstall' { & (Get-Module HttkUpdater) { function script:Get-HttkInstalledVersion { [version]'1.0.0' }; function script:Get-HttkRelease { [pscustomobject]@{ Version=[version]'2.0.0'; Uri='https://example.invalid/' } }; function script:Assert-HttkElevation {} ; function script:Save-HttkDownload { throw 'Simulated download failure' } }; try { $r = Invoke-HttkUpdate $config; if ($r.Status -ne 'Error' -or $r.Stage -ne 'Download' -or $r.InstallerValidated) { throw 'Download failure not reported' } } finally { Import-Module (Join-Path $PSScriptRoot 'HttkUpdater.psm1') -Force } }
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
"Passed: $script:passed; Failed: $script:failed"
if ($script:failed) { exit 1 }
