Set-StrictMode -Version Latest

function Assert-HtkkConfig {
    param([Parameter(Mandatory=$true)][hashtable]$Config)
    $required = @('InstallDirectory','WorkDirectory','BackupDirectory','RestoreVerificationDirectory','SevenZipPath','SevenZipSha256','PublisherThumbprints','ReleaseIndicatorPath','ProcessNames','DataPaths','MaxArchiveBytes','MaxExtractedBytes','MaxArchiveEntries')
    foreach ($key in $required) { if (-not $Config.ContainsKey($key) -or $null -eq $Config[$key]) { throw "Missing configuration: $key" } }
    foreach ($key in @('InstallDirectory','WorkDirectory','BackupDirectory','RestoreVerificationDirectory','SevenZipPath','ReleaseIndicatorPath')) { if (-not [IO.Path]::IsPathRooted([string]$Config[$key])) { throw "$key must be an absolute path" } }
    foreach ($key in @('InstallDirectory','WorkDirectory','BackupDirectory','RestoreVerificationDirectory')) { if ([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Config[$key])).TrimEnd('\') -eq ([IO.Path]::GetFullPath($Config[$key])).TrimEnd('\')) { throw "$key cannot be a filesystem root" } }
    $dirs = @('InstallDirectory','WorkDirectory','BackupDirectory','RestoreVerificationDirectory') | ForEach-Object { [IO.Path]::GetFullPath($Config[$_]).TrimEnd('\') }
    for ($i=0; $i -lt $dirs.Count; $i++) { for ($j=$i+1; $j -lt $dirs.Count; $j++) { if ($dirs[$i].Equals($dirs[$j],[StringComparison]::OrdinalIgnoreCase) -or $dirs[$i].StartsWith($dirs[$j]+'\',[StringComparison]::OrdinalIgnoreCase) -or $dirs[$j].StartsWith($dirs[$i]+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Install, work, backup and restore directories must not overlap' } } }
    if ($Config.SevenZipSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'SevenZipSha256 must be an explicit SHA-256 digest' }
    if (@($Config.PublisherThumbprints).Count -eq 0) { throw 'PublisherThumbprints cannot be empty' }
    foreach ($thumb in $Config.PublisherThumbprints) { if ($thumb -notmatch '^[a-fA-F0-9]{40}$') { throw 'Publisher thumbprints must be SHA-1 certificate thumbprints' } }
    if (@($Config.ProcessNames).Count -eq 0 -or @($Config.DataPaths).Count -eq 0) { throw 'ProcessNames and DataPaths must be explicitly configured' }
    foreach ($name in $Config.ProcessNames) { if ($name -notmatch '^[\w .-]+$') { throw 'Invalid process name' } }
    foreach ($path in $Config.DataPaths) { if (-not [IO.Path]::IsPathRooted([string]$path)) { throw 'DataPaths must be absolute' }; $full = [IO.Path]::GetFullPath($path).TrimEnd('\'); if (-not $full.StartsWith($dirs[0]+'\',[StringComparison]::OrdinalIgnoreCase) -and -not $full.Equals($dirs[0],[StringComparison]::OrdinalIgnoreCase)) { throw 'DataPaths must be inside InstallDirectory; external data requires separate protection' } }
    foreach ($key in @('MaxArchiveBytes','MaxExtractedBytes','MaxArchiveEntries')) { $n = 0L; if (-not [long]::TryParse([string]$Config[$key],[ref]$n) -or $n -le 0) { throw "$key must be a positive integer" } }
    $indicator = [IO.Path]::GetFullPath($Config.ReleaseIndicatorPath)
    if (-not $indicator.StartsWith($dirs[0]+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($indicator) -ieq 'Setup.ini') { throw 'ReleaseIndicatorPath must be an installed file inside InstallDirectory and not Setup.ini' }
    if (-not $Config.ContainsKey('ReleaseIndicatorVerified') -or $Config.ReleaseIndicatorVerified -isnot [bool] -or -not $Config.ReleaseIndicatorVerified) { throw 'An independently verified release indicator is required' }
}

function Get-HtkkRelease {
    param([Parameter(Mandatory=$true)][hashtable]$Config)
    $uri = 'https://www.gdt.gov.vn/wps/portal/home/hotrokekhai?1dmy&current=true&urile=wcm:path:/gdt+content/sa_gdt/htkk/soft_sup_declare'
    $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
    if ($response.BaseResponse.ResponseUri.Scheme -ne 'https' -or $response.BaseResponse.ResponseUri.Host -ine 'www.gdt.gov.vn') { throw 'Official release page redirected to an unexpected host' }
    $rows = [regex]::Matches($response.Content,'(?is)<tr\b[^>]*>.*?</tr>')
    $releases = @()
    foreach ($row in $rows) {
        $text = [System.Net.WebUtility]::HtmlDecode(($row.Value -replace '<[^>]+>',' '))
        $versions = @([regex]::Matches($text,'(?<!\d)\d+\.\d+\.\d+(?:\.\d+)?(?!\d)') | ForEach-Object { $_.Value } | Select-Object -Unique)
        $links = [regex]::Matches($row.Value,'(?is)<a\b[^>]*href\s*=\s*["'']([^"'']+)["''][^>]*>\s*(?:<[^>]+>\s*)*(?:ZIP|RAR|TẢI|DOWNLOAD)\b')
        if (@($versions).Count -eq 1 -and $links.Count -eq 1) {
            $link = [uri]::new([uri]$uri,[System.Net.WebUtility]::HtmlDecode($links[0].Groups[1].Value))
            if ($link.Scheme -ne 'https' -or $link.UserInfo) { throw 'Release link is not a safe HTTPS URL' }
            $releases += [pscustomobject]@{ Version = [version]$versions[0]; Uri = $link.AbsoluteUri }
        }
    }
    if ($releases.Count -eq 0) { throw 'Official release page did not contain an unambiguous release row' }
    $sorted = @($releases | Sort-Object Version -Descending)
    if (@($sorted | Where-Object { $_.Version -eq $sorted[0].Version }).Count -ne 1) { throw 'Latest release is ambiguous' }
    return $sorted[0]
}

function Save-HtkkDownload {
    param([Parameter(Mandatory=$true)][string]$Uri,[Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][long]$MaxBytes)
    $current = [uri]$Uri
    $created = $false
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(5)
    try {
        for ($redirects=0; $redirects -le 5; $redirects++) {
            if ($current.Scheme -ne 'https' -or $current.UserInfo) { throw 'Download requires HTTPS at every redirect' }
            $response = $client.GetAsync($current,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            if ([int]$response.StatusCode -ge 300 -and [int]$response.StatusCode -lt 400) {
                $location = $response.Headers.Location
                $response.Dispose()
                if ($null -eq $location) { throw 'Redirect lacks a location' }
                $current = [uri]::new($current,$location)
                continue
            }
            try {
                $response.EnsureSuccessStatusCode() | Out-Null
                if ($null -ne $response.Content.Headers.ContentLength -and $response.Content.Headers.ContentLength -gt $MaxBytes) { throw 'Download exceeds configured limit' }
                $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $outputStream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $created = $true
                try {
                    $buffer = New-Object byte[] 65536; $total = 0L
                    while (($count = $inputStream.Read($buffer,0,$buffer.Length)) -gt 0) { $total += $count; if ($total -gt $MaxBytes) { throw 'Download exceeds configured limit' }; $outputStream.Write($buffer,0,$count) }
                    if ($total -eq 0) { throw 'Empty download' }
                } finally { $outputStream.Dispose(); $inputStream.Dispose() }
                return
            } finally { $response.Dispose() }
        }
        throw 'Too many download redirects'
    } catch { if ($created -and (Test-Path -LiteralPath $Path -PathType Leaf)) { Remove-Item -LiteralPath $Path -Force }; throw } finally { $client.Dispose(); $handler.Dispose() }
}

function Expand-HtkkArchive {
    param([Parameter(Mandatory=$true)][hashtable]$Config,[Parameter(Mandatory=$true)][string]$Archive,[Parameter(Mandatory=$true)][string]$Destination)
    if (-not (Test-Path -LiteralPath $Config.SevenZipPath -PathType Leaf) -or (Get-FileHash -LiteralPath $Config.SevenZipPath -Algorithm SHA256).Hash -ine $Config.SevenZipSha256) { throw 'Trusted 7z executable missing or digest mismatch' }
    $dll = Join-Path ([IO.Path]::GetDirectoryName($Config.SevenZipPath)) '7z.dll'
    if (-not $Config.ContainsKey('SevenZipDllSha256') -or -not (Test-Path -LiteralPath $dll -PathType Leaf) -or (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -ine $Config.SevenZipDllSha256) { throw 'Trusted 7z DLL missing or digest mismatch' }
    $listing = @(& $Config.SevenZipPath l -slt -ba -- $Archive 2>&1)
    if ($LASTEXITCODE -ne 0) { throw '7z listing failed' }
    $entries = @(); $entry = @{}
    foreach ($line in $listing) {
        if ([string]::IsNullOrWhiteSpace($line)) { if ($entry.Count) { $entries += $entry; $entry = @{} }; continue }
        if ($line -match '^([^=]+) = (.*)$') { $entry[$matches[1].Trim()] = $matches[2] }
    }
    if ($entry.Count) { $entries += $entry }
    if ($entries.Count -eq 0 -or $entries.Count -gt [long]$Config.MaxArchiveEntries) { throw 'Archive entry count outside limits' }
    $seen = @{}; $total = 0L
    foreach ($item in $entries) {
        if (-not $item.ContainsKey('Path') -or -not $item.ContainsKey('Size')) { throw 'Unrecognized 7z listing' }
        $name = $item.Path.Replace('/','\')
        if ($name -match '(^[\\/]|:|[\x00-\x1f]|(^|\\)\.\.?($|\\)|[<>"|?*]|(^|\\)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|\\|$)|[ .](\\|$))' -or [IO.Path]::IsPathRooted($name)) { throw "Unsafe archive path: $name" }
        if ($seen.ContainsKey($name)) { throw 'Duplicate archive path' }; $seen[$name] = $true
        if (($item.ContainsKey('Symbolic Link') -and -not [string]::IsNullOrWhiteSpace($item['Symbolic Link'])) -or ($item.ContainsKey('Hard Link') -and -not [string]::IsNullOrWhiteSpace($item['Hard Link'])) -or ($item.ContainsKey('Attributes') -and $item.Attributes -match '(?i)(^|\s)L|reparse')) { throw 'Archive links are prohibited' }
        $size = 0L; if (-not [long]::TryParse($item.Size,[ref]$size) -or $size -lt 0 -or $size -gt ([long]$Config.MaxExtractedBytes - $total)) { throw 'Archive extracted size exceeds limit' }; $total += $size
    }
    if (Test-Path -LiteralPath $Destination) { throw 'Extraction destination already exists' }
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    & $Config.SevenZipPath x -y "-o$Destination" -- $Archive | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '7z extraction failed' }
    $actual = Get-HtkkManifest -Root $Destination
    if (@($actual).Count -gt [long]$Config.MaxArchiveEntries -or (($actual | Measure-Object -Property Length -Sum).Sum -gt [long]$Config.MaxExtractedBytes)) { throw 'Extracted files exceed configured limits' }
}

function Get-HtkkManifest {
    param([Parameter(Mandatory=$true)][string]$Root)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) { throw "Directory not found: $rootFull" }
    $rootItem = Get-Item -LiteralPath $rootFull -Force
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse points are prohibited' }
    $pending = New-Object 'System.Collections.Generic.Stack[string]'; $pending.Push($rootFull)
    $result = New-Object 'System.Collections.Generic.List[object]'
    while ($pending.Count) {
        $dir = $pending.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $dir -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point prohibited: $($item.FullName)" }
            $relative = $item.FullName.Substring($rootFull.Length + 1)
            if ($item.PSIsContainer) { $result.Add([pscustomobject]@{ Path=$relative; Kind='Directory'; Length=0L; Hash='' }); $pending.Push($item.FullName) }
            else { $result.Add([pscustomobject]@{ Path=$relative; Kind='File'; Length=$item.Length; Hash=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash }) }
        }
    }
    return @($result | Sort-Object Path)
}

function Compare-HtkkManifest {
    param([object[]]$Expected,[object[]]$Actual)
    $a = @($Expected | Sort-Object Path); $b = @($Actual | Sort-Object Path)
    if ($a.Count -ne $b.Count) { throw 'Manifest entry count mismatch' }
    for ($i=0; $i -lt $a.Count; $i++) { if ($a[$i].Path -cne $b[$i].Path -or $a[$i].Kind -cne $b[$i].Kind -or $a[$i].Length -ne $b[$i].Length -or $a[$i].Hash -cne $b[$i].Hash) { throw "Manifest mismatch: $($a[$i].Path)" } }
}

function Copy-HtkkTree {
    param([string]$Source,[string]$Destination,[object[]]$Manifest)
    if (Test-Path -LiteralPath $Destination) { throw "Destination already exists: $Destination" }
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($entry in $Manifest) {
        $target = Join-Path $Destination $entry.Path
        if ($entry.Kind -eq 'Directory') { [IO.Directory]::CreateDirectory($target) | Out-Null }
        else { [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null; [IO.File]::Copy((Join-Path $Source $entry.Path),$target,$false) }
    }
}

function Backup-HtkkInstallation {
    param([Parameter(Mandatory=$true)][hashtable]$Config)
    $manifest = @(Get-HtkkManifest -Root $Config.InstallDirectory)
    foreach ($dataPath in $Config.DataPaths) { if (-not (Test-Path -LiteralPath $dataPath)) { throw "Configured data path missing: $dataPath" } }
    Copy-HtkkTree -Source $Config.InstallDirectory -Destination $Config.BackupDirectory -Manifest $manifest
    Compare-HtkkManifest -Expected $manifest -Actual @(Get-HtkkManifest -Root $Config.BackupDirectory)
    Compare-HtkkManifest -Expected $manifest -Actual @(Get-HtkkManifest -Root $Config.InstallDirectory)
    Copy-HtkkTree -Source $Config.BackupDirectory -Destination $Config.RestoreVerificationDirectory -Manifest $manifest
    Compare-HtkkManifest -Expected $manifest -Actual @(Get-HtkkManifest -Root $Config.RestoreVerificationDirectory)
    $manifestPath = $Config.BackupDirectory + '.manifest.json'
    if (Test-Path -LiteralPath $manifestPath) { throw 'Manifest destination already exists' }
    $json = ConvertTo-Json -InputObject @($manifest) -Depth 4
    [IO.File]::WriteAllText($manifestPath,$json,(New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Backup=$Config.BackupDirectory; RestoreVerification=$Config.RestoreVerificationDirectory; Manifest=$manifestPath }
}

function Get-HtkkInstalledVersion {
    param([hashtable]$Config)
    if (-not (Test-Path -LiteralPath $Config.ReleaseIndicatorPath -PathType Leaf)) { throw 'Release indicator missing' }
    $xml = New-Object System.Xml.XmlDocument
    $xml.XmlResolver = $null
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $reader = [System.Xml.XmlReader]::Create($Config.ReleaseIndicatorPath,$settings)
    try { $xml.Load($reader) } finally { $reader.Dispose() }
    $nodes = @($xml.SelectNodes('/configuration/appSettings/add[@key="VERSION"]'))
    if ($nodes.Count -ne 1) { throw 'Release version missing or ambiguous' }
    $version = $null
    if (-not [version]::TryParse($nodes[0].GetAttribute('value'),[ref]$version) -or $version.Build -lt 0) { throw 'Invalid release version' }
    return $version
}

function Assert-HtkkNotRunning {
    param([hashtable]$Config)
    foreach ($name in $Config.ProcessNames) { if (@(Get-Process -Name $name -ErrorAction SilentlyContinue).Count -gt 0) { throw "Application process running: $name" } }
}

function Assert-HtkkSignatures {
    param([hashtable]$Config,[string]$Directory)
    $msi = @(Get-ChildItem -LiteralPath $Directory -Filter '*.msi' -File -Recurse)
    $setup = @(Get-ChildItem -LiteralPath $Directory -Filter 'setup.exe' -File -Recurse)
    if ($msi.Count -ne 1 -or $setup.Count -ne 1) { throw 'Expected exactly one MSI and one setup.exe' }
    foreach ($file in @($msi[0],$setup[0])) {
        $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
        if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or @($Config.PublisherThumbprints | Where-Object { $_ -ieq $signature.SignerCertificate.Thumbprint }).Count -eq 0) { throw "Installer signature or publisher not trusted: $($file.Name)" }
    }
    return $msi[0].FullName
}

function Assert-HtkkElevation {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator elevation is required' }
}

function Invoke-HtkkUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][hashtable]$Config)
    $mutex = $null; $locked = $false; $stage = 'Configuration'
    try {
        Assert-HtkkConfig $Config
        Add-Type -AssemblyName System.Net.Http
        $mutex = New-Object System.Threading.Mutex($false,'Global\HtkkUpdater')
        try { $locked = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another updater is running' }
        $stage = 'ProcessCheck'; Assert-HtkkNotRunning $Config
        $stage = 'InstalledVersion'; $installed = Get-HtkkInstalledVersion $Config
        $stage = 'Discovery'; $release = Get-HtkkRelease $Config
        if ($installed -ge $release.Version) { return [pscustomobject]@{ Status='Current'; InstalledVersion=$installed.ToString(); LatestVersion=$release.Version.ToString(); InstallerValidated=$false } }
        $stage = 'Elevation'; Assert-HtkkElevation
        $stage = 'Download'
        if (Test-Path -LiteralPath $Config.WorkDirectory) { throw 'WorkDirectory must not already exist' }
        [IO.Directory]::CreateDirectory($Config.WorkDirectory) | Out-Null
        $archive = Join-Path $Config.WorkDirectory 'release.archive'
        Save-HtkkDownload -Uri $release.Uri -Path $archive -MaxBytes ([long]$Config.MaxArchiveBytes)
        $stage = 'Extraction'; $extracted = Join-Path $Config.WorkDirectory 'extracted'; Expand-HtkkArchive -Config $Config -Archive $archive -Destination $extracted
        $stage = 'Signature'; $msi = Assert-HtkkSignatures -Config $Config -Directory $extracted
        $stage = 'Backup'; Assert-HtkkNotRunning $Config; $backup = Backup-HtkkInstallation $Config
        $stage = 'Uninstall'; Assert-HtkkNotRunning $Config
        $registrations = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.PSObject.Properties['InstallLocation'] -and $_.DisplayName -eq 'HTKK' -and $_.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$' -and $_.InstallLocation -and [IO.Path]::GetFullPath($_.InstallLocation).TrimEnd('\') -ieq [IO.Path]::GetFullPath($Config.InstallDirectory).TrimEnd('\') })
        if ($registrations.Count -ne 1) { throw 'Expected exactly one HTKK MSI registration at the configured installation directory' }
        $uninstallLog = Join-Path $Config.WorkDirectory 'uninstall.log'
        $uninstall = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList @('/x',$registrations[0].PSChildName,'/qn','/norestart','/l*v',('"'+$uninstallLog+'"')) -Wait -PassThru
        if ($uninstall.ExitCode -eq 3010) { throw "Uninstall requires reboot; installation not attempted; backup: $($backup.Backup); log: $uninstallLog" }
        if ($uninstall.ExitCode -ne 0) { throw "Uninstall failed with exit code $($uninstall.ExitCode); backup: $($backup.Backup); log: $uninstallLog" }
        $stage = 'Install'; Assert-HtkkNotRunning $Config
        $log = Join-Path $Config.WorkDirectory 'msiexec.log'
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList @('/i',('"'+$msi+'"'),'/qn','/norestart','/l*v',('"'+$log+'"')) -Wait -PassThru
        if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) { throw "MSI failed with exit code $($process.ExitCode); backup: $($backup.Backup); log: $log" }
        if ($process.ExitCode -eq 3010) { return [pscustomobject]@{ Status='RebootRequired'; InstalledVersion=$null; LatestVersion=$release.Version.ToString(); Backup=$backup; Log=$log; RebootRequired=$true; InstallerValidated=$false } }
        $stage = 'Verification'; $actual = Get-HtkkInstalledVersion $Config
        if ($actual -ne $release.Version) { throw "Installed version $actual does not match expected $($release.Version); backup: $($backup.Backup); log: $log" }
        return [pscustomobject]@{ Status='Updated'; InstalledVersion=$actual.ToString(); LatestVersion=$release.Version.ToString(); Backup=$backup; Log=$log; RebootRequired=($process.ExitCode -eq 3010); InstallerValidated=$true }
    } catch { return [pscustomobject]@{ Status='Error'; Stage=$stage; Error=$_.Exception.Message; Backup=$Config.BackupDirectory; Work=$Config.WorkDirectory; InstallerValidated=$false } }
    finally { if ($locked) { $mutex.ReleaseMutex() }; if ($null -ne $mutex) { $mutex.Dispose() } }
}

Export-ModuleMember -Function Assert-HtkkConfig,Get-HtkkRelease,Save-HtkkDownload,Expand-HtkkArchive,Get-HtkkManifest,Compare-HtkkManifest,Copy-HtkkTree,Backup-HtkkInstallation,Get-HtkkInstalledVersion,Assert-HtkkNotRunning,Assert-HtkkSignatures,Assert-HtkkElevation,Invoke-HtkkUpdate
