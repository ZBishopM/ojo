#Requires -Version 5.1
<#
Todas las pruebas de Ojo en un sitio, para la página MVP: qué comprueba cada
una, su último resultado y los casos que fallan tal cual. Nada copiado a mano:
los bancos se leen de sus .json; las pruebas sin .json se corren (-Correr) y
su salida se guarda en pruebas-resumen.json.

    .\resumen-pruebas.ps1 -Correr -Salida <dir>   corre las pruebas y escribe <dir>\pruebas.js
    .\resumen-pruebas.ps1 -Salida <dir>           solo relee (usa la última corrida)
    .\resumen-pruebas.ps1 -Correr -Solo chat,conocer -Salida <dir>   corre solo esas

En <dir>\codigo\ deja el código de cada prueba como .txt, para leerlo en el
navegador.
#>
param([switch]$Correr, [string]$Salida,
      # Con -Correr, solo estas (por id); las demás se quedan con su última corrida.
      [string[]]$Solo)
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$guardado = Join-Path $raiz 'pruebas-resumen.json'

function Leer-Json([string]$f) {
    $j = [IO.File]::ReadAllText((Join-Path $raiz $f), [Text.Encoding]::UTF8) | ConvertFrom-Json
    # Los hay guardados como {value: [...]} y como [...]; y PS 5.1 da el array como UN objeto.
    @($j | ForEach-Object { $_ } | ForEach-Object { if ($_.value) { $_.value } else { $_ } } | ForEach-Object { $_ })
}
function Corto([string]$s, [int]$n = 220) { $s = "$s" -replace '\s+', ' '; if ($s.Length -gt $n) { $s.Substring(0, $n) + '…' } else { $s } }

