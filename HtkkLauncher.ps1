param([switch]$CheckOnly, [string]$Screenshot, [string]$Lang)

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
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public static class Win32 {
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
}
public class BufPanel : Panel {
    public BufPanel() {
        this.DoubleBuffered = true;
        this.SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
    }
}
'@ -ReferencedAssemblies System.Windows.Forms, System.Drawing
$resultPath = Join-Path $env:ProgramData 'HtkkUpdater\last-result.json'

function Get-LauncherInfo {
    $info = [ordered]@{
        InstalledVersion = $null
        VersionError     = $null
        TaskState        = 'Not found'
        TaskTime         = $null
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
            if ($tasks[0].Triggers.Count -gt 0) {
                try { $info.TaskTime = ([datetime]$tasks[0].Triggers[0].StartBoundary).ToString('HH:mm') } catch {}
            }
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

# ---- preferences + i18n ----
$prefPath = Join-Path $env:LOCALAPPDATA 'HtkkUpdater\prefs.json'
$script:Lang = 'en'
try {
    if ([IO.File]::Exists($prefPath)) {
        $p = [IO.File]::ReadAllText($prefPath) | ConvertFrom-Json
        if ($p.lang -match '^(en|vi)$') { $script:Lang = $p.lang }
    }
} catch {}
if ($Lang -match '^(en|vi)$') { $script:Lang = $Lang }

function Save-Prefs {
    try {
        $dir = [IO.Path]::GetDirectoryName($prefPath)
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($prefPath, (@{ lang = $script:Lang } | ConvertTo-Json -Compress))
    } catch {}
}

$L = @{
    en = @{
        subtitle     = 'Automatic updates - every day at {0}'
        installed    = 'INSTALLED VERSION'
        latest       = 'Latest release: v{0}'
        task         = 'SCHEDULED TASK'
        lastRun      = 'LAST UPDATE CHECK'
        updResult    = 'UPDATER RESULT'
        settings     = 'SETTINGS'
        timeLabel    = 'Daily update time'
        apply        = 'Apply'
        open         = 'Open HTKK'
        check        = 'Check for updates'
        taskMissing  = 'Not installed - run Install-HtkkUpdater.ps1'
        taskFmt      = '{0} - daily at {1}'
        unavailable  = 'Unavailable: {0}'
        never        = 'Never'
        noRuns       = 'No runs recorded yet'
        notFound     = 'Not found'
        saved        = 'Saved - daily at {0}'
        saving       = 'Saving...'
        invalidTime  = 'Enter a valid time (HH:mm)'
        changeFail   = 'Could not change schedule: {0}'
        pillChecking = 'Checking'
        pillUpdating = 'Updating'
        pillReady    = 'Update ready'
        pillGood     = 'Up to date'
        pillError    = 'Error'
        pillUnknown  = 'Unknown'
        pillRunning  = 'Running'
        disabled     = 'The scheduled updater is disabled.'
        alreadyRun   = 'The updater is already running.'
        taskErr      = 'Expected exactly one scheduled updater task.'
        exeMissing   = 'HTKK executable not found.'
    }
    vi = @{
        subtitle     = 'Tự động cập nhật - mỗi ngày lúc {0}'
        installed    = 'PHIÊN BẢN ĐÃ CÀI'
        latest       = 'Bản mới nhất: v{0}'
        task         = 'TÁC VỤ ĐỊNH KỲ'
        lastRun      = 'KIỂM TRA LẦN CUỐI'
        updResult    = 'KẾT QUẢ CẬP NHẬT'
        settings     = 'CÀI ĐẶT'
        timeLabel    = 'Giờ cập nhật mỗi ngày'
        apply        = 'Áp dụng'
        open         = 'Mở HTKK'
        check        = 'Kiểm tra cập nhật'
        taskMissing  = 'Chưa cài đặt - hãy chạy Install-HtkkUpdater.ps1'
        taskFmt      = '{0} - mỗi ngày lúc {1}'
        unavailable  = 'Không khả dụng: {0}'
        never        = 'Chưa từng'
        noRuns       = 'Chưa có lượt chạy nào'
        notFound     = 'Không tìm thấy'
        saved        = 'Đã lưu - mỗi ngày lúc {0}'
        saving       = 'Đang lưu...'
        invalidTime  = 'Nhập giờ hợp lệ (HH:mm)'
        changeFail   = 'Không đổi được lịch: {0}'
        pillChecking = 'Đang kiểm tra'
        pillUpdating = 'Đang cập nhật'
        pillReady    = 'Có bản mới'
        pillGood     = 'Mới nhất'
        pillError    = 'Lỗi'
        pillUnknown  = 'Không rõ'
        pillRunning  = 'Đang chạy'
        disabled     = 'Tác vụ cập nhật đang tắt.'
        alreadyRun   = 'Trình cập nhật đang chạy.'
        taskErr      = 'Cần đúng một tác vụ cập nhật định kỳ.'
        exeMissing   = 'Không tìm thấy HTKK.exe.'
    }
}
function Str([string]$k) { return $L[$script:Lang][$k] }

# ---- palette: Apple HIG dark mode ----
$bg       = [Drawing.Color]::FromArgb(0, 0, 0)         # system background
$card     = [Drawing.Color]::FromArgb(28, 28, 30)      # secondary system background #1C1C1E
$cardEdge = [Drawing.Color]::FromArgb(56, 58, 60)      # separator #38383C
$ink      = [Drawing.Color]::FromArgb(245, 245, 247)   # primary label
$dim      = [Drawing.Color]::FromArgb(152, 152, 157)   # secondary label
$accent   = [Drawing.Color]::FromArgb(10, 132, 255)    # system blue (dark)
$accentHi = [Drawing.Color]::FromArgb(64, 156, 255)
$good     = [Drawing.Color]::FromArgb(48, 209, 88)     # system green (dark)
$warn     = [Drawing.Color]::FromArgb(255, 214, 10)    # system yellow (dark)
$bad      = [Drawing.Color]::FromArgb(255, 69, 58)     # system red (dark)

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
$fontBig   = New-Object Drawing.Font('Segoe UI Semilight', 27)
$fontPill  = New-Object Drawing.Font('Segoe UI Semibold', 8.5)
$fontBtn   = New-Object Drawing.Font('Segoe UI Semibold', 9.5)

$form = New-Object Windows.Forms.Form
$form.Text = 'HTKK'
$form.ClientSize = New-Object Drawing.Size(440, 652)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'None'
$form.BackColor = $bg
$form.ForeColor = $ink
$form.KeyPreview = $true
$form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } })
# rounded window: clip corners, draw hairline edge
$rp = New-RoundedPath (New-Object Drawing.Rectangle(0, 0, 440, 652)) 18
$form.Region = New-Object Drawing.Region($rp)
$rp.Dispose()
$form.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $rect = New-Object Drawing.Rectangle(0, 0, ($s.ClientSize.Width - 1), ($s.ClientSize.Height - 1))
    $path = New-RoundedPath $rect 18
    $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(80, 56, 58, 60), 1)
    $e.Graphics.DrawPath($pen, $path)
    $pen.Dispose(); $path.Dispose()
})
try { $form.Icon = [Drawing.Icon]::ExtractAssociatedIcon($exe) } catch {}
if ($form.Icon -eq $null) { $form.Icon = [Drawing.SystemIcons]::Application }

