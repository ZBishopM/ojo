#Requires -Version 5.1
<#
COMO conoce Ojo a las personas de su vida: el algoritmo, con su fuente.

POR QUE: lo pidio asi (2026-09-23): "un algoritmo para conocer personas basado
en articulos cientificos verificados o fuentes confiables de como una persona
real conoce a otra, en un vinculo sano". Y que le ACERQUE a su gente.

Las decisiones van en CODIGO (el 8B no las toma bien); el modelo solo redacta.
Cada una, con su fuente (detalle en memorias\conocer-personas.md):

  1. Capas, amplitud antes que profundidad: se pregunta en la capa en la que
     ya hay datos; se sube cuando hay 2+ hechos de la anterior y se ha hablado
     de esa persona lo bastante (Altman y Taylor 1973; Aron et al. 1997; Hall
     2019: la cercania necesita tiempo compartido).
  2. Seguimiento antes que tema nuevo, y pocas preguntas: si acaba de contar
     algo, la pregunta es sobre ESO; como mucho una por turno y no seguidas
     (Huang et al. 2017).
  3. Responder antes de preguntar: mostrar que entendio (Reis y Shaver 1988).
  4. Buenas noticias: entusiasmo y pedir un detalle, sin sarcasmo (Gable et
     al. 2004). Malas: apoyo breve, sin humor ni consejos no pedidos.
  5. Eventos pendientes: "el viernes tiene examen" se guarda con fecha y
     despues se pregunta como le fue (Gottman, mapas del amor).
  6. Acercar: de vez en cuando sugiere contarselo a esa persona; nunca se
     presenta como sustituto (MIT Media Lab + OpenAI 2025).

    . .\conocer.ps1        (con punto) Conocer-Turno, Guardar-Pendiente...
#>
$ErrorActionPreference = 'Stop'
$CONOCER_DIR = Join-Path $PSScriptRoot 'conocer'
$CONOCER_ESTADO = Join-Path $CONOCER_DIR 'estado.json'

function Plano-C([string]$s) { ($s.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '') }

# Valencia de lo que cuenta, por palabras (sin modelo): buena, mala o nada.
function Valencia([string]$q) {
    $p = Plano-C $q
    if ($p -match '\b(murio|fallecio|enferm|hospital|accidente|triste|deprim|ansiedad|estres|preocupad|pele(e|o|amos|aron)\b|pelea|terminamos|termino con|rompimos|despidieron|perdio|perdi|reprob|jalo|jale|jalaron|mal momento|lo esta pasando mal|la esta pasando mal|le va mal)') { return 'mala' }
    if ($p -match '\b(aprob|gano|gane|ganamos|consigui|consiguio|logro|logre|ascend|me dieron|le dieron|por fin|feliz|contento|contenta|se caso|nos casamos|embarazad|nacio|se graduo|me gradue|ingreso|ingrese|la aceptaron|lo aceptaron|me aceptaron|compro|compre|viajo|va a viajar|cumple)') { return 'buena' }
    ''
}

# Capa de un hecho, por palabras: 3 = lo de dentro, 2 = opiniones y planes, 1 = lo demas.
function Capa-De([string]$hecho) {
    $p = Plano-C $hecho
    if ($p -match '\b(miedo|sueno|suena con|le importa|valora|cree en|se siente|siente que|le duele|sufre|ama|odia|preocupa|ansiedad|triste|feliz|meta|proposito)') { return 3 }
    if ($p -match '\b(piensa|opina|planea|quiere|va a|trabaja|estudia|carrera|proyecto|busca|intenta|prepara|se muda|viaja)') { return 2 }
    1
}

