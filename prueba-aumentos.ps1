#Requires -Version 5.1
<#
La eleccion de aumento de principio a fin, sin partida: dibuja la pantalla de
eleccion (tres cartas con nombre y descripcion, 1920x1080, fondo oscuro), la
lee con el OCR de Windows, busca los aumentos y elige con la clasificacion de
op.gg. Lo esperado sale de la propia clasificacion: el mejor puesto de los
tres, escogidos lejos entre si.

Necesita la build de Kayn en Mayhem en cache (builds.ps1 Kayn KIWI).

    .\prueba-aumentos.ps1
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\builds.ps1"
. "$PSScriptRoot\ocr.ps1"
Add-Type -AssemblyName System.Drawing

$cat = Get-DDragon
$b = Get-Build 'Kayn' 'KIWI' $cat
$rank = @($b.ranking_aumentos | Where-Object { $_ })
if ($rank.Count -lt 120) { Write-Host "sin clasificacion de Kayn ($($rank.Count))" -ForegroundColor Red; exit 2 }

$fallos = @()
# Tres juegos de cartas, en distinto orden: el mejor a la izquierda, en medio
# y a la derecha.
foreach ($puestos in @(5, 60, 110), @(90, 12, 140), @(100, 70, 30)) {
    $tres = @($puestos | ForEach-Object { $rank[$_] })
    $esperado = $rank[($puestos | Measure-Object -Minimum).Minimum]

    $img = New-Object Drawing.Bitmap 1920, 1080
    $g = [Drawing.Graphics]::FromImage($img)
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([Drawing.Color]::FromArgb(12, 16, 24))
    $titulo = New-Object Drawing.Font 'Segoe UI', 22, ([Drawing.FontStyle]::Bold)
    $texto = New-Object Drawing.Font 'Segoe UI', 13
    $oro = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(240, 230, 210))
    $gris = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(170, 170, 170))
    for ($i = 0; $i -lt 3; $i++) {
        $x = 360 + $i * 420
        $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(28, 34, 48))), $x, 250, 380, 560)
        # Titulo con sitio para dos lineas: los nombres largos se parten.
        $g.DrawString($tres[$i], $titulo, $oro, (New-Object Drawing.RectangleF ($x + 20), 540, 340, 90))
        $g.DrawString("$($cat.aumentos.($tres[$i]))", $texto, $gris, (New-Object Drawing.RectangleF ($x + 20), 640, 340, 160))
    }
    $g.Dispose()
    $ruta = Join-Path $env:TEMP 'ojo-prueba-eleccion.bmp'
    $img.Save($ruta, [Drawing.Imaging.ImageFormat]::Bmp); $img.Dispose()

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lineas = @(Leer-Texto $ruta)
    $msOcr = $sw.ElapsedMilliseconds
    $ofrecidos = @(Aumentos-En-Lineas $cat $lineas | Select-Object -First 3)
    $msBuscar = $sw.ElapsedMilliseconds - $msOcr
    $mejor = Elegir-Aumento $ofrecidos $rank
    $leidos = @($ofrecidos | ForEach-Object { ($_ -split ':')[0] })
    Write-Host ("{0} -> leidos: {1} | elige: {2} | OCR {3} ms, busqueda {4} ms" -f ($tres -join ' / '), ($leidos -join ' / '), (($mejor.texto -split ':')[0]), $msOcr, $msBuscar)
    foreach ($t in $tres) { if ($leidos -notcontains $t) { $fallos += "no leyo '$t'. El OCR dio: $($lineas -join ' | ')" } }
    if ((($mejor.texto -split ':')[0]) -ne $esperado) { $fallos += "eligio '$(($mejor.texto -split ':')[0])', tocaba '$esperado'" }
}

if ($fallos) { Write-Host "`nFALLA:`n  $($fallos -join "`n  ")" -ForegroundColor Red; exit 2 }
Write-Host "`n3 elecciones OK" -ForegroundColor Green
exit 0