# drag anywhere on header / background to move
$startDrag = {
    param($s, $e)
    if ($e.Button -eq 'Left') {
        [Win32]::ReleaseCapture() | Out-Null
        [Win32]::SendMessage($form.Handle, 0xA1, [IntPtr]2, [IntPtr]0) | Out-Null
    }
}
$form.Add_MouseDown($startDrag)

# ---- header ----
$header = New-Object BufPanel
$header.SetBounds(0, 0, 440, 84)
$header.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $g = $e.Graphics
    # squircle app-icon
    $iconR = New-Object Drawing.Rectangle(28, 24, 38, 38)
    $iconPath = New-RoundedPath $iconR 11
    $brush = New-Object Drawing.Drawing2D.LinearGradientBrush($iconR, $accentHi, $accent, 45)
    $g.FillPath($brush, $iconPath)
    $brush.Dispose(); $iconPath.Dispose()
    $sf = New-Object Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $wb = New-Object Drawing.SolidBrush([Drawing.Color]::White)
    $g.DrawString('H', $fontTitle, $wb, (New-Object Drawing.RectangleF(28, 24, 38, 38)), $sf)
    $wb.Dispose(); $sf.Dispose()
})
$form.Controls.Add($header)
$header.Add_MouseDown($startDrag)

# window chrome: minimize + close, custom-drawn
function New-ChromeButton([Drawing.Rectangle]$b, [string]$kind) {
    $btn = New-Object BufPanel
    $btn.SetBounds($b.X, $b.Y, $b.Width, $b.Height)
    $btn.Cursor = [Windows.Forms.Cursors]::Hand
    $btn.Tag = @{ Kind = $kind; Hover = $false }
    $btn.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        if ($s.Tag.Hover) {
            $fill = if ($s.Tag.Kind -eq 'close') { $bad } else { [Drawing.Color]::FromArgb(58, 58, 60) }
            $rect = New-Object Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
            $path = New-RoundedPath $rect 13
            $fb = New-Object Drawing.SolidBrush($fill)
            $g.FillPath($fb, $path); $fb.Dispose(); $path.Dispose()
        }
        $pen = New-Object Drawing.Pen($ink, 1.8)
        $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
        $cx = [int]($s.Width / 2); $cy = [int]($s.Height / 2)
        if ($s.Tag.Kind -eq 'close') {
            $g.DrawLine($pen, ($cx - 4), ($cy - 4), ($cx + 4), ($cy + 4))
            $g.DrawLine($pen, ($cx + 4), ($cy - 4), ($cx - 4), ($cy + 4))
        } else {
            $g.DrawLine($pen, ($cx - 5), $cy, ($cx + 5), $cy)
        }
        $pen.Dispose()
    })
    $btn.Add_MouseEnter({ $this.Tag.Hover = $true; $this.Invalidate() })
    $btn.Add_MouseLeave({ $this.Tag.Hover = $false; $this.Invalidate() })
    return $btn
}
$btnMin = New-ChromeButton (New-Object Drawing.Rectangle(376, 8, 26, 26)) 'min'
$btnMin.Add_Click({ $form.WindowState = 'Minimized' })
$btnClose = New-ChromeButton (New-Object Drawing.Rectangle(408, 8, 26, 26)) 'close'
$btnClose.Add_Click({ $form.Close() })
$header.Controls.Add($btnMin)
$header.Controls.Add($btnClose)

