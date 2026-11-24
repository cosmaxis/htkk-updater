[CmdletBinding()]
param([string]$ConfigPath)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'HttkUpdater.psm1') -Force
if ($ConfigPath) {
    if (-not [IO.Path]::IsPathRooted($ConfigPath)) { throw 'ConfigPath must be absolute' }
    $config = Import-PowerShellDataFile -LiteralPath $ConfigPath
} else {
    $root = Join-Path $env:ProgramData 'HttkUpdater'
    $id = [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
    $install = $null
    foreach ($dir in @('C:\Program Files (x86)\HTKK','C:\Program Files\HTKK')) {
        if (Test-Path -LiteralPath (Join-Path $dir 'Project\HTKK.exe.config') -PathType Leaf) { $install = $dir; break }
    }
    if (-not $install) { throw 'HTTK installation not found' }
    $config = @{
        InstallDirectory = $install
        WorkDirectory = Join-Path $root "work\$id"
        BackupDirectory = Join-Path $root "backups\$id"
        RestoreVerificationDirectory = Join-Path $root "verified\$id"
        SevenZipPath = Join-Path $root '7z\7z.exe'
        SevenZipSha256 = 'DC0493429FE28136FCB177A0E77C9875CBB3B0BFF5F2F8EEBA4DF302E98CEF76'
        SevenZipDllSha256 = '500DB9EB17F3C21B729BA41DD02ECFE1823DA05028C7E4BA129084CC74CC364E'
        PublisherThumbprints = @('516F4A7FDA7331CC292C955E2ACF155C93D40738')
        ReleaseIndicatorPath = Join-Path $install 'Project\HTKK.exe.config'
        ReleaseIndicatorVerified = $true
        ProcessNames = @('HTKK','Client_VersionUpdate')
        DataPaths = @($install)
        MaxArchiveBytes = 1073741824
        MaxExtractedBytes = 4294967296
        MaxArchiveEntries = 30000
    }
}
$result = Invoke-HttkUpdate -Config $config
$json = $result | ConvertTo-Json -Depth 6
$logRoot = Join-Path $env:ProgramData 'HttkUpdater'
[IO.Directory]::CreateDirectory($logRoot) | Out-Null
[IO.File]::WriteAllText((Join-Path $logRoot 'last-result.json'),$json,(New-Object Text.UTF8Encoding($false)))
$json
if ($result.Status -eq 'Error') { exit 1 }
