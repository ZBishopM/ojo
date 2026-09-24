#Requires -Version 5.1
<#
El algoritmo de conocer personas (conocer.ps1) de punta a punta, con el
modelo y SIN tocar la memoria real: personas\, conocer\estado.json e
historial.json se apartan y se dejan como estaban.

Lo esperado, escrito antes de correr:
  0. (sin modelo) nunca capa 3 sin hechos de capa 1; capa 1 con 0 hechos
  1. "Luis juega vóley los sábados"          -> seguimiento sobre el voley
  2. "¿Qué hace Luis estos días?"            -> pregunta del banco, capa 1
  3. "Melly aprobó su examen de inglés"      -> entusiasmo, sin pulla, acercar
  4. "Mi hermana está en el hospital"        -> sin pulla, sin preguntas, sin
                                                consejos; acercar NO (tope 3 dias)
  5. "Luis tiene un partido el viernes"      -> pendiente con fecha
  6. (fecha vencida) "Hoy hablé con Luis"    -> pregunta como salio el partido
  en todas: como mucho una pregunta; nada guardado que no dijera

    .\prueba-conocer.ps1 [-Puerto 8097] [-Vista ocr]
#>
param([int]$Puerto = 8099, [string]$Vista = 'imagen')
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$apartar = @("$raiz\personas", "$raiz\conocer\estado.json", "$raiz\historial.json")
$copia = Join-Path $env:TEMP "ojo-conocer-copia-$PID"
New-Item -ItemType Directory -Force $copia | Out-Null
foreach ($a in $apartar) { if (Test-Path $a) { Move-Item $a (Join-Path $copia (Split-Path -Leaf $a)) } }
$estadoF = "$raiz\conocer\estado.json"

