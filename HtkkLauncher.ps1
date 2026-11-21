param([switch]$CheckOnly, [string]$Screenshot)

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
$resultPath = Join-Path $env:ProgramData 'HtkkUpdater\last-result.json'

function Get-LauncherInfo {
    $info = [ordered]@{
        InstalledVersion = $null
        VersionError     = $null
        TaskState        = 'Not found'
        TaskError        = $null
        LastRun          = $null
        LastTaskResult   = $null
        Status           = $null
        Stage            = $null
        Error            = $null
        LatestVersion    = $null
        ResultAge        = $null
    }
    try { $info.InstalledVersion = Get-InstalledRelease $config } catch { $info.VersionError = $_.Exception.Message }
    try {
        $tasks = @(Get-ScheduledTask -TaskName 'HTKK Daily Updater' -ErrorAction Stop)
        if ($tasks.Count -eq 1) {
            $info.TaskState = [string]$tasks[0].State
            try {
                $t = $tasks[0] | Get-ScheduledTaskInfo -ErrorAction Stop
                $info.LastRun = $t.LastRunTime
                $info.LastTaskResult = $t.LastTaskResult
            } catch {}
        } elseif ($tasks.Count -gt 1) { $info.TaskState = 'Ambiguous' }
    } catch { $info.TaskError = $_.Exception.Message }
    try {
        if ([IO.File]::Exists($resultPath)) {
            $result = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json -ErrorAction Stop
            $info.Status = [string]$result.Status
            $info.Stage = [string]$result.Stage
            $info.Error = [string]$result.Error
            $info.LatestVersion = [string]$result.LatestVersion
            $info.ResultAge = (Get-Item -LiteralPath $resultPath).LastWriteTime
        }
    } catch {}
    return [pscustomobject]$info
}

# ---- palette ----
$bg       = [Drawing.Color]::FromArgb(13, 15, 19)
$card     = [Drawing.Color]::FromArgb(24, 27, 34)
$cardEdge = [Drawing.Color]::FromArgb(38, 42, 52)
$ink      = [Drawing.Color]::FromArgb(240, 242, 246)
$dim      = [Drawing.Color]::FromArgb(140, 148, 162)
$accent   = [Drawing.Color]::FromArgb(88, 101, 242)   # indigo
$accentHi = [Drawing.Color]::FromArgb(110, 122, 255)
$good     = [Drawing.Color]::FromArgb(52, 211, 153)   # emerald
$warn     = [Drawing.Color]::FromArgb(251, 191, 36)   # amber
$bad      = [Drawing.Color]::FromArgb(248, 113, 113)  # red

function New-RoundedPath([Drawing.Rectangle]$r, [int]$radius) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $p.AddArc($r.X, $r.Y, $d, $d, 180, 90)
    $p.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
    $p.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90)
    $p.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

$fontUi    = New-Object Drawing.Font('Segoe UI', 10)
$fontSmall = New-Object Drawing.Font('Segoe UI', 8.5)
$fontDim   = New-Object Drawing.Font('Segoe UI', 9)
$fontTitle = New-Object Drawing.Font('Segoe UI Semibold', 15)
$fontBig   = New-Object Drawing.Font('Segoe UI Semibold', 26)
$fontPill  = New-Object Drawing.Font('Segoe UI Semibold', 8.5)
$fontBtn   = New-Object Drawing.Font('Segoe UI Semibold', 9.5)

$form = New-Object Windows.Forms.Form
$form.Text = 'HTKK'
$form.ClientSize = New-Object Drawing.Size(440, 580)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = $bg
$form.ForeColor = $ink
try { $form.Icon = [Drawing.Icon]::ExtractAssociatedIcon($exe) } catch {}
if ($form.Icon -eq $null) { $form.Icon = [Drawing.SystemIcons]::Application }