# grupo: con modelo o sin él. correr: script y argumentos. banco: cómo leer su .json.
$PRUEBAS = @(
    @{ id = 'verdad'; nombre = 'Verdad'; grupo = 'modelo'; archivo = 'banco-verdad.ps1'
       que = 'Preguntas con respuesta comprobable (hora, día, dólar, Mundial de LoL, VRAM de la barra, correo que no existe, workspaces). Falla si se equivoca o si afirma algo sin respaldo (invento).'
       banco = { $u = (Leer-Json 'banco-verdad.json')[-1]
                 $mal = @($u.filas | Where-Object { -not $_.ok -or $_.invento })
                 @{ resultado = "$($u.aciertos) · $($u.inventos) inventos"; fecha = $u.fecha
                    fallos = @($mal | ForEach-Object { "$($_.q) → «$(Corto $_.dijo)»" })
                    casos = @($mal | ForEach-Object { [pscustomobject]@{ q = $_.q; dijo = $_.dijo; tocaba = if ($_.invento) { 'no afirmar nada sin respaldo' } else { 'la respuesta comprobable (ver el código del banco)' }
                        vio = @(@(if ($_.busco) { "buscó: $($_.busco)" }; if ($_.fuentes) { "fuentes: $($_.fuentes)" }; if ($_.sin_respaldo) { "sin respaldo: $($_.sin_respaldo)" }; "líneas de OCR: $($_.ocr)") | Where-Object { $_ }) } }) } } }
    @{ id = 'partida'; nombre = 'Partida (inventada)'; grupo = 'modelo'; archivo = 'banco-partida.ps1'
       que = 'Preguntas de partida sobre una partida inventada con la respuesta conocida: composición, rival de línea, quién está muerto, oro, ítems.'
       banco = { $u = @(Leer-Json 'banco-partida.json' | Where-Object { $_.nombre -notlike '*real*' })[-1]
                 @{ resultado = "$($u.aciertos) · $($u.ms_medio) ms de media"; fecha = ''
                    fallos = @($u.filas | Where-Object { -not $_.ok } | ForEach-Object { "$($_.q) → «$(Corto $_.dijo)»" })
                    casos = @($u.filas | Where-Object { -not $_.ok } | ForEach-Object { [pscustomobject]@{ q = $_.q; dijo = $_.dijo; tocaba = 'ver el código del banco'; vio = @('los datos de la partida inventada (lol.ps1)') } }) } } }
    @{ id = 'partida-real'; nombre = 'Partida (real, frases tuyas)'; grupo = 'modelo'; archivo = 'banco-partida.ps1'
       que = 'La partida real congelada de ARAM Mayhem (2026-09-22) con las frases literales que fallaron aquel día.'
       banco = { $u = @(Leer-Json 'banco-partida.json' | Where-Object { $_.nombre -like '*real*' })[-1]
                 @{ resultado = "$($u.aciertos)"; fecha = ''
                    fallos = @($u.filas | Where-Object { -not $_.ok } | ForEach-Object { "$($_.q) → «$(Corto $_.dijo)»" }) } } }
    @{ id = 'pantalla'; nombre = 'Leer y señalar la pantalla'; grupo = 'modelo'; archivo = 'banco-pantalla.ps1'
       que = 'Tus pantallas REALES congeladas (los dos monitores a tamaño nativo, con la verdad del sistema y de UI Automation: leer la barra y señalar controles) e imágenes trampa dibujadas (cifras de 11 px, tabla densa, gris sobre gris, decimales, el mismo botón dos veces) a 1080p, 1440p y 900p. Camino real de Ojo (OCR, controles, verificador) contra la imagen sola al modelo.'
       banco = { $u = @(Leer-Json 'banco-pantalla.json')[-1]
                 $mal = @($u.filas | Where-Object { $_.real -eq $false })
                 $porCat = @($u.filas | Group-Object cat | ForEach-Object { "$($_.Name) $(@($_.Group | Where-Object real).Count)/$($_.Count)" }) -join ' · '
                 @{ resultado = "camino real $($u.real)$(if ($u.sola) { " · imagen sola $($u.sola)" })"; fecha = $u.fecha; detalle = $porCat
                    fallos = @($mal | ForEach-Object { "[$($_.res), $($_.cat)] $($_.q) → «$(Corto $_.dijo)»" })
                    casos = @($mal | ForEach-Object { [pscustomobject]@{ q = "[$($_.res), $($_.cat)] $($_.q)"; dijo = $_.dijo; tocaba = $_.tocaba; vio = @($_.vio)
                        dijo_sola = $_.dijo_sola; sola_ok = $_.sola; _img = $_.img; _caja = $_.caja; _senalo = $_.senalo; _cat = $_.cat } }) +
                            # Los que solo falla la IMAGEN SOLA: lo que el modelo hace sin OCR ni controles.
                            @($u.filas | Where-Object { $_.real -and $_.sola -eq $false } | ForEach-Object { [pscustomobject]@{ q = "[imagen sola · $($_.res), $($_.cat)] $($_.q)"; dijo = $_.dijo_sola
                                tocaba = $_.tocaba; vio = @('solo la imagen reducida a 1280, sin OCR ni lista de controles'); dijo_sola = "camino real (acertó): $($_.dijo)"; sola_ok = $true
                                _img = $_.img; _caja = $_.caja; _senalo = ''; _cat = $_.cat } }) } } }
    @{ id = 'conocer'; nombre = 'Conocer a tu gente'; grupo = 'modelo'; archivo = 'prueba-conocer.ps1'; correr = @()
       que = 'Conversación guionada sobre una copia de la memoria: seguimiento de lo que cuentas, preguntas por capas, buena y mala noticia, un evento con fecha que pregunta después, tope de «acercar», nada inventado.' }
    @{ id = 'personas'; nombre = 'Memoria de personas'; grupo = 'modelo'; archivo = 'prueba-personas.ps1'; correr = @()
       que = 'Sobre una copia de la memoria: aprende nombres hablando, no repite preguntas, no inventa de quien no sabe nada, tiene tema cuando no hay.' }
    @{ id = 'chat'; nombre = 'Chat de WhatsApp'; grupo = 'modelo'; archivo = 'prueba-chat.ps1'; correr = @()
       que = 'Un chat inventado: el último mensaje que te enviaron (el de la izquierda, no el tuyo) y no inventar un botón que no está.' }
    @{ id = 'verificar'; nombre = 'Verificador'; grupo = 'codigo'; archivo = 'prueba-verificar.ps1'; correr = @()
       que = 'Sin modelo: cada cifra y nombre propio de una respuesta tiene que salir de la pantalla, el sistema o la web.' }
    @{ id = 'conocer-reglas'; nombre = 'Reglas de conocer'; grupo = 'codigo'; archivo = 'conocer.ps1'; correr = @()
       que = 'Sin modelo: buena o mala noticia, fecha de «el viernes» y «mañana», capa de cada hecho.' }
    @{ id = 'decir'; nombre = 'Nombres de controles'; grupo = 'codigo'; archivo = 'decir.ps1'; correr = @()
       que = 'Sin modelo: el nombre de un control dicho por el modelo se cambia por el real.' }
    @{ id = 'lol'; nombre = 'Datos de partida'; grupo = 'codigo'; archivo = 'lol.ps1'; correr = @('-Prueba')
       que = 'Sin modelo: los datos masticados de la partida (equipos, oro, muertos) con casos inventados.' }
    @{ id = 'lcu'; nombre = 'Cliente de LoL'; grupo = 'codigo'; archivo = 'lcu.ps1'; correr = @('-Prueba')
       que = 'Sin modelo: lectura del cliente (aumentos elegidos, selección) contra una muestra guardada.' }
    @{ id = 'builds'; nombre = 'Builds y aumentos'; grupo = 'codigo'; archivo = 'builds.ps1'; correr = @('-Prueba')
       que = 'Sin modelo: la build y la clasificación de aumentos contra una página guardada.' }
    @{ id = 'aumentos'; nombre = 'Elegir aumento'; grupo = 'codigo'; archivo = 'prueba-aumentos.ps1'; correr = @()
       que = 'Pantalla de elección dibujada: OCR de las tres cartas y elige el mejor por la clasificación (sin tasas de victoria).' }
    @{ id = 'decidir'; nombre = 'Decisiones tipadas «a lo Jev» (descartado)'; grupo = 'descartado'; archivo = 'banco-decidir.ps1'; mediciones = 'banco-decidir\.ps1'
       que = 'El modelo decidiendo la ruta de cada pregunta contra las reglas en código. Perdió: se quedan las reglas.' }
    @{ id = 'extractor'; nombre = 'Extractor web: regex contra Trafilatura (descartado)'; grupo = 'descartado'; archivo = 'ab-extractor.ps1'; mediciones = 'ab-extractor\.ps1'
       que = 'Cuántas páginas traen el dato al modelo con cada extractor. Ganó el regex.' }
)

