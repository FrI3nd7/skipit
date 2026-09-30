# Логотипы для README (тёмная и светлая тема GitHub): знак ▶▶ + «SkipIt».
#   powershell -ExecutionPolicy Bypass -File tools\make_readme_logo.ps1
# Результат: docs\logo-dark.png, docs\logo-light.png

Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Force (Join-Path $root 'docs') | Out-Null

function New-Logo([string]$path, [Drawing.Color]$textColor, [Drawing.Color]$subColor) {
    $W = 2172; $H = 724
    $bmp = New-Object Drawing.Bitmap $W, $H
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([Drawing.Color]::Transparent)

    $font = New-Object Drawing.Font 'Segoe UI Black', 230, ([Drawing.FontStyle]::Regular), ([Drawing.GraphicsUnit]::Pixel)
    $sub = New-Object Drawing.Font 'Segoe UI', 70, ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
    $fmt = [Drawing.StringFormat]::GenericTypographic

    # Знак: два одинаковых скруглённых треугольника с оранжевым градиентом (как иконка программы).
    $mh = 250.0; $tw = $mh * 0.72; $r = $mh * 0.09
    # Вся композиция (знак + надпись) по центру картинки.
    $total = 2 * $tw + 14 + 110 + $g.MeasureString('SkipIt', $font, 2000, $fmt).Width
    $x0 = ($W - $total) / 2; $y0 = ($H - $mh) / 2
    $grad = New-Object Drawing.Drawing2D.LinearGradientBrush (New-Object Drawing.PointF $x0, $y0), (New-Object Drawing.PointF ($x0 + 2 * $tw), ($y0 + $mh)),
        ([Drawing.Color]::FromArgb(255, 255, 154, 61)), ([Drawing.Color]::FromArgb(255, 255, 95, 26))
    $pen = New-Object Drawing.Pen $grad, ([single]($r * 2)); $pen.LineJoin = 'Round'
    foreach ($x in @($x0, ($x0 + $tw + 14))) {
        $pts = [Drawing.PointF[]]@(
            (New-Object Drawing.PointF ($x + $r), ($y0 + $r)),
            (New-Object Drawing.PointF ($x + $tw - $r), ($y0 + $mh / 2)),
            (New-Object Drawing.PointF ($x + $r), ($y0 + $mh - $r)))
        $g.FillPolygon($grad, $pts); $g.DrawPolygon($pen, $pts)
    }

    # Надписи.
    $tx = $x0 + 2 * $tw + 110
    $size = $g.MeasureString('SkipIt', $font, 2000, $fmt)
    # Надпись по центру знака по вертикали (у шрифта сверху запас под диакритику — поправка вверх).
    $ty = $y0 + ($mh - $size.Height) / 2 - 18
    $g.DrawString('SkipIt', $font, (New-Object Drawing.SolidBrush $textColor), $tx, $ty, $fmt)

    $g.Dispose()
    $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

New-Logo (Join-Path $root 'docs\logo-dark.png')  ([Drawing.Color]::FromArgb(255, 245, 245, 247)) ([Drawing.Color]::FromArgb(255, 160, 160, 170))
New-Logo (Join-Path $root 'docs\logo-light.png') ([Drawing.Color]::FromArgb(255, 12, 12, 14))    ([Drawing.Color]::FromArgb(255, 90, 90, 100))
Write-Host 'Готово: docs\logo-dark.png, docs\logo-light.png'