# ---- header: accent dot + title ----
$header = New-Object Windows.Forms.Panel
$header.SetBounds(0, 0, 440, 84)
$header.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $g = $e.Graphics
    # gradient accent dot
    $dot = New-Object Drawing.Rectangle(28, 26, 34, 34)
    $brush = New-Object Drawing.Drawing2D.LinearGradientBrush($dot, $accentHi, $accent, 45)
    $g.FillEllipse($brush, $dot)
    $brush.Dispose()
    $sf = New-Object Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $wb = New-Object Drawing.SolidBrush([Drawing.Color]::White)
    $g.DrawString('H', $fontTitle, $wb, (New-Object Drawing.RectangleF(28, 26, 34, 34)), $sf)
    $wb.Dispose(); $sf.Dispose()
})
$form.Controls.Add($header)

$title = New-Object Windows.Forms.Label
$title.Text = 'HTKK Updater'
$title.Font = $fontTitle
$title.ForeColor = $ink
$title.SetBounds(74, 24, 300, 26)
$title.BackColor = [Drawing.Color]::Transparent
$header.Controls.Add($title)

$subtitle = New-Object Windows.Forms.Label
$subtitle.Text = 'Automatic updates, every day at 09:00'
$subtitle.Font = $fontDim
$subtitle.ForeColor = $dim
$subtitle.SetBounds(74, 50, 320, 18)
$subtitle.BackColor = [Drawing.Color]::Transparent
$header.Controls.Add($subtitle)

# ---- version hero card ----
$hero = New-Object Windows.Forms.Panel
$hero.SetBounds(24, 96, 392, 128)
$hero.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $rect = New-Object Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
    $path = New-RoundedPath $rect 14
    $b = New-Object Drawing.SolidBrush($card)
    $e.Graphics.FillPath($b, $path)
    $b.Dispose()
    $pen = New-Object Drawing.Pen($cardEdge, 1)
    $e.Graphics.DrawPath($pen, $path)
    $pen.Dispose(); $path.Dispose()
})
$form.Controls.Add($hero)

$vLabel = New-Object Windows.Forms.Label
$vLabel.Text = 'INSTALLED VERSION'
$vLabel.Font = $fontPill
$vLabel.ForeColor = $dim
$vLabel.SetBounds(20, 16, 200, 16)
$vLabel.BackColor = [Drawing.Color]::Transparent
$hero.Controls.Add($vLabel)

$vBig = New-Object Windows.Forms.Label
$vBig.Text = '...'
$vBig.Font = $fontBig
$vBig.ForeColor = $ink
$vBig.SetBounds(18, 32, 260, 52)
$vBig.BackColor = [Drawing.Color]::Transparent
$hero.Controls.Add($vBig)

$vLatest = New-Object Windows.Forms.Label
$vLatest.Text = ''
$vLatest.Font = $fontDim
$vLatest.ForeColor = $dim
$vLatest.SetBounds(20, 92, 350, 18)
$vLatest.BackColor = [Drawing.Color]::Transparent
$hero.Controls.Add($vLatest)

# status pill (right side of hero)
$pill = New-Object Windows.Forms.Panel
$pill.SetBounds(268, 20, 104, 30)
$pill.Tag = @{ Color = $dim; Text = 'Checking' }
$pill.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $c = $s.Tag.Color
    $rect = New-Object Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
    $path = New-RoundedPath $rect 15
    $fill = [Drawing.Color]::FromArgb(40, $c.R, $c.G, $c.B)
    $b = New-Object Drawing.SolidBrush($fill)
    $e.Graphics.FillPath($b, $path)
    $b.Dispose()
    $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(140, $c.R, $c.G, $c.B), 1)
    $e.Graphics.DrawPath($pen, $path)
    $pen.Dispose(); $path.Dispose()
    $tb = New-Object Drawing.SolidBrush($c)
    $e.Graphics.FillEllipse($tb, (New-Object Drawing.Rectangle(12, 11, 8, 8)))
    $sf = New-Object Drawing.StringFormat
    $sf.LineAlignment = 'Center'
    $e.Graphics.DrawString($s.Tag.Text, $fontPill, $tb, (New-Object Drawing.RectangleF(24, 0, ($s.Width - 26), $s.Height)), $sf)
    $tb.Dispose(); $sf.Dispose()
})
$hero.Controls.Add($pill)

