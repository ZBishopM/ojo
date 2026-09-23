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
                 @{ resultado = "$($u.aciertos) · $($u.inventos) inventos"; fecha = $u.fecha
                    fallos = @($u.filas | Where-Object { -not $_.ok -or $_.invento } | ForEach-Object { "$($_.q) → «$(Corto $_.dijo)»" }) } } }
    @{ id = 'partida'; nombre = 'Partida (inventada)'; grupo = 'modelo'; archivo = 'banco-partida.ps1'
       que = 'Preguntas de partida sobre una partida inventada con la respuesta conocida: composición, rival de línea, quién está muerto, oro, ítems.'
       banco = { $u = @(Leer-Json 'banco-partida.json' | Where-Object { $_.nombre -notlike '*real*' })[-1]
                 @{ resultado = "$($u.aciertos) · $($u.ms_medio) ms de media"; fecha = ''
                    fallos = @($u.filas | Where-Object { -not $_.ok } | ForEach-Object { "$($_.q) → «$(Corto $_.dijo)»" }) } } }
    @{ id = 'partida-real'; nombre = 'Partida (real, frases tuyas)'; grupo = 'modelo'; archivo = 'banco-partida.ps1'
       que = 'La partida real congelada de ARAM Mayhem (2026-09-22) con las frases literales que fallaron aquel día.'
       banco = { $u = @(Leer-Json 'banco-partida.json' | Where-Object { $_.nombre -like '*real*' })[-1]
                 @{ resultado = "$($u.aciertos)"; fecha = ''
                    fallos = @($u.filas | Where-Object { -not $_.ok } | ForEach-Object { "$($_.q) → «$(Corto $_.dijo)»" }) } } }
    @{ id = 'pantalla'; nombre = 'Leer y señalar la pantalla'; grupo = 'modelo'; archivo = 'banco-pantalla.ps1'
       que = 'Imágenes trampa dibujadas con la verdad conocida (cifras de 11 px, tabla densa, gris sobre gris, decimales, el mismo botón dos veces) a 1080p, 1440p y 900p, más una captura real. Camino real de Ojo (OCR + verificador) contra la imagen sola al modelo.'
       banco = { $t = @(Leer-Json 'banco-pantalla.json'); $u = $t[-1]
                 $sola = @($t | Where-Object { $_.sola })[-1]
                 @{ resultado = "camino real $($u.real) · imagen sola $($sola.sola)"; fecha = $u.fecha
                    fallos = @($u.filas | Where-Object { $_.real -eq $false } | ForEach-Object { "[$($_.res), $($_.cat)] $($_.q) → «$(Corto $_.dijo)»" }) } } }
    @{ id = 'vision'; nombre = 'Visión sola (antigua)'; grupo = 'modelo'; archivo = 'banco-vision.ps1'
       que = 'La captura de referencia a 1280x720 mandada sola al modelo, sin OCR: lo que medía el 8/10 de «leer la pantalla».'
       banco = { $u = (Leer-Json 'banco-vision.json')[-1]
                 @{ resultado = "leer $($u.leer) · señalar $($u.senalar) (mediana $($u.px_mediana) px)"; fecha = ''
                    fallos = @($u.filas | Where-Object { -not $_.ok } | ForEach-Object { "$($_.q) → «$(Corto $_.dijo)»$(if ($_.px) { " a $($_.px) px" })" }) } } }
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
    [pscustomobject]@{ id = $p.id; nombre = $p.nombre; grupo = $p.grupo; archivo = $p.archivo; que = $p.que
                       resultado = $r.resultado; fecha = $r.fecha; ok = $r.ok; ms = $r.ms; fallos = @($r.fallos); medicion = $r.medicion }
}
[IO.File]::WriteAllText($guardado, (ConvertTo-Json @($salidaPruebas) -Depth 4), [Text.UTF8Encoding]::new($false))

if ($Salida) {
    New-Item -ItemType Directory -Force (Join-Path $Salida 'codigo') | Out-Null
    [IO.File]::WriteAllText((Join-Path $Salida 'pruebas.js'), "window.PRUEBAS = $(ConvertTo-Json @($salidaPruebas) -Depth 4 -Compress);", [Text.UTF8Encoding]::new($false))
    foreach ($a in @($PRUEBAS | ForEach-Object { $_.archivo } | Select-Object -Unique)) {
        Copy-Item (Join-Path $raiz $a) (Join-Path $Salida "codigo\$a.txt") -Force
    }
}
$salidaPruebas | ForEach-Object { '{0,-4} {1,-45} {2}' -f $(if ($_.ok -eq $true) { 'OK' } elseif ($_.ok -eq $false) { 'MAL' } else { '--' }), $_.nombre, $_.resultado }
