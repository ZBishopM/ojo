#Requires -Version 5.1
<#
Congela la pantalla REAL para banco-pantalla: los dos monitores a tamaño
nativo y, en el mismo instante, la verdad sacada de fuentes que NO son el OCR
(si la verdad saliera del OCR, la prueba se daría la razón a sí misma):

  - hora del sistema                 (el reloj de la barra)
  - RAM %, VRAM usada, temperatura   (lo que pinta la barra; de CIM y nvidia-smi)
  - controles de UI Automation       (rectángulos exactos) de cada ventana visible

Todo va a escenas\reales\<fecha>\ (en .gitignore: es tu pantalla).

    .\congelar-escena.ps1
#>
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Type -AssemblyName System.Drawing
$dir = Join-Path $raiz ("escenas\reales\{0:yyyyMMdd-HHmmss}" -f (Get-Date))
New-Item -ItemType Directory -Force $dir | Out-Null

# 1. La imagen de todo el escritorio y los hechos, lo más juntos posible.
$todo = Join-Path $env:TEMP 'ojo-congelar.bmp'
& "$raiz\captura\target\release\ojo-captura.exe" --todo --nativa $todo | Out-Null
$ahora = Get-Date
$so = Get-CimInstance Win32_OperatingSystem
$g = (& nvidia-smi --query-gpu=memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits) -split ',\s*'
$hechos = [ordered]@{
    hora      = $ahora.ToString('HH:mm')
    ram_pct   = [math]::Round(100 * (1 - $so.FreePhysicalMemory / $so.TotalVisibleMemorySize))
    vram_gb   = [math]::Round([int]$g[0] / 1024, 1)
    vram_tot  = [math]::Round([int]$g[1] / 1024)
    gpu_temp  = [int]$g[2]
}

# 2. Monitores y ventanas visibles, de GlazeWM (recorrido recursivo del árbol).
$mons = ((& glazewm query monitors) -join "`n" | ConvertFrom-Json).data.monitors
function Ventanas($nodo) {
    foreach ($c in @($nodo.children)) {
        if ($c.type -eq 'window') { $c } else { Ventanas $c }
    }
}
$uia = "$raiz\uia\target\release\ojo-uia.exe"
$vx = [int](@($mons | ForEach-Object { $_.x }) | Measure-Object -Minimum).Minimum
$vy = [int](@($mons | ForEach-Object { $_.y }) | Measure-Object -Minimum).Minimum
$src = [Drawing.Image]::FromFile($todo)
$salida = @()
$i = 0
foreach ($m in $mons) {
    $i++
    $img = Join-Path $dir "monitor$i.png"
    $bmp = New-Object Drawing.Bitmap ([int]$m.width), ([int]$m.height)
    $gr = [Drawing.Graphics]::FromImage($bmp)
    $gr.DrawImage($src, (New-Object Drawing.Rectangle 0, 0, $m.width, $m.height), (New-Object Drawing.Rectangle ($m.x - $vx), ($m.y - $vy), $m.width, $m.height), 'Pixel')
    $gr.Dispose(); $bmp.Save($img, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()

    $ventanas = foreach ($ws in @($m.children | Where-Object isDisplayed)) {
        foreach ($v in @(Ventanas $ws | Where-Object { $_.state.type -in 'tiling', 'floating' -and $_.title })) {
            # Controles de ESA ventana, sin darle el foco (--ventana por título).
            $j = try { & $uia --max 80 --ventana $v.title 2>$null | ConvertFrom-Json } catch { $null }
            $ctl = @($j.controles | Where-Object { $_.nombre -and $_.nombre.Length -ge 3 -and $_.nombre.Length -le 40 -and $_.w -gt 0 -and $_.h -gt 0 })
            # Solo nombres únicos en la ventana: "señala X" tiene una respuesta.
            $unicos = @($ctl | Group-Object nombre | Where-Object Count -eq 1 | ForEach-Object { $_.Group[0] })
            [pscustomobject]@{
                proceso = $v.processName; titulo = $v.title
                controles = @($unicos | ForEach-Object { [pscustomobject]@{ n = $_.n; nombre = $_.nombre; tipo = $_.tipo; x = $_.x; y = $_.y; w = $_.w; h = $_.h
                    caja = @(($_.x - $_.w / 2), ($_.y - $_.h / 2), ($_.x + $_.w / 2), ($_.y + $_.h / 2)) } })
                # La lista tal cual la ve ojo.ps1 (para -Controles), con los repetidos.
                lista = @($ctl)
            }
        }
    }
    $salida += [pscustomobject]@{ imagen = "monitor$i.png"; ancho = $m.width; alto = $m.height; ventanas = @($ventanas) }
}
$src.Dispose(); Remove-Item $todo -EA SilentlyContinue
$verdad = [ordered]@{ fecha = $ahora.ToString('yyyy-MM-dd HH:mm:ss'); hechos = $hechos; monitores = @($salida) }
[IO.File]::WriteAllText((Join-Path $dir 'verdad.json'), ($verdad | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
"congelada en $dir"
$salida | ForEach-Object { "  $($_.imagen) $($_.ancho)x$($_.alto): " + ((@($_.ventanas) | ForEach-Object { "$($_.proceso) ($(@($_.controles).Count) controles)" }) -join ', ') }