$title = New-Object Windows.Forms.Label
$title.Text = 'HTKK Updater'
$title.Font = $fontTitle
$title.ForeColor = $ink
$title.SetBounds(74, 24, 260, 26)
$title.BackColor = [Drawing.Color]::Transparent
$title.Add_MouseDown($startDrag)
$header.Controls.Add($title)

$subtitle = New-Object Windows.Forms.Label
$subtitle.Font = $fontDim
$subtitle.ForeColor = $dim
$subtitle.SetBounds(74, 50, 270, 18)
$subtitle.AutoEllipsis = $true
$subtitle.BackColor = [Drawing.Color]::Transparent
$subtitle.Add_MouseDown($startDrag)
$header.Controls.Add($subtitle)

# language segmented toggle (EN | VI) - one click switches
$langSeg = New-Object BufPanel
$langSeg.SetBounds(352, 48, 64, 26)
$langSeg.Cursor = [Windows.Forms.Cursors]::Hand
$langSeg.Tag = @{ Lang = $script:Lang }
$langSeg.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $g = $e.Graphics
    $rect = New-Object Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
    $path = New-RoundedPath $rect 12
    $b = New-Object Drawing.SolidBrush($card)
    $g.FillPath($b, $path); $b.Dispose()
    $pen = New-Object Drawing.Pen($cardEdge, 1)
    $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
    $sf = New-Object Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $active = if ($s.Tag.Lang -eq 'en') { 'EN' } else { 'VI' }
    $inactive = if ($s.Tag.Lang -eq 'en') { 'VI' } else { 'EN' }
    $halfW = $s.Width / 2
    # active half = filled accent segment
    $actRect = New-Object Drawing.Rectangle(0, 0, [int]$halfW, ($s.Height - 1))
    $ap = New-RoundedPath $actRect 12
    $ab = New-Object Drawing.SolidBrush($accent)
    $g.FillPath($ab, $ap); $ab.Dispose(); $ap.Dispose()
    $wb = New-Object Drawing.SolidBrush([Drawing.Color]::White)
    $db = New-Object Drawing.SolidBrush($dim)
    $g.DrawString($active, $fontPill, $wb, (New-Object Drawing.RectangleF(0, 0, $halfW, $s.Height)), $sf)
    $g.DrawString($inactive, $fontPill, $db, (New-Object Drawing.RectangleF($halfW, 0, $halfW, $s.Height)), $sf)
    $wb.Dispose(); $db.Dispose(); $sf.Dispose()
})
$langSeg.Add_Click({ Switch-Language })
$header.Controls.Add($langSeg)

