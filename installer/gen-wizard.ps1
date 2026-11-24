# Regenerates Inno wizard bitmaps (dark theme + real logo + wordmark).
# wizard.bmp 164x314 (left banner), wizard-small.bmp 55x55 (top-right).
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$out = $PSScriptRoot
$logo = [System.Drawing.Bitmap]::FromFile((Join-Path $out '..\launcher\assets\logo.png'))

# --- wizard.bmp (164x314): dark panel, centered logo + wordmark ---
$w = New-Object System.Drawing.Bitmap 164, 314
$g = [System.Drawing.Graphics]::FromImage($w)
$g.Clear([System.Drawing.Color]::FromArgb(26, 26, 30))
$g.SmoothingMode = 'AntiAlias'
$g.InterpolationMode = 'HighQualityBicubic'
$g.TextRenderingHint = 'AntiAlias'
$g.DrawImage($logo, (164 - 56) / 2, 60, 56, 56)
$font = New-Object System.Drawing.Font 'Segoe UI Semibold', 13
$sf = New-Object System.Drawing.StringFormat
$sf.Alignment = 'Center'
$g.DrawString('HTTK Updater', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 128, 164, 30), $sf)
$font2 = New-Object System.Drawing.Font 'Segoe UI', 8
$g.DrawString('Daily automatic updates', $font2, (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(160, 160, 170))), (New-Object System.Drawing.RectangleF 0, 158, 164, 20), $sf)
$w.Save((Join-Path $out 'assets\wizard.bmp'), [System.Drawing.Imaging.ImageFormat]::Bmp)

# --- wizard-small.bmp (55x55): dark square with logo ---
$s = New-Object System.Drawing.Bitmap 55, 55
$g2 = [System.Drawing.Graphics]::FromImage($s)
$g2.SmoothingMode = 'AntiAlias'
$g2.InterpolationMode = 'HighQualityBicubic'
$g2.Clear([System.Drawing.Color]::FromArgb(26, 26, 30))
$g2.DrawImage($logo, 10, 10, 34, 34)
$s.Save((Join-Path $out 'assets\wizard-small.bmp'), [System.Drawing.Imaging.ImageFormat]::Bmp)

$g.Dispose(); $g2.Dispose(); $logo.Dispose()
'BMPs regenerated'
