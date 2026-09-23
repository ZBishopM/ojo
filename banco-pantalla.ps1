#Requires -Version 5.1
<#
Banco de PANTALLA con el camino real: ojo.ps1 -Imagen (OCR a tamano real,
enganche al texto, verificador), contra la imagen sola al modelo (lo que media
banco-vision). Para encontrar donde falla leer y senalar, y probar arreglos.

Casos:
  - la captura de referencia y los 11 casos de banco-vision;
  - imagenes ADVERSARIALES dibujadas aqui con la verdad conocida: cifras
    confundibles (218/219, 138/183/813, 0/8, 1/7) en letra de 11-13 px, tema
    oscuro y claro, bajo contraste, una tabla densa, el mismo boton dos veces;
    cada una a 1920x1080, 2560x1440 y reducida a 1600x900.

    .\banco-pantalla.ps1 -Nombre base
    .\banco-pantalla.ps1 -Nombre base -SoloReal      (sin la imagen sola)
#>
param([Parameter(Mandatory)][string]$Nombre, [switch]$SoloReal, [int]$Puerto = 8099)
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
Add-Type -AssemblyName System.Drawing
$dir = Join-Path $env:TEMP 'ojo-banco-pantalla'
New-Item -ItemType Directory -Force $dir | Out-Null

# ---- Imagenes adversariales ---------------------------------------------------
function Fuente([float]$px, [string]$estilo = 'Regular') { New-Object Drawing.Font 'Segoe UI', $px, ([Drawing.FontStyle]$estilo), ([Drawing.GraphicsUnit]::Pixel) }
function Pincel($r, $g, $b) { New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb($r, $g, $b)) }

# Dibuja la escena en 1920x1080 "logicos" escalados a WxH; devuelve las cajas
# (normalizadas) de lo que luego se pide senalar.
function Dibujar-Escena([int]$W, [int]$H, [string]$ruta) {
    $k = $W / 1920.0
    $img = New-Object Drawing.Bitmap $W, $H
    $g = [Drawing.Graphics]::FromImage($img)
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $g.ScaleTransform($k, $k)
    $g.Clear([Drawing.Color]::FromArgb(24, 26, 32))
    $cajas = @{}
    $caja = { param($n, $x, $y, $w, $h) $cajas[$n] = @(($x / 1920.0), ($y / 1080.0), (($x + $w) / 1920.0), (($y + $h) / 1080.0)) }

    # Barra de estado de letra diminuta (11 px), tema oscuro: cifras confundibles.
    $g.FillRectangle((Pincel 16 17 22), 0, 0, 1920, 26)
    $f11 = Fuente 11
    $x = 1200
    foreach ($t in 'CPU 37%', 'RAM 58%', 'GPU 71°C', '218W', 'VRAM 10.6/12G') {
        $g.DrawString($t, $f11, (Pincel 200 200 205), $x, 6)
        $w = $g.MeasureString($t, $f11).Width
        & $caja $t $x 4 $w 18
        $x += $w + 22
    }

    # Tabla densa en tema CLARO: latencias que son permutaciones (138/183/813).
    $g.FillRectangle((Pincel 245 245 242), 80, 120, 760, 330)
    $f13 = Fuente 13; $f13b = Fuente 13 'Bold'
    $filas = @(@('Servidor', 'Latencia', 'Errores'), @('alfa', '138 ms', '0'), @('beta', '183 ms', '8'), @('gama', '813 ms', '3'), @('delta', '318 ms', '7'))
    $y = 140
    foreach ($fi in $filas) {
        $cx = 110
        foreach ($c in $fi) {
            $g.DrawString($c, $(if ($y -eq 140) { $f13b } else { $f13 }), (Pincel 30 30 35), $cx, $y)
            if ($c -eq 'Latencia') { & $caja 'Latencia' $cx $y ($g.MeasureString($c, $f13b).Width) 18 }
            $cx += 230
        }
        $y += 56
    }

    # Nota de BAJO CONTRASTE: gris sobre gris.
    $g.FillRectangle((Pincel 58 60 66), 960, 120, 560, 90)
    $g.DrawString('Código de acceso: 7169-B', (Fuente 15), (Pincel 96 98 104), 985, 150)

    # El mismo boton dos veces, en dos paneles.
    foreach ($p in @(@('izquierdo', 120), @('derecho', 1180))) {
        $g.FillRectangle((Pincel 36 39 46), $p[1], 560, 560, 300)
        $g.DrawString("Panel $($p[0])", (Fuente 16 'Bold'), (Pincel 220 220 225), $p[1] + 24, 580)
        $g.FillRectangle((Pincel 60 110 190), $p[1] + 380, 790, 150, 44)
        $g.DrawString('Guardar', (Fuente 15), (Pincel 255 255 255), $p[1] + 420, 800)
        & $caja "Guardar $($p[0])" ($p[1] + 380) 790 150 44
    }
    # Decimales con coma y unidades.
    $g.DrawString('Descarga: 1,87 GB de 7,81 GB', (Fuente 14), (Pincel 210 210 215), 960, 260)

    $g.Dispose()
    $img.Save($ruta, [Drawing.Imaging.ImageFormat]::Png); $img.Dispose()
    $cajas
}

