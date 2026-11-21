param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'
$install = $null
foreach ($dir in @('C:\Program Files (x86)\HTKK','C:\Program Files\HTKK')) {
    if (Test-Path -LiteralPath (Join-Path $dir 'Project\HTKK.exe.config') -PathType Leaf) { $install = $dir; break }
}
if (-not $install) { $install = 'C:\Program Files (x86)\HTKK' }
$exe = Join-Path $install 'Project\HTKK.exe'
$config = Join-Path $install 'Project\HTKK.exe.config'
function Get-InstalledRelease([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'HTKK configuration not found.' }
    $xml = New-Object System.Xml.XmlDocument
    $xml.XmlResolver = $null
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $reader = [System.Xml.XmlReader]::Create($Path,$settings)
    try { $xml.Load($reader) } finally { $reader.Dispose() }
    $nodes = @($xml.SelectNodes('/configuration/appSettings/add[@key="VERSION"]'))
    if ($nodes.Count -ne 1) { throw 'HTKK release version is missing or ambiguous.' }
    $version = $null
    if (-not [version]::TryParse($nodes[0].GetAttribute('value'),[ref]$version) -or $version.Build -lt 0) { throw 'Invalid HTKK release version.' }
    return $version.ToString()
}
function Get-LauncherStatus([string]$ConfigPath,[string]$ResultPath) {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    try { $lines.Add("Installed HTKK release (live): $(Get-InstalledRelease $ConfigPath)") } catch { $lines.Add("Installed version unavailable: $($_.Exception.Message)") }
    try {
        $tasks = @(Get-ScheduledTask -TaskName 'HTKK Daily Updater' -ErrorAction Stop)
        if ($tasks.Count -eq 0) { $lines.Add('Scheduled task: not found') }
        elseif ($tasks.Count -ne 1) { $lines.Add('Scheduled task: ambiguous (multiple matching tasks)') }
        else {
            $task = $tasks[0]
            $lines.Add("Scheduled task: $($task.State) (path: $($task.TaskPath))")
            try {
                $info = $task | Get-ScheduledTaskInfo -ErrorAction Stop
                $lines.Add("Task last run: $($info.LastRunTime); last task result: $($info.LastTaskResult)")
            } catch { $lines.Add("Task information unavailable: $($_.Exception.Message)") }
        }
    } catch {
        if ($_.FullyQualifiedErrorId -match 'ObjectNotFound|NoMatching' -or $_.CategoryInfo.Category -eq 'ObjectNotFound') { $lines.Add('Scheduled task: not found') }
        else { $lines.Add("Scheduled task unavailable: $($_.Exception.Message)") }
    }
    try {
        if (-not [IO.File]::Exists($ResultPath)) { $lines.Add('Saved updater result: not found') }
        else {
            $file = Get-Item -LiteralPath $ResultPath -ErrorAction Stop
            $result = [IO.File]::ReadAllText($ResultPath) | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $result -or -not $result.PSObject.Properties['Status'] -or [string]::IsNullOrWhiteSpace([string]$result.Status)) { throw 'Missing status in result.' }
            $lines.Add("Saved updater result (file modified $($file.LastWriteTime); may be stale or from another run): $($result.Status)")
            foreach ($name in @('Stage','Error','InstalledVersion','LatestVersion')) {
                if ($result.PSObject.Properties[$name] -and $null -ne $result.$name -and [string]$result.$name -ne '') { $lines.Add("${name}: $($result.$name)") }
            }
        }
    } catch { $lines.Add("Saved updater result unavailable or invalid: $($_.Exception.Message)") }
    return ($lines -join "`r`n")
}
if ($CheckOnly) {
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'HTKK executable not found.' }
    Get-InstalledRelease $config
    return
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$form = New-Object Windows.Forms.Form
$form.Text = 'HTKK launcher'
$form.ClientSize = New-Object Drawing.Size(700,400)
$form.StartPosition = 'CenterScreen'
$label = New-Object Windows.Forms.TextBox
$label.Location = New-Object Drawing.Point(20,20)
$label.Size = New-Object Drawing.Size(660,300)
$label.Multiline = $true
$label.ReadOnly = $true
$label.ScrollBars = 'Vertical'
$form.Controls.Add($label)
$resultPath = Join-Path $env:ProgramData 'HtkkUpdater\last-result.json'
$refresh = { $label.Text = Get-LauncherStatus $config $resultPath }
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick($refresh)
$form.Add_Shown({ & $refresh; $timer.Start() })
$form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })
$open = New-Object Windows.Forms.Button
$open.Text = 'Open HTKK'
$open.Location = New-Object Drawing.Point(20,340)
$open.Size = New-Object Drawing.Size(130,35)
$open.Add_Click({ try { if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'HTKK executable not found.' }; Start-Process -FilePath $exe -WorkingDirectory ([IO.Path]::GetDirectoryName($exe)) } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'HTKK') | Out-Null } })
$form.Controls.Add($open)
$page = New-Object Windows.Forms.Button
$page.Text = 'Check for updates'
$page.Location = New-Object Drawing.Point(170,340)
$page.Size = New-Object Drawing.Size(140,35)
$page.Add_Click({ try { $tasks = @(Get-ScheduledTask -TaskName 'HTKK Daily Updater' -ErrorAction Stop); if ($tasks.Count -ne 1) { throw 'Expected exactly one scheduled updater task.' }; $task = $tasks[0]; if ($task.State -eq 'Disabled') { throw 'The scheduled updater is disabled.' }; if ($task.State -eq 'Running') { throw 'The updater is already running.' }; $task | Start-ScheduledTask -ErrorAction Stop; [Windows.Forms.MessageBox]::Show('Start requested. Check task state and saved result below; the saved result may be from an earlier run.','HTKK') | Out-Null } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'HTKK') | Out-Null } finally { & $refresh } })
$form.Controls.Add($page)
[void]$form.ShowDialog()