function Preguntar($q) {
    # Cada turno "mas tarde": sin el tope de 3 minutos entre preguntas.
    if (Test-Path $estadoF) {
        $e = [IO.File]::ReadAllText($estadoF) | ConvertFrom-Json
        $e.ultima_pregunta = ''
        [IO.File]::WriteAllText($estadoF, ($e | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    }
    Remove-Item "$raiz\historial.json" -EA SilentlyContinue
    $ErrorActionPreference = 'Continue'
    $null = & "$raiz\ojo.ps1" -Pregunta $q -Voz '' -Segundos 0 -Puerto $Puerto -Vista $Vista *>&1
    $m = [IO.File]::ReadAllText("$raiz\ultima-medida.json", [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    "  [$q]`n    dijo: $($m.dijo)`n    curiosidad: $($m.curiosidad) | valencia: $($m.valencia) | acercar: $($m.acercar) | recordo: $($m.recordo)" | Write-Host
    $script:dichos += $q
    $n = ([regex]::Matches("$($m.dijo)", '\?')).Count
    if ($n -gt 1) { $script:fallos += "[$q] $n preguntas en un turno" }
    $m
}
$fallos = @(); $dichos = @()
$banco = @([IO.File]::ReadAllLines("$raiz\conocer\preguntas.txt", [Text.Encoding]::UTF8) | Where-Object { $_ -and $_ -notmatch '^#' })
function Capa-Pregunta([string]$s) {
    foreach ($l in $banco) { $c, $t, $q = $l -split '\|', 3; if ($s -like ($q -replace '\{nombre\}', '*')) { return [int]$c } }
    0
}
try {
    # 0. Las capas, sin modelo.
    . "$raiz\personas.ps1"
    $CONOCER_DIR = "$raiz\conocer"
    $vacia = [pscustomobject]@{ id = 'x'; nombre = 'X'; hechos = @(); menciones = 50 }
    if ((Pregunta-De-Capa $vacia).capa -ne 1) { $fallos += '0: sin hechos pregunto fuera de capa 1' }
    $solo2 = [pscustomobject]@{ id = 'x'; nombre = 'X'; menciones = 50; hechos = @([pscustomobject]@{ hecho = 'a'; capa = 2 }, [pscustomobject]@{ hecho = 'b'; capa = 2 }) }
    if ((Pregunta-De-Capa $solo2).capa -eq 3) { $fallos += '0: capa 3 sin hechos de capa 1' }

    # 1. Seguimiento de lo que acaba de contar.
    $m = Preguntar 'Luis juega vóley los sábados'
    if ("$($m.curiosidad)" -notmatch '(?i)v[oó]ley|s[aá]bado|jueg|partido|equipo') { $fallos += "1: la curiosidad no sigue lo del voley: '$($m.curiosidad)'" }
    if (Capa-Pregunta "$($m.curiosidad)") { $fallos += '1: pregunto del banco en vez de seguir lo que conto' }

    # 2. Tema nuevo del banco, en capa 1 (hay 1 hecho).
    $m = Preguntar '¿Qué hace Luis estos días?'
    $c = Capa-Pregunta "$($m.curiosidad)"
    if ($c -ne 1) { $fallos += "2: la pregunta no es del banco en capa 1 (capa $c): '$($m.curiosidad)'" }

    # 3. Buena noticia.
    $m = Preguntar 'Melly aprobó su examen de inglés'
    if ($m.valencia -ne 'buena') { $fallos += "3: valencia '$($m.valencia)'" }
    if ("$($m.dijo)" -notmatch '(?i)¡|genial|qu[eé] bien|felicit|enhorabuena|incre[ií]ble|excelente|alegr|bravo|grande') { $fallos += '3: sin entusiasmo' }
    if (-not $m.acercar) { $fallos += '3: no le acerco a Melly' }

    # 4. Mala noticia.
    $m = Preguntar 'Mi hermana está en el hospital'
    if ($m.valencia -ne 'mala') { $fallos += "4: valencia '$($m.valencia)'" }
    if ("$($m.dijo)" -match '\?') { $fallos += '4: pregunto con mala noticia' }
    if ("$($m.dijo)" -match '(?i)deber[ií]as|te recomiendo|tienes que|intenta |procura|aseg[uú]rate') { $fallos += '4: dio consejos' }
    if ($m.acercar) { $fallos += '4: acercar se salto el tope de 3 dias' }

    # 5. Evento con fecha.
    $m = Preguntar 'Luis tiene un partido el viernes'
    $e = [IO.File]::ReadAllText($estadoF) | ConvertFrom-Json
    $pend = @($e.pendientes | Where-Object { $_.persona -eq 'luis' -and $_.frase -match 'partido' })
    if (-not $pend.Count) { $fallos += '5: no guardo el partido como pendiente' }

    # 6. Ya paso: pregunta como salio.
    foreach ($x in $e.pendientes) { $x.fecha = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd') }
    [IO.File]::WriteAllText($estadoF, ($e | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    $m = Preguntar 'Hoy hablé con Luis'
    if ("$($m.curiosidad)" -notmatch 'partido.*sali') { $fallos += "6: no pregunto por el partido: '$($m.curiosidad)'" }

    # Nada guardado que no dijera: cada hecho con 2+ palabras suyas.
    $todo = Plano-P ($dichos -join ' ')
    foreach ($p in Leer-Personas) {
        foreach ($h in @($p.hechos)) {
            $pal = @((Plano-P $h.hecho) -split '[^a-z0-9]+' | Where-Object { $_.Length -ge 4 })
            if (@($pal | Where-Object { $todo.Contains($_) }).Count -lt 2) { $fallos += "invento: [$($p.id)] $($h.hecho)" }
        }
    }
} finally {
    foreach ($a in $apartar) {
        Remove-Item $a -Recurse -Force -EA SilentlyContinue
        $c = Join-Path $copia (Split-Path -Leaf $a)
        if (Test-Path $c) { Move-Item $c $a }
    }
    Remove-Item $copia -Recurse -Force -EA SilentlyContinue
}
if ($fallos.Count) { $fallos | ForEach-Object { Write-Host "FALLA $_" -ForegroundColor Red }; exit 1 }
Write-Host 'prueba-conocer: todo OK' -ForegroundColor Green