$CASOS = @()
foreach ($res in @(@(1920, 1080, '1080p'), @(2560, 1440, '1440p'), @(1920, 1080, '900p'))) {
    $ruta = Join-Path $dir "escena-$($res[2]).png"
    $cajas = Dibujar-Escena $res[0] $res[1] $ruta
    if ($res[2] -eq '900p') {
        # Reducida a 1600x900: como un monitor mas pequeno.
        $src = [Drawing.Image]::FromFile($ruta)
        $red = New-Object Drawing.Bitmap 1600, 900
        $gr = [Drawing.Graphics]::FromImage($red); $gr.InterpolationMode = 'HighQualityBicubic'; $gr.DrawImage($src, 0, 0, 1600, 900); $gr.Dispose(); $src.Dispose()
        $ruta = Join-Path $dir 'escena-900p-red.png'; $red.Save($ruta, [Drawing.Imaging.ImageFormat]::Png); $red.Dispose()
    }
    $r = $res[2]
    $CASOS += @(
        @{ res = $r; img = $ruta; cat = 'cifra diminuta'; tipo = 'leer'; q = '¿Cuántos vatios marca la barra de arriba?'; esp = '\b218(?!\d)' }
        @{ res = $r; img = $ruta; cat = 'cifra diminuta'; tipo = 'leer'; q = '¿Qué temperatura marca la GPU en la barra de arriba?'; esp = '\b71\b' }
        @{ res = $r; img = $ruta; cat = 'tabla densa'; tipo = 'leer'; q = '¿Qué latencia tiene beta en la tabla?'; esp = '\b183\b' }
        @{ res = $r; img = $ruta; cat = 'tabla densa'; tipo = 'leer'; q = '¿Cuántos errores tiene delta en la tabla?'; esp = '\b7\b' }
        @{ res = $r; img = $ruta; cat = 'bajo contraste'; tipo = 'leer'; q = '¿Qué código de acceso pone en la nota gris?'; esp = '7169' }
        @{ res = $r; img = $ruta; cat = 'decimales'; tipo = 'leer'; q = '¿Cuánto lleva descargado según la pantalla?'; esp = '1[.,]87' }
        @{ res = $r; img = $ruta; cat = 'senalar texto'; tipo = 'senalar'; q = 'Señala donde pone Latencia'; caja = $cajas['Latencia'] }
        @{ res = $r; img = $ruta; cat = 'senalar texto'; tipo = 'senalar'; q = 'Señala donde la barra de arriba indica la RAM'; caja = $cajas['RAM 58%'] }
        @{ res = $r; img = $ruta; cat = 'ambiguo'; tipo = 'senalar'; q = 'Señala el botón Guardar del panel derecho'; caja = $cajas['Guardar derecho'] }
    )
}
# La captura de referencia y sus casos de banco-vision (cajas en px de 1280x720).
$ref = Join-Path $raiz 'escenas\captura-referencia.jpg'
$n = { param($c) @(($c[0] / 1280.0), ($c[1] / 720.0), ($c[2] / 1280.0), ($c[3] / 720.0)) }
$CASOS += @(
    @{ res = 'ref'; img = $ref; cat = 'referencia'; tipo = 'leer'; q = 'Que hora marca el reloj de la barra superior?'; esp = '12[:.]17' }
    @{ res = 'ref'; img = $ref; cat = 'referencia'; tipo = 'leer'; q = 'Cuantos vatios marca la barra superior?'; esp = '\b218(?!\d)' }
    @{ res = 'ref'; img = $ref; cat = 'referencia'; tipo = 'leer'; q = 'Que porcentaje de RAM indica la barra superior?'; esp = '45' }
    @{ res = 'ref'; img = $ref; cat = 'referencia'; tipo = 'leer'; q = 'Como se llama el archivo abierto en el editor de arriba a la izquierda?'; esp = 'test\.py' }
    @{ res = 'ref'; img = $ref; cat = 'referencia'; tipo = 'leer'; q = 'Que temperatura tiene la GPU segun la barra superior?'; esp = '47' }
    @{ res = 'ref'; img = $ref; cat = 'referencia'; tipo = 'senalar'; q = 'Senala el reloj de la barra superior.'; caja = (& $n @(622, 3, 656, 20)) }
    @{ res = 'ref'; img = $ref; cat = 'referencia'; tipo = 'senalar'; q = 'Senala donde la barra superior indica el consumo en vatios.'; caja = (& $n @(752, 3, 775, 20)) }
    @{ res = 'ref'; img = $ref; cat = 'referencia'; tipo = 'senalar'; q = 'Senala donde la barra superior indica el porcentaje de RAM.'; caja = (& $n @(905, 3, 943, 20)) }
    @{ res = 'ref'; img = $ref; cat = 'referencia'; tipo = 'senalar'; q = 'Senala la pestana del archivo test.py en el editor.'; caja = (& $n @(159, 51, 218, 70)) }
    @{ res = 'ref'; img = $ref; cat = 'referencia'; tipo = 'senalar'; q = "Senala donde pone 'Dejame ver'."; caja = (& $n @(588, 654, 692, 674)) }
)

