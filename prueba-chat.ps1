#Requires -Version 5.1
<#
Un chat INVENTADO (tipo WhatsApp, 1920x1080) para probar, sin tocar los chats
del usuario:
  - "ultimo mensaje que me envio Irene": el de la IZQUIERDA mas abajo, no uno
    suyo (retos del 2026-09-23: leyo uno que habia enviado el).
  - "donde esta el boton de enviar": en esta imagen no hay ninguno; no debe
    describir donde estaria.

    .\prueba-chat.ps1
#>
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Type -AssemblyName System.Drawing
$img = New-Object Drawing.Bitmap 1920, 1080
$g = [Drawing.Graphics]::FromImage($img)
$g.TextRenderingHint = 'AntiAliasGridFit'
$g.Clear([Drawing.Color]::FromArgb(11, 20, 26))
$fuente = New-Object Drawing.Font 'Segoe UI', 17
$hora = New-Object Drawing.Font 'Segoe UI', 11
$blanco = [Drawing.Brushes]::WhiteSmoke
$g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(32, 44, 51))), 0, 0, 1920, 70)
$g.DrawString('Irene', (New-Object Drawing.Font 'Segoe UI', 20, ([Drawing.FontStyle]::Bold)), $blanco, 90, 18)
$mensajes = @(
    @('izq', '¿Vienes a la cena del viernes?', '13:02'),
    @('der', 'Sí, llego a las ocho', '13:03'),
    @('izq', 'Perfecto, trae el postre', '13:05'),
    @('der', 'Hecho, llevo tiramisú', '13:06')
)
$y = 140
foreach ($m in $mensajes) {
    $w = [int]$g.MeasureString($m[1], $fuente).Width + 90
    $x = if ($m[0] -eq 'izq') { 60 } else { 1920 - 60 - $w }
    $color = if ($m[0] -eq 'izq') { [Drawing.Color]::FromArgb(32, 44, 51) } else { [Drawing.Color]::FromArgb(0, 92, 75) }
    $g.FillRectangle((New-Object Drawing.SolidBrush $color), $x, $y, $w, 60)
    $g.DrawString($m[1], $fuente, $blanco, $x + 14, $y + 14)
    $g.DrawString($m[2], $hora, [Drawing.Brushes]::Silver, $x + $w - 50, $y + 38)
    $y += 100
}
$g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(32, 44, 51))), 0, 1000, 1920, 80)
$g.DrawString('Escribe un mensaje', $fuente, [Drawing.Brushes]::Gray, 90, 1025)
$g.Dispose()
$png = Join-Path $env:TEMP 'ojo-prueba-chat.png'
$img.Save($png, [Drawing.Imaging.ImageFormat]::Png); $img.Dispose()

$fallos = @()
$ErrorActionPreference = 'Continue'
$null = & "$raiz\ojo.ps1" -Pregunta '¿Cuál fue el último mensaje que me envió Irene?' -Imagen $png -Voz '' -Segundos 0 *>&1
$m1 = [IO.File]::ReadAllText("$raiz\ultima-medida.json", [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
"ultimo de Irene -> $($m1.dijo)"
if ($m1.dijo -notmatch '(?i)postre' -or $m1.dijo -match '(?i)tiramis') { $fallos += "ultimo de Irene: '$($m1.dijo)' (tocaba 'Perfecto, trae el postre')" }

$null = & "$raiz\ojo.ps1" -Pregunta '¿Dónde está el botón de enviar?' -Imagen $png -Voz '' -Segundos 0 *>&1
$m2 = [IO.File]::ReadAllText("$raiz\ultima-medida.json", [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
"boton de enviar -> $($m2.dijo)  [$($m2.via)]"
if ($m2.dijo -match '(?i)\b(derecha|izquierda|arriba|abajo|esquina)\b' -and -not $m2.senalo) { $fallos += "boton de enviar: describe un sitio sin senalar: '$($m2.dijo)'" }

if ($fallos) { Write-Host "`nFALLA:`n  $($fallos -join "`n  ")" -ForegroundColor Red; exit 2 }
Write-Host "`n2 comprobaciones OK" -ForegroundColor Green