# ---- version hero card ----
$hero = New-Object BufPanel
$hero.SetBounds(24, 96, 392, 128)
$hero.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $rect = New-Object Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
    $path = New-RoundedPath $rect 16
    $b = New-Object Drawing.SolidBrush($card)
    $e.Graphics.FillPath($b, $path)
    $b.Dispose()
    $pen = New-Object Drawing.Pen($cardEdge, 1)
    $e.Graphics.DrawPath($pen, $path)
    $pen.Dispose(); $path.Dispose()
})
$form.Controls.Add($hero)

$vLabel = New-Object Windows.Forms.Label
$vLabel.Font = $fontPill
$vLabel.ForeColor = $dim
$vLabel.SetBounds(20, 16, 240, 16)
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

$pill = New-Object BufPanel
$pill.SetBounds(268, 20, 104, 30)
$pill.Tag = @{ Color = $dim; Text = '' }
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
    $e.Graphics.FillEllipse($tb, (New-Object Drawing.Rectangle(10, 11, 8, 8)))
    $sf = New-Object Drawing.StringFormat
    $sf.LineAlignment = 'Center'
    $e.Graphics.DrawString($s.Tag.Text, $fontPill, $tb, (New-Object Drawing.RectangleF(22, 0, ($s.Width - 24), $s.Height)), $sf)
    $tb.Dispose(); $sf.Dispose()
})
$hero.Controls.Add($pill)

# ---- detail card ----
$detail = New-Object BufPanel
$detail.SetBounds(24, 240, 392, 168)
$detail.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $rect = New-Object Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
    $path = New-RoundedPath $rect 16
    $b = New-Object Drawing.SolidBrush($card)
    $e.Graphics.FillPath($b, $path)
    $b.Dispose()
    $pen = New-Object Drawing.Pen($cardEdge, 1)
    $e.Graphics.DrawPath($pen, $path)
    $pen.Dispose(); $path.Dispose()
    # iOS grouped-list hairline separators between rows
    $sp = New-Object Drawing.Pen([Drawing.Color]::FromArgb(70, 56, 58, 60), 1)
    $e.Graphics.DrawLine($sp, 20, 56, ($s.Width - 20), 56)
    $e.Graphics.DrawLine($sp, 20, 102, ($s.Width - 20), 102)
    $sp.Dispose()
})
$form.Controls.Add($detail)

function New-DetailRow([int]$y) {
    $l = New-Object Windows.Forms.Label
    $l.Font = $fontSmall
    $l.ForeColor = $dim
    $l.SetBounds(20, $y, 170, 16)
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
    return [pscustomobject]@{ Label = $l; Value = $v }
}
$rowTask   = New-DetailRow 16
$rowRun    = New-DetailRow 62
$rowResult = New-DetailRow 108

# ---- settings card ----
$settingsCard = New-Object BufPanel
$settingsCard.SetBounds(24, 424, 392, 112)
$settingsCard.Add_Paint({
    param($s, $e)
    $e.Graphics.SmoothingMode = 'AntiAlias'
    $rect = New-Object Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
    $path = New-RoundedPath $rect 16
    $b = New-Object Drawing.SolidBrush($card)
    $e.Graphics.FillPath($b, $path)
    $b.Dispose()
    $pen = New-Object Drawing.Pen($cardEdge, 1)
    $e.Graphics.DrawPath($pen, $path)
    $pen.Dispose(); $path.Dispose()
})
$form.Controls.Add($settingsCard)