# La fecha de un evento dicho en la frase ("manana", "el viernes"...), o $null.
function Fecha-De-Evento([string]$q, [datetime]$hoy = (Get-Date).Date) {
    $p = Plano-C $q
    if ($p -match '\bpasado manana\b') { return $hoy.AddDays(2) }
    if ($p -match '\bmanana\b') { return $hoy.AddDays(1) }
    if ($p -match '\b(la proxima semana|la otra semana|la semana que viene)\b') { return $hoy.AddDays(7) }
    if ($p -match '\b(este fin de semana|el fin de semana)\b') { $d = (6 - [int]$hoy.DayOfWeek + 7) % 7; if ($d -eq 0) { $d = 7 }; return $hoy.AddDays($d) }
    $dias = @{ lunes = 1; martes = 2; miercoles = 3; jueves = 4; viernes = 5; sabado = 6; domingo = 0 }
    foreach ($k in $dias.Keys) {
        if ($p -match "\b(el|este|el proximo) $k\b") { $d = ($dias[$k] - [int]$hoy.DayOfWeek + 7) % 7; if ($d -eq 0) { $d = 7 }; return $hoy.AddDays($d) }
    }
    $null
}

function Leer-Estado-C {
    $e = try { [IO.File]::ReadAllText($CONOCER_ESTADO, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json } catch { $null }
    if (-not $e) { $e = [pscustomobject]@{ ultimo_acercar = ''; ultima_pregunta = ''; pendientes = @() } }
    $e
}
function Guardar-Estado-C($e) {
    New-Item -ItemType Directory -Force $CONOCER_DIR | Out-Null
    [IO.File]::WriteAllText($CONOCER_ESTADO, ($e | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
}

# Una pregunta del banco para esa persona: en la capa que toca, de un tema
# que aun no se le pregunto. $null si no hay.
function Pregunta-De-Capa($p) {
    $hechos = @($p.hechos)
    $n1 = @($hechos | Where-Object { [int]"$($_.capa)" -le 1 }).Count
    $n2 = @($hechos | Where-Object { [int]"$($_.capa)" -eq 2 }).Count
    $menciones = [int]"$($p.menciones)"
    # Amplitud antes que profundidad, y la cercania pide tiempo (Hall 2019).
    $capa = if ($n1 -ge 2 -and $n2 -ge 2 -and $menciones -ge 6) { 3 } elseif ($n1 -ge 2 -and $menciones -ge 3) { 2 } else { 1 }
    $nom = if ($p.nombre) { $p.nombre } else { "tu $($p.id)" }
    $hechas = @($p.temas_preguntados)
    $banco = @(try { [IO.File]::ReadAllLines((Join-Path $CONOCER_DIR 'preguntas.txt'), [Text.Encoding]::UTF8) } catch { }) |
        Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $c, $t, $q = $_ -split '\|', 3; [pscustomobject]@{ capa = [int]$c; tema = $t; q = $q } }
    # "¿Como conociste a tu hermana?" no tiene sentido.
    $opc = @($banco | Where-Object { $_.capa -le $capa -and $hechas -notcontains $_.tema -and -not ($p.id -eq 'hermana' -and $_.tema -eq 'origen') } |
             Sort-Object { - $_.capa })
    if (-not $opc.Count) { return $null }
    $e = $opc[0]
    [pscustomobject]@{ tema = $e.tema; capa = $e.capa; pregunta = $e.q.Replace('{nombre}', $nom) }
}

# El PLAN del turno, decidido en codigo. Devuelve:
#   instruccion : lo que se le pide al modelo (se anade al prompt)
#   pregunta    : la pregunta que hara Ojo (o $null)
#   sin_pulla   : si hay que quitar el humor
#   acercar     : sugerencia de acercarle a esa persona (o $null)
function Conocer-Turno([string]$q, $personas, $ids, [bool]$tema) {
    $plan = [pscustomobject]@{ instruccion = ''; pregunta = $null; sin_pulla = $false; acercar = $null; persona = $null; valencia = ''; conto = $false; tema_banco = $null }
    $p = if (@($ids).Count) { $personas | Where-Object id -eq $ids[0] | Select-Object -First 1 }
    if (-not $p) { return $plan }
    $estado = Leer-Estado-C
    $val = Valencia $q
    $conto = -not $tema -and (Conto-Algo $q)
    $inst = @()
    $pregunta = $null; $acercar = $null
    $nom = if ($p.nombre) { $p.nombre } else { "tu $($p.id)" }
    # Tiempo compartido (Hall 2019): cada vez que lo nombra.
    if (-not $tema) { $p | Add-Member -NotePropertyName menciones -NotePropertyValue ([int]"$($p.menciones)" + 1) -Force }

    # 3. Responder antes de preguntar (Reis y Shaver).
    if ($conto) { $inst += "Antes de nada, demuestra que entendiste lo que contó de $nom (dilo con tus palabras, sin repetirlo tal cual)." }
    # 4. Valencia (Gable; cuidado).
    if ($val -eq 'buena') { $inst += 'Es una BUENA noticia: responde con entusiasmo sincero (respuesta activa-constructiva). Nada de sarcasmo.' }
    if ($val -eq 'mala') { $inst += 'Es una MALA noticia: apoyo breve y cálido. Sin humor, sin sarcasmo, sin preguntas y sin consejos que no pidió.' }

    # 5. Eventos pendientes ya vencidos de esta persona (o de cualquiera, si
    #    pidio tema): se pregunta como salio.
    $hoy = (Get-Date).Date
    $vencido = @($estado.pendientes | Where-Object { $_ -and -not $_.preguntado -and [datetime]$_.fecha -le $hoy -and ($tema -or $_.persona -eq $p.id) }) | Select-Object -First 1

    # 2. Como mucho UNA pregunta, y de banco no si hubo otra hace menos de 3
    #    minutos (salvo que pida tema). El seguimiento de lo que acaba de
    #    contar va antes que un tema nuevo.
    $reciente = $estado.ultima_pregunta -and ([datetime]$estado.ultima_pregunta -gt (Get-Date).AddMinutes(-3))
    if ($val -ne 'mala') {
        if ($vencido) {
            $pregunta = "La otra vez me contaste: «$($vencido.frase)». ¿Cómo salió?"
            $vencido.preguntado = $true
        } elseif ($conto) {
            $inst += "Haz UNA pregunta de SEGUIMIENTO sobre eso mismo que acaba de contar de $nom, corta y natural, en el campo curiosidad (no en decir). La pregunta es sobre $nom, no sobre el usuario."
        } elseif (-not $reciente -or $tema) {
            $pc = Pregunta-De-Capa $p
            if ($pc) {
                $pregunta = $pc.pregunta
                $plan.tema_banco = $pc.tema
                $p | Add-Member -NotePropertyName temas_preguntados -NotePropertyValue @(@($p.temas_preguntados | Where-Object { $_ }) + $pc.tema | Select-Object -Unique) -Force
            }
        }
    }
    if ($pregunta) { $inst += 'No hagas ninguna pregunta: la pregunta la pongo yo. Deja curiosidad vacía.' }
    if ($pregunta -or $conto) { $estado | Add-Member -NotePropertyName ultima_pregunta -NotePropertyValue (Get-Date).ToString('o') -Force }

    # 6. Acercar (MIT Media Lab + OpenAI 2025): cuando hay noticia de esa
    #    persona, como mucho una vez cada 3 dias. Afirmacion, no pregunta (ya
    #    hay una). Nunca como sustituto.
    if ($val -and -not $tema -and (-not $estado.ultimo_acercar -or [datetime]$estado.ultimo_acercar -lt (Get-Date).AddDays(-3))) {
        $acercar = if ($val -eq 'buena') { "Escríbele a $nom para felicitarle; seguro le hace ilusión que se lo digas tú." } else { "Si te apetece, escríbele a $nom; a veces ayuda más que cualquier cosa que yo te diga." }
        $estado | Add-Member -NotePropertyName ultimo_acercar -NotePropertyValue (Get-Date).ToString('o') -Force
    }
    Guardar-Estado-C $estado
    Guardar-Persona $p
    $plan.instruccion = if ($inst.Count) { "`n`nCOMO RESPONDER AHORA (para conocer bien a las personas de su vida):`n- " + ($inst -join "`n- ") } else { '' }
    $plan.pregunta = $pregunta; $plan.acercar = $acercar; $plan.persona = $p; $plan.valencia = $val; $plan.conto = $conto
    $plan.sin_pulla = [bool]$val -or [bool]$pregunta -or $conto
    $plan
}

# Conto algo (no pregunto): nombra a alguien y no es una pregunta.
function Conto-Algo([string]$q) {
    $q -notmatch '\?' -and $q -notmatch '(?i)^\W*(qu[eé]|c[oó]mo|cu[aá]l|cu[aá]nto|qui[eé]n|d[oó]nde|cu[aá]ndo|por qu[eé]|sabes|recuerdas|dime|h[aá]blame)\b'
}

# Reflexion (Park et al. 2023): cada 5 hechos, un resumen de rasgos SOLO de
# los hechos. Cada frase del resumen tiene que apoyarse en palabras de los
# hechos; si no, se descarta (el 8B tiende a adornar).
function Reflexionar($p, [string]$url = 'http://127.0.0.1:8099') {
    $hechos = @($p.hechos | ForEach-Object { $_.hecho })
    if ($hechos.Count -lt 5 -or $hechos.Count % 5) { return $null }
    $nom = if ($p.nombre) { $p.nombre } else { "su $($p.id)" }
    $cuerpo = @{
        messages = @(@{ role = 'user'; content = "Hechos que el usuario contó de $($nom):`n- " + ($hechos -join "`n- ") + "`n`nEscribe en español 1 o 2 frases cortas que resuman cómo es $nom, usando SOLO estos hechos. Nada que no esté en ellos." })
        max_tokens = 80; temperature = 0.2
        chat_template_kwargs = @{ enable_thinking = $false }
    } | ConvertTo-Json -Depth 5
    $r = Invoke-RestMethod "$url/v1/chat/completions" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($cuerpo)) -TimeoutSec 30
    $base = Plano-C ($hechos -join ' ')
    $frases = @([regex]::Split("$($r.choices[0].message.content)".Trim(), '(?<=[.!?])\s+') | Where-Object {
        $pal = @((Plano-C $_) -split '[^a-z0-9]+' | Where-Object { $_.Length -ge 5 })
        $pal.Count -and (@($pal | Where-Object { $base.Contains($_) }).Count / $pal.Count) -ge 0.5
    })
    if (-not $frases.Count) { return $null }
    $res = $frases -join ' '
    $p | Add-Member -NotePropertyName resumen -NotePropertyValue $res -Force
    Guardar-Persona $p
    $res
}

# Guarda un evento con fecha ("el viernes tiene examen") para preguntar despues.
function Guardar-Pendiente([string]$q, $ids) {
    $f = Fecha-De-Evento $q
    if (-not $f -or -not @($ids).Count) { return $null }
    $e = Leer-Estado-C
    $e.pendientes = @(@($e.pendientes | Where-Object { $_ }) + [pscustomobject]@{ persona = $ids[0]; frase = $q.Trim(); fecha = $f.ToString('yyyy-MM-dd'); preguntado = $false } | Select-Object -Last 30)
    Guardar-Estado-C $e
    $f.ToString('yyyy-MM-dd')
}

if ($MyInvocation.InvocationName -eq '.') { return }
# Comprobaciones sin modelo.
$mal = 0
$casos = @(
    @('Luis aprobó el examen de manejo', 'buena'), @('Mi hermana está en el hospital', 'mala'),
    @('Melly se fue de viaje ayer', ''), @('Luis ganó el torneo', 'buena'), @('Me peleé con Melly', 'mala')
)
foreach ($c in $casos) { $v = Valencia $c[0]; if ($v -ne $c[1]) { $mal++; "FALLA valencia: '$($c[0])' -> '$v' (tocaba '$($c[1])')" } }
$lunes = [datetime]'2026-09-21'
foreach ($c in @(@('mañana tiene examen', '2026-09-22'), @('el viernes juega', '2026-09-25'), @('la próxima semana viaja', '2026-09-28'), @('ayer fue al cine', ''))) {
    $f = Fecha-De-Evento $c[0] $lunes; $s = if ($f) { $f.ToString('yyyy-MM-dd') } else { '' }
    if ($s -ne $c[1]) { $mal++; "FALLA fecha: '$($c[0])' -> '$s' (tocaba '$($c[1])')" }
}
foreach ($c in @(@('le gusta el rock', 1), @('estudia medicina', 2), @('tiene miedo a volar', 3))) {
    if ((Capa-De $c[0]) -ne $c[1]) { $mal++; "FALLA capa: '$($c[0])' -> $(Capa-De $c[0])" }
}
if ($mal) { exit 2 }
Write-Host '12 comprobaciones OK' -ForegroundColor Green