# ---- detail card ----
$detail = New-Object Windows.Forms.Panel
$detail.SetBounds(24, 240, 392, 168)
$detail.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $rect = New-Object Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
    $path = New-RoundedPath $rect 14
    $b = New-Object Drawing.SolidBrush($card)
    $e.Graphics.FillPath($b, $path)
    $b.Dispose()
    $pen = New-Object Drawing.Pen($cardEdge, 1)
    $e.Graphics.DrawPath($pen, $path)
    $pen.Dispose(); $path.Dispose()
})
$form.Controls.Add($detail)

function New-DetailRow([string]$label, [int]$y) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $label.ToUpper()
    $l.Font = $fontSmall
    $l.ForeColor = $dim
    $l.SetBounds(20, $y, 130, 16)
    $l.BackColor = [Drawing.Color]::Transparent
    $detail.Controls.Add($l)
    $v = New-Object Windows.Forms.Label
    $v.Text = '...'
    $v.Font = $fontUi
    $v.ForeColor = $ink
    $v.SetBounds(20, ($y + 17), 352, 20)
    $v.BackColor = [Drawing.Color]::Transparent
    $v.AutoEllipsis = $true
    $detail.Controls.Add($v)
    return $v
}
$rowTask   = New-DetailRow 'Scheduled task'    16
$rowRun    = New-DetailRow 'Last update check' 62
$rowResult = New-DetailRow 'Updater result'    108

# ---- buttons ----
function New-UIButton([string]$text, [Drawing.Rectangle]$bounds, [bool]$primary) {
    $btn = New-Object Windows.Forms.Panel
    $btn.SetBounds($bounds.X, $bounds.Y, $bounds.Width, $bounds.Height)
    $btn.Cursor = [Windows.Forms.Cursors]::Hand
    $btn.Tag = @{ Text = $text; Primary = $primary; Hover = $false; Pressed = $false }
    $btn.Add_Paint({
        param($s, $e)
        $e.Graphics.SmoothingMode = 'AntiAlias'
        $t = $s.Tag
        if ($t.Primary) {
            $fill = if ($t.Pressed) { [Drawing.Color]::FromArgb(70, 82, 200) } elseif ($t.Hover) { $accentHi } else { $accent }
            $fg = [Drawing.Color]::White
        } else {
            $fill = if ($t.Pressed) { [Drawing.Color]::FromArgb(34, 38, 48) } elseif ($t.Hover) { [Drawing.Color]::FromArgb(30, 34, 43) } else { $card }
            $fg = $ink
        }
        $rect = New-Object Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
        $path = New-RoundedPath $rect 10
        $b = New-Object Drawing.SolidBrush($fill)
        $e.Graphics.FillPath($b, $path)
        $b.Dispose()
        if (-not $t.Primary) {
            $pen = New-Object Drawing.Pen($cardEdge, 1)
            $e.Graphics.DrawPath($pen, $path)
            $pen.Dispose()
        }
        $path.Dispose()
        $tb = New-Object Drawing.SolidBrush($fg)
        $sf = New-Object Drawing.StringFormat
        $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
        $e.Graphics.DrawString($t.Text, $fontBtn, $tb, (New-Object Drawing.RectangleF(0, 0, $s.Width, $s.Height)), $sf)
        $tb.Dispose(); $sf.Dispose()
    })
    $btn.Add_MouseEnter({ $this.Tag.Hover = $true; $this.Invalidate() })
    $btn.Add_MouseLeave({ $this.Tag.Hover = $false; $this.Tag.Pressed = $false; $this.Invalidate() })
    $btn.Add_MouseDown({ $this.Tag.Pressed = $true; $this.Invalidate() })
    $btn.Add_MouseUp({ $this.Tag.Pressed = $false; $this.Invalidate() })
    return $btn
}

$btnOpen = New-UIButton 'Open HTKK' (New-Object Drawing.Rectangle(24, 436, 188, 46)) $true
$btnOpen.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'HTKK executable not found.' }
        Start-Process -FilePath $exe -WorkingDirectory ([IO.Path]::GetDirectoryName($exe))
    } catch { [Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'HTKK', 'OK', 'Error') | Out-Null }
})
$form.Controls.Add($btnOpen)