$lblSettings = New-Object Windows.Forms.Label
$lblSettings.Font = $fontSmall
$lblSettings.ForeColor = $dim
$lblSettings.SetBounds(20, 12, 200, 16)
$lblSettings.BackColor = [Drawing.Color]::Transparent
$settingsCard.Controls.Add($lblSettings)

$lblTime = New-Object Windows.Forms.Label
$lblTime.Font = $fontUi
$lblTime.ForeColor = $ink
$lblTime.SetBounds(20, 32, 220, 20)
$lblTime.BackColor = [Drawing.Color]::Transparent
$settingsCard.Controls.Add($lblTime)

# custom time field (fully drawn - no WinForms chrome)
$timeField = New-Object BufPanel
$timeField.SetBounds(20, 56, 132, 30)
$timeField.Cursor = [Windows.Forms.Cursors]::Hand
$timeField.Tag = @{ Value = '09:00'; Hover = $false }
$timeField.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
    $rect = New-Object Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
    $path = New-RoundedPath $rect 9
    $fill = if ($s.Tag.Hover) { [Drawing.Color]::FromArgb(54, 54, 56) } else { [Drawing.Color]::FromArgb(44, 44, 46) }
    $b = New-Object Drawing.SolidBrush($fill)
    $g.FillPath($b, $path); $b.Dispose()
    $pen = New-Object Drawing.Pen($cardEdge, 1)
    $g.DrawPath($pen, $path); $pen.Dispose(); $path.Dispose()
    $tb = New-Object Drawing.SolidBrush($ink)
    $sf = New-Object Drawing.StringFormat; $sf.LineAlignment = 'Center'
    $g.DrawString([string]$s.Tag.Value, $fontUi, $tb, (New-Object Drawing.RectangleF(12, 0, ($s.Width - 40), $s.Height)), $sf)
    $tb.Dispose(); $sf.Dispose()
    $gp = New-Object Drawing.Pen($dim, 1.8)
    $gp.StartCap = 'Round'; $gp.EndCap = 'Round'
    $cx = $s.Width - 18; $cy = [int]($s.Height / 2)
    $g.DrawLine($gp, ($cx - 4), ($cy - 2), $cx, ($cy + 2))
    $g.DrawLine($gp, $cx, ($cy + 2), ($cx + 4), ($cy - 2))
    $gp.Dispose()
})
$timeField.Add_MouseEnter({ $this.Tag.Hover = $true; $this.Invalidate() })
$timeField.Add_MouseLeave({ $this.Tag.Hover = $false; $this.Invalidate() })
$timeField.Add_Click({ Show-TimePopup })
$settingsCard.Controls.Add($timeField)