# ---- Imagen sola: lo que media banco-vision ---------------------------------------
$fuenteOjo = [IO.File]::ReadAllText("$raiz\ojo.ps1")
$SISTEMA = [regex]::Match($fuenteOjo, "(?s)\`$SISTEMA = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
function Solo-Imagen($img, $q) {
    Add-Type -AssemblyName System.Drawing
    $src = [Drawing.Image]::FromFile($img)
    $k = [math]::Min(1.0, 1280.0 / [math]::Max($src.Width, $src.Height))
    $red = New-Object Drawing.Bitmap ([int]($src.Width * $k)), ([int]($src.Height * $k))
    $gr = [Drawing.Graphics]::FromImage($red); $gr.InterpolationMode = 'HighQualityBicubic'; $gr.DrawImage($src, 0, 0, $red.Width, $red.Height); $gr.Dispose(); $src.Dispose()
    $ms = New-Object IO.MemoryStream; $red.Save($ms, [Drawing.Imaging.ImageFormat]::Jpeg); $red.Dispose()
    $b64 = [Convert]::ToBase64String($ms.ToArray())
    $cuerpo = @{ stream = $false; max_tokens = 200; temperature = 0; chat_template_kwargs = @{ enable_thinking = $false }
        messages = @(@{ role = 'system'; content = $SISTEMA }, @{ role = 'user'; content = @(
            @{ type = 'image_url'; image_url = @{ url = "data:image/jpeg;base64,$b64" } }, @{ type = 'text'; text = $q }) }) } | ConvertTo-Json -Depth 8 -Compress
    $r = Invoke-RestMethod "http://127.0.0.1:$Puerto/v1/chat/completions" -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($cuerpo)) -TimeoutSec 120
    $t = "$($r.choices[0].message.content)"
    $m = [regex]::Match($t, '(?s)\{.*\}'); $j = if ($m.Success) { try { $m.Value | ConvertFrom-Json } catch { } }
    $pt = if ($j.senalar) { $x = [double]$j.senalar.x; $y = [double]$j.senalar.y; if ($x -gt 1 -or $y -gt 1) { $x /= 1000; $y /= 1000 }; @($x, $y) }
    [pscustomobject]@{ dijo = if ($j.decir) { "$($j.decir)" } else { $t }; punto = $pt }
}

