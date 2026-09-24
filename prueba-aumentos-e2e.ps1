#Requires -Version 5.1
<#
Elegir entre los tres aumentos de ARAM Mayhem DE PUNTA A PUNTA: la partida
falsa (API del 2999 con la muestra real de Mayhem, Sylas), la pantalla de
eleccion dibujada a 1080p y 1440p, y la pregunta de verdad a ojo.ps1.

  - Con la clasificacion de op.gg en cache: ojo.ps1 elige SIN modelo. Tiene
    que elegir la mejor clasificada de las tres, exacta.
  - -SinClasificacion: se aparta la cache de la build y decide el MODELO que
    haya en -Puerto con los aumentos leidos. Tiene que nombrar UNA de las tres,
    no inventarse otras y no dar porcentajes (politica de Riot).

    .\prueba-aumentos-e2e.ps1 [-SinClasificacion] [-Puerto 8099]
#>
param([switch]$SinClasificacion, [int]$Puerto = 8099, [string]$Nombre = 'e2e')
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$raiz\builds.ps1"
Add-Type -AssemblyName System.Drawing

$cat = Get-DDragon
$b = Get-Build 'Sylas' 'KIWI' $cat
$rank = @($b.ranking_aumentos | Where-Object { $_ })
if ($rank.Count -lt 100) { Write-Host "sin clasificacion de Sylas ($($rank.Count))" -ForegroundColor Red; exit 2 }
$cache = Archivo-Build 'Sylas' 'KIWI' $cat
$apartada = "$cache.apartada"

function Dibujar([string[]]$tres, [int]$W, [int]$H, [string]$ruta) {
    $k = $W / 1920.0
    $img = New-Object Drawing.Bitmap $W, $H
    $g = [Drawing.Graphics]::FromImage($img)
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.ScaleTransform($k, $k)
    $g.Clear([Drawing.Color]::FromArgb(12, 16, 24))
    $titulo = New-Object Drawing.Font 'Segoe UI', 22, ([Drawing.FontStyle]::Bold)
    $texto = New-Object Drawing.Font 'Segoe UI', 13
    for ($i = 0; $i -lt 3; $i++) {
        $x = 360 + $i * 420
        $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(28, 34, 48))), $x, 250, 380, 560)
        $g.DrawString($tres[$i], $titulo, (New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(240, 230, 210))), (New-Object Drawing.RectangleF ($x + 20), 540, 340, 90))
        $g.DrawString("$($cat.aumentos.($tres[$i]))", $texto, (New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(170, 170, 170))), (New-Object Drawing.RectangleF ($x + 20), 640, 340, 160))
    }
    $g.Dispose(); $img.Save($ruta, [Drawing.Imaging.ImageFormat]::Png); $img.Dispose()
}

$filas = @()
& "$raiz\prueba-lol\partida.ps1" -Empezar -Datos "$raiz\prueba-lol\muestra-aram-mayhem.json" | Out-Null
try {
    # Con el "juego" puesto el supervisor cambia el 8B por el modelo de partida:
    # si se pregunta durante el cambio, la conexion se corta. Se espera a que
    # el del puerto sea el de partida (sin vision) y conteste.
    if ($Puerto -eq 8099) {
        $t = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $ok = try { $p = Invoke-RestMethod "http://127.0.0.1:$Puerto/props" -TimeoutSec 2; -not $p.modalities.vision -and (Invoke-RestMethod "http://127.0.0.1:$Puerto/health" -TimeoutSec 2).status -eq 'ok' } catch { $false }
            if ($ok) { break }
            if ($t.Elapsed.TotalSeconds -gt 300) { throw 'el supervisor no puso el modelo de partida' }
            Start-Sleep -Milliseconds 500
        }
    }
    if ($SinClasificacion -and (Test-Path $cache)) { Move-Item $cache $apartada -Force }
    $dir = Join-Path $env:TEMP 'ojo-aumentos-e2e'; New-Item -ItemType Directory -Force $dir | Out-Null
    $juegos = @(@(3, 70, 130), @(95, 8, 150), @(120, 60, 25), @(40, 2, 88))
    foreach ($res in @(@(1920, 1080), @(2560, 1440))) {
        foreach ($p in $juegos) {
            $tres = @($p | ForEach-Object { $rank[$_] })
            $esperado = $rank[($p | Measure-Object -Minimum).Minimum]
            $png = Join-Path $dir ("{0}p-{1}.png" -f $res[1], ($p -join '-'))
            Dibujar $tres $res[0] $res[1] $png
            # ojo.ps1 baja la build en segundo plano si no la encuentra: se vuelve
            # a apartar antes de cada pregunta.
            if ($SinClasificacion -and (Test-Path $cache)) { Move-Item $cache $apartada -Force }
            $ErrorActionPreference = 'Continue'
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $null = & "$raiz\ojo.ps1" -Pregunta '¿Cuál de estos tres aumentos elijo?' -Imagen $png -Voz '' -Segundos 0 -Puerto $Puerto *>&1
            $ms = $sw.ElapsedMilliseconds
            $ErrorActionPreference = 'Stop'
            $m = [IO.File]::ReadAllText("$raiz\ultima-medida.json", [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
            $d = "$($m.dijo)"
            $nombrados = @($tres | Where-Object { $d -match [regex]::Escape($_) })
            $ok = if ($SinClasificacion) {
                # Decide el modelo: una de las tres, primero, sin porcentajes.
                $primero = @($tres | Sort-Object { $i = $d.IndexOf($_); if ($i -lt 0) { [int]::MaxValue } else { $i } })[0]
                # (el "X%" de la descripcion del aumento no es una tasa; una cifra con % si)
                $nombrados.Count -eq 1 -and $d -notmatch '\d\s*%|por ciento' -and $d.IndexOf($primero) -ge 0
            } else { $d -match "^Elige $([regex]::Escape($esperado))" }
            $filas += [pscustomobject]@{ res = "$($res[1])p"; tres = ($tres -join ' / '); tocaba = $(if ($SinClasificacion) { 'una de las tres, sin porcentajes' } else { $esperado })
                                         ok = $ok; ms = $ms; modelo = $m.modelo; dijo = $d }
            Write-Host ("{0} {1} {2,6} ms  [{3}]`n      dijo: {4}" -f $(if ($ok) { 'OK ' } else { 'MAL' }), "$($res[1])p", $ms, ($tres -join ' / '), $d)
        }
    }
} finally {
    if (Test-Path $apartada) { if (Test-Path $cache) { Remove-Item $apartada -Force } else { Move-Item $apartada $cache -Force } }
    & "$raiz\prueba-lol\partida.ps1" -Terminar | Out-Null
}
$res = [ordered]@{ nombre = $Nombre; fecha = Get-Date -Format 'yyyy-MM-dd HH:mm'; clasificacion = -not $SinClasificacion; puerto = $Puerto
    aciertos = "{0}/{1}" -f @($filas | Where-Object ok).Count, $filas.Count
    ms_p50 = (@($filas.ms | Sort-Object))[[int]($filas.Count / 2)]; filas = @($filas) }
$f = "$raiz\banco-aumentos.json"
$todas = @(if (Test-Path $f) { [IO.File]::ReadAllText($f, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json | ForEach-Object { $_ } }) + [pscustomobject]$res
[IO.File]::WriteAllText($f, (ConvertTo-Json @($todas) -Depth 5), [Text.UTF8Encoding]::new($false))
"$Nombre  $($res.aciertos)  p50 $($res.ms_p50) ms"
if (@($filas | Where-Object { -not $_.ok }).Count) { exit 1 }