$script:popup = $null
function New-TimePopup {
    $cellW = 104; $cellH = 26; $gap = 4; $pad = 8
    $pw = ($pad * 2) + ($cellW * 2) + $gap
    $ph = ($pad * 2) + ($cellH * 12) + ($gap * 11)
    $popup = New-Object Windows.Forms.Form
    $popup.FormBorderStyle = 'None'
    $popup.ShowInTaskbar = $false
    $popup.TopMost = $true
    $popup.StartPosition = 'Manual'
    $popup.Size = New-Object Drawing.Size($pw, $ph)
    $popup.BackColor = [Drawing.Color]::FromArgb(36, 36, 38)
    $loc = $timeField.PointToScreen((New-Object Drawing.Point(0, ($timeField.Height + 6))))
    $scr = [Windows.Forms.Screen]::FromPoint($loc).WorkingArea
    if (($loc.Y + $ph) -gt $scr.Bottom) { $loc.Y = ($timeField.PointToScreen((New-Object Drawing.Point(0, 0)))).Y - $ph - 6 }
    if (($loc.X + $pw) -gt $scr.Right) { $loc.X = $scr.Right - $pw }
    $popup.Location = $loc
    $popup.Owner = $form
    $rpp = New-RoundedPath (New-Object Drawing.Rectangle(0, 0, $pw, $ph)) 12
    $popup.Region = New-Object Drawing.Region($rpp); $rpp.Dispose()
    $list = New-Object BufPanel
    $list.Dock = 'Fill'
    $list.Tag = @{ Hover = -1; CellW = $cellW; CellH = $cellH; Gap = $gap; Pad = $pad; Field = $timeField; Popup = $popup }
    $list.Add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $t = $s.Tag
        for ($c = 0; $c -lt 2; $c++) {
            for ($r = 0; $r -lt 12; $r++) {
                $idx = $c * 12 + $r
                $x = $t.Pad + $c * ($t.CellW + $t.Gap)
                $y = $t.Pad + $r * ($t.CellH + $t.Gap)
                $item = '{0:d2}:00' -f $idx
                $cur = ($item -eq $t.Field.Tag.Value)
                $rect = New-Object Drawing.Rectangle($x, $y, $t.CellW, $t.CellH)
                if ($cur -or ($t.Hover -eq $idx)) {
                    $fc = if ($cur) { $accent } else { [Drawing.Color]::FromArgb(56, 56, 58) }
                    $path = New-RoundedPath $rect 8
                    $fb = New-Object Drawing.SolidBrush($fc)
                    $g.FillPath($fb, $path); $fb.Dispose(); $path.Dispose()
                }
                $fg = if ($cur) { [Drawing.Color]::White } else { $ink }
                $tb = New-Object Drawing.SolidBrush($fg)
                $sf = New-Object Drawing.StringFormat
                $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
                $g.DrawString($item, $fontUi, $tb, (New-Object Drawing.RectangleF($x, $y, $t.CellW, $t.CellH)), $sf)
                $tb.Dispose(); $sf.Dispose()
            }
        }
        $pr = New-Object Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
        $pp = New-RoundedPath $pr 12
        $pen = New-Object Drawing.Pen($cardEdge, 1)
        $g.DrawPath($pen, $pp); $pen.Dispose(); $pp.Dispose()
    })
    $pick = {
        param($s, $e)
        $t = $s.Tag
        $c = [math]::Floor(($e.X - $t.Pad) / ($t.CellW + $t.Gap))
        $r = [math]::Floor(($e.Y - $t.Pad) / ($t.CellH + $t.Gap))
        if ($c -lt 0 -or $c -gt 1 -or $r -lt 0 -or $r -gt 11) { return -1 }
        if (($e.X - $t.Pad - $c * ($t.CellW + $t.Gap)) -gt $t.CellW) { return -1 }
        if (($e.Y - $t.Pad - $r * ($t.CellH + $t.Gap)) -gt $t.CellH) { return -1 }
        return [int]($c * 12 + $r)
    }
    $list.Add_MouseMove({ $i = & $pick $this $_; if ($i -ne $this.Tag.Hover) { $this.Tag.Hover = $i; $this.Invalidate() } })
    $list.Add_MouseLeave({ $this.Tag.Hover = -1; $this.Invalidate() })
    $list.Add_MouseClick({
        $i = & $pick $this $_
        if ($i -ge 0) {
            $this.Tag.Field.Tag.Value = '{0:d2}:00' -f $i
            $this.Tag.Field.Invalidate()
            $this.Tag.Popup.Close()
        }
    })
    $popup.Controls.Add($list)
    $popup.Add_Deactivate({ $popup.Close() })
    return $popup
}
function Show-TimePopup {
    if ($script:popup -ne $null -and -not $script:popup.IsDisposed) { $script:popup.Close(); return }
    $script:popup = New-TimePopup
    [void]$script:popup.Show($form)
}

$lblSave = New-Object Windows.Forms.Label
$lblSave.Font = $fontDim
$lblSave.ForeColor = $dim
$lblSave.SetBounds(20, 88, 352, 16)
$lblSave.AutoEllipsis = $true
$lblSave.BackColor = [Drawing.Color]::Transparent
$settingsCard.Controls.Add($lblSave)