$btnCheck = New-UIButton 'Check for updates' (New-Object Drawing.Rectangle(228, 436, 188, 46)) $false
$btnCheck.Add_Click({
    try {
        $tasks = @(Get-ScheduledTask -TaskName 'HTKK Daily Updater' -ErrorAction Stop)
        if ($tasks.Count -ne 1) { throw 'Expected exactly one scheduled updater task.' }
        $task = $tasks[0]
        if ($task.State -eq 'Disabled') { throw 'The scheduled updater is disabled.' }
        if ($task.State -eq 'Running') { throw 'The updater is already running.' }
        $task | Start-ScheduledTask -ErrorAction Stop
        $pill.Tag.Text = 'Running'; $pill.Tag.Color = $warn; $pill.Invalidate()
    } catch { [Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'HTKK', 'OK', 'Error') | Out-Null }
    finally { & $refresh }
})
$form.Controls.Add($btnCheck)

# ---- footer ----
$footer = New-Object Windows.Forms.Label
$footer.Text = 'github.com/cosmaxis/htkk-updater'
$footer.Font = $fontSmall
$footer.ForeColor = [Drawing.Color]::FromArgb(90, 96, 110)
$footer.TextAlign = 'MiddleCenter'
$footer.SetBounds(0, 546, 440, 20)
$footer.BackColor = [Drawing.Color]::Transparent
$form.Controls.Add($footer)

# ---- refresh ----
$refresh = {
    $i = Get-LauncherInfo
    if ($i.InstalledVersion) {
        $vBig.Text = "v$($i.InstalledVersion)"
    } else {
        $vBig.Text = 'Not found'
    }
    if ($i.LatestVersion) {
        $vLatest.Text = "Latest release: v$($i.LatestVersion)"
    } else {
        $vLatest.Text = ''
    }
    if ($i.TaskError) { $rowTask.Text = "Unavailable: $($i.TaskError)" }
    elseif ($i.TaskState -eq 'Not found') { $rowTask.Text = 'Not installed - run Install-HtkkUpdater.ps1' }
    else { $rowTask.Text = "$($i.TaskState) - daily at 09:00" }
    if ($i.LastRun) { $rowRun.Text = ([datetime]$i.LastRun).ToString('MMM d, yyyy HH:mm') }
    else { $rowRun.Text = 'Never' }
    if ($i.Error) { $rowResult.Text = "$($i.Status) - $($i.Error)"; $rowResult.ForeColor = $bad }
    elseif ($i.Status) { $rowResult.Text = "$($i.Status)" + $(if ($i.ResultAge) { " at $((([datetime]$i.ResultAge)).ToString('MMM d HH:mm'))" } else { '' }); $rowResult.ForeColor = $ink }
    else { $rowResult.Text = 'No runs recorded yet'; $rowResult.ForeColor = $ink }
    # pill
    if ($i.Error) { $pill.Tag.Text = 'Error'; $pill.Tag.Color = $bad }
    elseif ($i.TaskState -eq 'Running') { $pill.Tag.Text = 'Updating'; $pill.Tag.Color = $warn }
    elseif ($i.InstalledVersion -and $i.LatestVersion -and ([version]$i.LatestVersion -gt [version]$i.InstalledVersion)) { $pill.Tag.Text = 'Update ready'; $pill.Tag.Color = $warn }
    elseif ($i.Status -eq 'Current' -or $i.Status -eq 'Updated' -or $i.InstalledVersion) { $pill.Tag.Text = 'Up to date'; $pill.Tag.Color = $good }
    else { $pill.Tag.Text = 'Unknown'; $pill.Tag.Color = $dim }
    $pill.Invalidate()
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick($refresh)
$form.Add_Shown({ & $refresh; $timer.Start() })
$form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })
if ($Screenshot) {
    & $refresh
    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp.Save($Screenshot, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return
}
[void]$form.ShowDialog()