$previo = @{}
if (Test-Path $guardado) { foreach ($x in (Leer-Json 'pruebas-resumen.json')) { $previo[$x.id] = $x } }
$mediciones = [IO.File]::ReadAllLines((Join-Path $raiz 'MEDICIONES.md'), [Text.Encoding]::UTF8)

$salidaPruebas = foreach ($p in $PRUEBAS) {
    $r = @{ resultado = ''; fecha = ''; fallos = @(); ok = $null }
    if ($p.banco) {
        try { $r = & $p.banco; $r.ok = -not @($r.fallos).Count } catch { $r.resultado = "sin resultado: $_" }
    } elseif ($p.mediciones) {
        # El párrafo de MEDICIONES.md que lo cuenta, hasta la siguiente línea en blanco tras la tabla.
        $i = [Array]::FindIndex($mediciones, [Predicate[string]] { param($l) $l -match $p.mediciones })
        $bloque = @(); $j = $i
        while ($j -ge 0 -and $j -lt $mediciones.Count -and $bloque.Count -lt 18) { $bloque += $mediciones[$j]; $j++; if ($mediciones[$j] -eq '' -and $bloque[-1] -notmatch '^\|' -and $bloque.Count -gt 4) { break } }
        $r.resultado = 'descartado (ver medición)'; $r.medicion = ($bloque -join "`n")
    } elseif ($Correr -and (-not $Solo -or $Solo -contains $p.id)) {
        Write-Host "corriendo $($p.archivo) $($p.correr)..." -ForegroundColor DarkGray
        $sw = [Diagnostics.Stopwatch]::StartNew()
        # (con Stop, el stderr de un proceso nativo por 2>&1 revienta en 5.1)
        $ErrorActionPreference = 'Continue'
        $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $raiz $p.archivo) @($p.correr) 2>&1 | ForEach-Object { "$_" })
        $codigo = $LASTEXITCODE
        $out = @(($out -join "`n") -split '\r?\n')
        $ok = $out | Where-Object { $_ -match '^\s*\d+ \w+ OK\s*$|todo OK' } | Select-Object -Last 1
        $r.fallos = @($out | Where-Object { $_ -match '^\s*FALLA|^\s+\d+:' } | ForEach-Object { Corto $_.Trim() 300 })
        $r.ok = $codigo -eq 0
        $r.resultado = if ($r.ok) { "$ok".Trim() } else { "falla (código $codigo)" }
        $r.fecha = Get-Date -Format 'yyyy-MM-dd HH:mm'; $r.ms = $sw.ElapsedMilliseconds
    } elseif ($previo[$p.id]) {
        $x = $previo[$p.id]; $r = @{ resultado = $x.resultado; fecha = $x.fecha; fallos = @($x.fallos); ok = $x.ok; ms = $x.ms }
    } else { $r.resultado = 'sin correr' }
    [pscustomobject]@{ id = $p.id; nombre = $p.nombre; grupo = $p.grupo; archivo = $p.archivo; que = $p.que; detalle = $r.detalle
                       resultado = $r.resultado; fecha = $r.fecha; ok = $r.ok; ms = $r.ms; fallos = @($r.fallos); medicion = $r.medicion; casos = @($r.casos | Where-Object { $_ }) }
}
[IO.File]::WriteAllText($guardado, (ConvertTo-Json @($salidaPruebas) -Depth 5), [Text.UTF8Encoding]::new($false))