# ---- buttons ----
function New-UIButton([string]$text, [Drawing.Rectangle]$bounds, [bool]$primary) {
    $btn = New-Object BufPanel
    $btn.SetBounds($bounds.X, $bounds.Y, $bounds.Width, $bounds.Height)
    $btn.Cursor = [Windows.Forms.Cursors]::Hand
    $btn.Tag = @{ Text = $text; Primary = $primary; Hover = $false; Pressed = $false }
    $btn.Add_Paint({
        param($s, $e)
        $e.Graphics.SmoothingMode = 'AntiAlias'
        $t = $s.Tag
        if ($t.Primary) {
            $fill = if ($t.Pressed) { [Drawing.Color]::FromArgb(8, 104, 200) } elseif ($t.Hover) { $accentHi } else { $accent }
            $fg = [Drawing.Color]::White
        } else {
            $fill = if ($t.Pressed) { [Drawing.Color]::FromArgb(34, 38, 48) } elseif ($t.Hover) { [Drawing.Color]::FromArgb(30, 34, 43) } else { $card }
            $fg = $ink
        }
        $rect = New-Object Drawing.Rectangle(0, 0, ($s.Width - 1), ($s.Height - 1))
        $path = New-RoundedPath $rect 12
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

$btnApply = New-UIButton 'Apply' (New-Object Drawing.Rectangle(266, 56, 106, 30)) $false
$settingsCard.Controls.Add($btnApply)

$btnOpen = New-UIButton '' (New-Object Drawing.Rectangle(24, 556, 188, 46)) $true
$btnOpen.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw (Str 'exeMissing') }
        Start-Process -FilePath $exe -WorkingDirectory ([IO.Path]::GetDirectoryName($exe))
    } catch { [Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'HTKK', 'OK', 'Error') | Out-Null }
})
$form.Controls.Add($btnOpen)