# Acierta al senalar si el punto cae en la caja con 20 px de margen (en la
# resolucion de la imagen).
function Dentro($p, $c, $img) {
    if (-not $p) { return $false }
    $src = [Drawing.Image]::FromFile($img); $W = $src.Width; $H = $src.Height; $src.Dispose()
    $mx = 20.0 / $W; $my = 20.0 / $H
    $p[0] -ge ($c[0] - $mx) -and $p[0] -le ($c[2] + $mx) -and $p[1] -ge ($c[1] - $my) -and $p[1] -le ($c[3] + $my)
}

$filas = foreach ($c in $CASOS) {
    $ErrorActionPreference = 'Continue'
    $null = & "$raiz\ojo.ps1" -Pregunta $c.q -Imagen $c.img -Voz '' -Segundos 0 *>&1
    $ErrorActionPreference = 'Stop'
    $m = [IO.File]::ReadAllText("$raiz\ultima-medida.json", [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $pReal = if ($m.senalo) { @($m.senalo -split ',' | ForEach-Object { [double]$_ }) }
    $okReal = if ($c.tipo -eq 'leer') { [bool]($m.dijo -match $c.esp) } else { Dentro $pReal $c.caja $c.img }
    $okSola = $null; $dijoSola = ''
    if (-not $SoloReal) {
        $s = Solo-Imagen $c.img $c.q
        $okSola = if ($c.tipo -eq 'leer') { [bool]($s.dijo -match $c.esp) } else { Dentro $s.punto $c.caja $c.img }
        $dijoSola = $s.dijo
    }
    [pscustomobject]@{ res = $c.res; cat = $c.cat; tipo = $c.tipo; q = $c.q; real = $okReal; sola = $okSola
                       dijo = "$($m.dijo)"; via = "$($m.via)"; busco = "$($m.busco)"; dijo_sola = $dijoSola }
}

$res = [ordered]@{ nombre = $Nombre; fecha = Get-Date -Format 'yyyy-MM-dd HH:mm'
    real = "{0}/{1}" -f @($filas | Where-Object real).Count, $filas.Count
    sola = if ($SoloReal) { '' } else { "{0}/{1}" -f @($filas | Where-Object sola).Count, $filas.Count }
    filas = @($filas) }
$f = "$raiz\banco-pantalla.json"
$todas = @(if (Test-Path $f) { [IO.File]::ReadAllText($f, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json }) + [pscustomobject]$res
[IO.File]::WriteAllText($f, (ConvertTo-Json @($todas) -Depth 5), [Text.UTF8Encoding]::new($false))

"$Nombre   camino real $($res.real)   imagen sola $($res.sola)"
$filas | Group-Object cat | ForEach-Object {
    "{0,-15} real {1}/{2}   sola {3}/{2}" -f $_.Name, @($_.Group | Where-Object real).Count, $_.Count, @($_.Group | Where-Object sola).Count
}
"`nFALLOS del camino real:"
$filas | Where-Object { -not $_.real } | ForEach-Object { "  [$($_.res)] $($_.q)`n      dijo: $($_.dijo)  [$($_.via)]$(if ($_.busco) { "  busco: $($_.busco)" })" }