# El recorte de un fallo de pantalla: la caja que tocaba en verde y el punto
# que marco en rojo; en lectura, la barra de arriba (o la imagen entera).
function Recorte($c, [string]$destino) {
    Add-Type -AssemblyName System.Drawing
    $src = [Drawing.Image]::FromFile($c._img)
    try {
        $W = $src.Width; $H = $src.Height
        $pt = if ($c._senalo) { $s = @("$($c._senalo)" -split ',' | ForEach-Object { [double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) }); @(($s[0] * $W), ($s[1] * $H)) }
        if ($c._caja) {
            $k = @($c._caja | ForEach-Object { [double]$_ })
            $bx = @(($k[0] * $W), ($k[1] * $H), ($k[2] * $W), ($k[3] * $H))
            $xs = @($bx[0], $bx[2]); $ys = @($bx[1], $bx[3]); if ($pt) { $xs += $pt[0]; $ys += $pt[1] }
            $x0 = [math]::Max(0, ($xs | Measure-Object -Minimum).Minimum - 220); $y0 = [math]::Max(0, ($ys | Measure-Object -Minimum).Minimum - 140)
            $x1 = [math]::Min($W, ($xs | Measure-Object -Maximum).Maximum + 220); $y1 = [math]::Min($H, ($ys | Measure-Object -Maximum).Maximum + 140)
        } elseif ($c._cat -match 'barra') { $x0 = [int]($W * 0.45); $y0 = 0; $x1 = $W; $y1 = 60 }
        else { $x0 = 0; $y0 = 0; $x1 = $W; $y1 = $H }
        $rw = [int]($x1 - $x0); $rh = [int]($y1 - $y0)
        $esc = [math]::Min(1.0, 1100.0 / $rw)
        $bmp = New-Object Drawing.Bitmap ([int]($rw * $esc)), ([int]($rh * $esc))
        $g = [Drawing.Graphics]::FromImage($bmp); $g.InterpolationMode = 'HighQualityBicubic'
        $g.DrawImage($src, (New-Object Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height), (New-Object Drawing.Rectangle ([int]$x0), ([int]$y0), $rw, $rh), 'Pixel')
        if ($c._caja) { $g.DrawRectangle((New-Object Drawing.Pen ([Drawing.Color]::LimeGreen), 3), [float](($bx[0] - $x0) * $esc), [float](($bx[1] - $y0) * $esc), [float](($bx[2] - $bx[0]) * $esc), [float](($bx[3] - $bx[1]) * $esc)) }
        if ($pt) { $r = 9; $g.FillEllipse([Drawing.Brushes]::Red, [float](($pt[0] - $x0) * $esc - $r), [float](($pt[1] - $y0) * $esc - $r), 2 * $r, 2 * $r) }
        $g.Dispose(); $bmp.Save($destino, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    } finally { $src.Dispose() }
}

if ($Salida) {
    New-Item -ItemType Directory -Force (Join-Path $Salida 'codigo') | Out-Null
    $dirFallos = Join-Path $Salida 'fallos'
    Remove-Item $dirFallos -Recurse -Force -EA SilentlyContinue; New-Item -ItemType Directory -Force $dirFallos | Out-Null
    $n = 0
    $web = foreach ($p in $salidaPruebas) {
        $casos = foreach ($c in @($p.casos)) {
            $img = $null
            if ($c._img -and (Test-Path $c._img)) { $n++; $img = "fallos/$n.png"; try { Recorte $c (Join-Path $Salida $img) } catch { $img = $null } }
            [pscustomobject]@{ q = $c.q; tocaba = $c.tocaba; vio = @($c.vio); dijo = $c.dijo; dijo_sola = $c.dijo_sola; sola_ok = $c.sola_ok; img = $img }
        }
        $p | Select-Object * -ExcludeProperty casos | Add-Member -NotePropertyName casos -NotePropertyValue @($casos) -PassThru
    }
    # La comparacion de modelos (comparar-modelos.ps1), mas el 8B de referencia
    # medido con el mismo banco de pantalla (banco-pantalla -Nombre M0-v1).
    $modelos = @()
    if (Test-Path "$raiz\comparar-modelos.json") {
        # La ultima corrida de cada modelo (una corrida cortada deja filas a medias).
        $modelos = @(Leer-Json 'comparar-modelos.json' | Group-Object id | ForEach-Object { $_.Group[-1] } | ForEach-Object {
            $m = $_
            [pscustomobject]@{ id = $m.id; nombre = $m.nombre; tok_s = $m.tok_s; vram = $m.vram_modelo
                variantes = (@($m.variantes.PSObject.Properties | ForEach-Object { "$($_.Name): $($_.Value.real) ($($_.Value.ms_medio) ms)" }) -join ' · ')
                categorias = "$(@($m.vueltas)[0].pantalla.categorias)"
                con_lol = "$($m.con_lol.tok_s) tok/s · pantallas reales $($m.con_lol.pantallas_reales) · partida $($m.con_lol.partida)$(if ($m.con_lol.derrama) { ' · DERRAMA' })"
                vueltas = @($m.vueltas | ForEach-Object { [pscustomobject]@{ pantalla = $_.pantalla.real; sola = $_.pantalla.sola; verdad = "$($_.verdad.aciertos) · $($_.verdad.inventos) inventos"
                    chat = $_.'prueba-chat'.ok; personas = $_.'prueba-personas'.ok; conocer = $_.'prueba-conocer'.ok; partida = $_.partida.aciertos; partida_real = $_.partida_real.aciertos
                    fallos = @(@($_.pantalla.fallos | ForEach-Object { "pantalla: $_" }) + @($_.verdad.fallos | ForEach-Object { "verdad: $_" }) +
                               @($_.'prueba-conocer'.fallos + $_.'prueba-personas'.fallos + $_.'prueba-chat'.fallos | Where-Object { $_ } | ForEach-Object { "conversación: $_" }) +
                               @(@($_.partida.fallos) + @($_.partida_real.fallos) | Where-Object { $_ } | ForEach-Object { "partida: $_" })) } }) }
        })
        $m0 = @(Leer-Json 'banco-pantalla.json' | Where-Object nombre -eq 'M0-v1')[-1]
        if ($m0 -and -not @($modelos | Where-Object id -eq 'M0').Count) {
            $modelos = @([pscustomobject]@{ id = 'M0'; nombre = 'Qwen3-VL-8B Q6_K + visión (el de hoy)'; tok_s = 62; vram = 8540; con_lol = 'no cabe: LoL + 8B derraman (47,8 → 6,1 tok/s, medido el 22/09)'
                vueltas = @([pscustomobject]@{ pantalla = $m0.real; sola = $m0.sola; verdad = '8/8 · 0 inventos'; chat = $true; personas = $true; conocer = $true; partida = '16/16'; partida_real = '8/8'
                    fallos = @($m0.filas | Where-Object { $_.real -eq $false } | ForEach-Object { "pantalla: [$($_.res), $($_.cat)] $($_.q) -> $($_.dijo)" }) }) }) + $modelos
        }
    }
    # Lo que gasta el PC por escenario (medir-consumo.ps1) y el historico de
    # rice\consumo, para la seccion "Cuanto gasta".
    $consumo = @(if (Test-Path "$raiz\consumo-escenarios.json") { Leer-Json 'consumo-escenarios.json' | Group-Object escenario | ForEach-Object { $_.Group[-1] } })
    $mes = try { [IO.File]::ReadAllText("$env:USERPROFILE\.config\consumo\$(Get-Date -Format 'yyyy-MM').json", [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json } catch { $null }
    $dias = @(if ($mes) { $mes.PSObject.Properties | Where-Object { $_.Value.segundos -gt 4 * 3600 } | ForEach-Object { [pscustomobject]@{ kwh = $_.Value.wh / 1000; h = $_.Value.segundos / 3600 } } })
    $precio = try { [double](([IO.File]::ReadAllText("$env:USERPROFILE\.config\rice.json", [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json).consumo.precio_kwh) } catch { 0.70 }
    $historico = if ($dias.Count) { [ordered]@{ dias = $dias.Count; kwh_dia = [math]::Round(($dias | Measure-Object kwh -Average).Average, 2); horas_dia = [math]::Round(($dias | Measure-Object h -Average).Average, 1)
                                                 soles_mes = [math]::Round(($dias | Measure-Object kwh -Average).Average * 30 * $precio, 1); precio = $precio } }
    # La VRAM por proceso (vram.ps1), para el diagrama.
    $vram = @(Get-ChildItem $raiz -Filter 'vram-*.json' | Where-Object Name -ne 'vram-ahora.json' | ForEach-Object { [IO.File]::ReadAllText($_.FullName, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json })
    [IO.File]::WriteAllText((Join-Path $Salida 'pruebas.js'), "window.PRUEBAS = $(ConvertTo-Json @($web) -Depth 5 -Compress);`nwindow.VRAM = $(ConvertTo-Json @($vram) -Depth 4 -Compress);`nwindow.MODELOS = $(ConvertTo-Json @($modelos) -Depth 6 -Compress);`nwindow.CONSUMO = $(ConvertTo-Json ([ordered]@{ escenarios = @($consumo); historico = $historico }) -Depth 4 -Compress);", [Text.UTF8Encoding]::new($false))
    foreach ($a in @($PRUEBAS | ForEach-Object { $_.archivo } | Select-Object -Unique)) {
        Copy-Item (Join-Path $raiz $a) (Join-Path $Salida "codigo\$a.txt") -Force
    }
}
$salidaPruebas | ForEach-Object { '{0,-4} {1,-45} {2}' -f $(if ($_.ok -eq $true) { 'OK' } elseif ($_.ok -eq $false) { 'MAL' } else { '--' }), $_.nombre, $_.resultado }