$btnCheck = New-UIButton '' (New-Object Drawing.Rectangle(228, 556, 188, 46)) $false
$btnCheck.Add_Click({
    try {
        $tasks = @(Get-ScheduledTask -TaskName 'HTKK Daily Updater' -ErrorAction Stop)
        if ($tasks.Count -ne 1) { throw (Str 'taskErr') }
        $task = $tasks[0]
        if ($task.State -eq 'Disabled') { throw (Str 'disabled') }
        if ($task.State -eq 'Running') { throw (Str 'alreadyRun') }
        $task | Start-ScheduledTask -ErrorAction Stop
        $pill.Tag.Text = Str 'pillRunning'; $pill.Tag.Color = $warn; $pill.Invalidate()
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
$footer.SetBounds(0, 618, 440, 20)
$footer.BackColor = [Drawing.Color]::Transparent
$form.Controls.Add($footer)

# ---- language switch (one click) ----
$script:timeInit = $false
function Switch-Language {
    $script:Lang = if ($script:Lang -eq 'en') { 'vi' } else { 'en' }
    $langSeg.Tag.Lang = $script:Lang
    Save-Prefs
    Update-Text
}
function Update-Text {
    $vLabel.Text = Str 'installed'
    $rowTask.Label.Text = Str 'task'
    $rowRun.Label.Text = Str 'lastRun'
    $rowResult.Label.Text = Str 'updResult'
    $lblSettings.Text = Str 'settings'
    $lblTime.Text = Str 'timeLabel'
    $btnApply.Tag.Text = Str 'apply'; $btnApply.Invalidate()
    $btnOpen.Tag.Text = Str 'open'; $btnOpen.Invalidate()
    $btnCheck.Tag.Text = Str 'check'; $btnCheck.Invalidate()
    $langSeg.Invalidate()
    & $refresh
}

# ---- refresh ----
$refresh = {
    $i = Get-LauncherInfo
    $timeFmt = '09:00'
    if ($i.TaskTime) { $timeFmt = $i.TaskTime }
    $subtitle.Text = (Str 'subtitle') -f $timeFmt
    if (-not $script:timeInit -and $i.TaskTime) { $timeField.Tag.Value = $i.TaskTime; $timeField.Invalidate(); $script:timeInit = $true }
    if ($i.InstalledVersion) {
        $vBig.Text = "v$($i.InstalledVersion)"
    } else {
        $vBig.Text = Str 'notFound'
    }
    if ($i.LatestVersion) {
        $vLatest.Text = (Str 'latest') -f $i.LatestVersion
    } else {
        $vLatest.Text = ''
    }
    if ($i.TaskError) { $rowTask.Value.Text = (Str 'unavailable') -f $i.TaskError }
    elseif ($i.TaskState -eq 'Not found') { $rowTask.Value.Text = Str 'taskMissing' }
    else { $rowTask.Value.Text = (Str 'taskFmt') -f $i.TaskState, $timeFmt }
    if ($i.LastRun) { $rowRun.Value.Text = ([datetime]$i.LastRun).ToString('MMM d, yyyy HH:mm') }
    else { $rowRun.Value.Text = Str 'never' }
    if ($i.Error) { $rowResult.Value.Text = "$($i.Status) - $($i.Error)"; $rowResult.Value.ForeColor = $bad }
    elseif ($i.Status) { $rowResult.Value.Text = "$($i.Status)" + $(if ($i.ResultAge) { " at $((([datetime]$i.ResultAge)).ToString('MMM d HH:mm'))" } else { '' }); $rowResult.Value.ForeColor = $ink }
    else { $rowResult.Value.Text = Str 'noRuns'; $rowResult.Value.ForeColor = $ink }
    if ($i.Error) { $pill.Tag.Text = Str 'pillError'; $pill.Tag.Color = $bad }
    elseif ($i.TaskState -eq 'Running') { $pill.Tag.Text = Str 'pillUpdating'; $pill.Tag.Color = $warn }
    elseif ($i.InstalledVersion -and $i.LatestVersion -and ([version]$i.LatestVersion -gt [version]$i.InstalledVersion)) { $pill.Tag.Text = Str 'pillReady'; $pill.Tag.Color = $warn }
    elseif ($i.Status -eq 'Current' -or $i.Status -eq 'Updated' -or $i.InstalledVersion) { $pill.Tag.Text = Str 'pillGood'; $pill.Tag.Color = $good }
    else { $pill.Tag.Text = Str 'pillUnknown'; $pill.Tag.Color = $dim }
    $pill.Invalidate()
}

# ---- apply schedule change (elevated via UAC when needed) ----
$btnApply.Add_Click({
    $t = ([string]$timeField.Tag.Value).Trim()
    if ($t -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') {
        $lblSave.ForeColor = $bad
        $lblSave.Text = Str 'invalidTime'
        return
    }
    if ($t -match '^\d:') { $t = "0$t" }
    $lblSave.ForeColor = $dim
    $lblSave.Text = Str 'saving'
    [Windows.Forms.Application]::DoEvents()
    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) {
            & schtasks /change /tn 'HTKK Daily Updater' /st $t | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "schtasks exit $LASTEXITCODE" }
        } else {
            $p = Start-Process -FilePath 'schtasks.exe' -ArgumentList '/change','/tn','HTKK Daily Updater','/st',$t -Verb RunAs -Wait -PassThru -ErrorAction Stop
            if ($p.ExitCode -ne 0) { throw "schtasks exit $($p.ExitCode)" }
        }
        $lblSave.ForeColor = $good
        $lblSave.Text = (Str 'saved') -f $t
        $script:timeInit = $false
    } catch {
        $lblSave.ForeColor = $bad
        $lblSave.Text = (Str 'changeFail') -f $_.Exception.Message
    }
    finally { & $refresh }
})

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick($refresh)
$form.Add_Shown({ Update-Text; $timer.Start() })
$form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })
if ($Screenshot) {
    Update-Text
    $form.Show(); [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 800
    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    [Win32]::PrintWindow($form.Handle, $hdc, 2) | Out-Null
    $g.ReleaseHdc($hdc); $g.Dispose()
    $bmp.Save($Screenshot, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $tp = New-TimePopup
    $tp.Show(); [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 200
    $pb = New-Object Drawing.Bitmap($tp.Width, $tp.Height)
    $g2 = [Drawing.Graphics]::FromImage($pb)
    $hdc2 = $g2.GetHdc()
    [Win32]::PrintWindow($tp.Handle, $hdc2, 2) | Out-Null
    $g2.ReleaseHdc($hdc2); $g2.Dispose()
    $pb.Save(($Screenshot -replace '\.png$', '-popup.png'), [Drawing.Imaging.ImageFormat]::Png)
    $pb.Dispose(); $tp.Dispose()
    return
}
[void]$form.ShowDialog()
