#Requires -Version 5.1
<#
La memoria de las PERSONAS de la vida del usuario, y la conversacion reciente.

POR QUE: lo pidio asi (2026-09-23): "tengo hermana, dos mejores amigos: Luis y
Melly; que sea curiosa solo cuando los mencione, y que cree y revise memoria de
ellos cuando los mencione o cuando no sepa de que hablar; que lo vaya
actualizando; quiero que este viva y curiosa". Su nombre y el de su hermana los
aprende hablando.

COMO (el patron de "Generative Agents": memoria, recuperacion y reflexion, en
pequeno y local):
  - Una ficha por persona en personas\<id>.json: nombre, alias, relacion,
    HECHOS con fecha (siempre de lo que dijo el usuario) y las preguntas que ya
    le hizo Ojo (para no repetirlas).
  - Recuperar: si la pregunta nombra a alguien, su ficha va al prompt.
  - Recordar: el modelo devuelve "recordar" con lo nuevo; aqui se guarda SOLO
    si sale de las palabras del usuario (se coteja con la pregunta).
  - Curiosidad: "curiosidad" es una pregunta para conocerle mejor; solo si esa
    persona se menciono (o si no hay tema), y se apunta para no repetirla.
  - Conversacion reciente: las ultimas 4 preguntas y respuestas de los ultimos
    15 minutos, para que "¿y ella?" o "¿seguro?" tengan contexto.

    . .\personas.ps1               (con punto) las funciones
    .\personas.ps1                 muestra las fichas
#>
$ErrorActionPreference = 'Stop'
$PERSONAS_DIR = Join-Path $PSScriptRoot 'personas'
$HISTORIAL = Join-Path $PSScriptRoot 'historial.json'
# Como se conoce a alguien (capas, noticias, pendientes, reflexion).
. (Join-Path $PSScriptRoot 'conocer.ps1')

function Plano-P([string]$s) { ($s.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '') }

# Las fichas de partida, si no existen. Neutras donde no se sabe (el genero de
# Melly, el nombre de su hermana y el suyo).
function Asegurar-Personas {
    New-Item -ItemType Directory -Force $PERSONAS_DIR | Out-Null
    $semillas = @(
        [ordered]@{ id = 'yo'; nombre = $null; alias = @(); relacion = 'el propio usuario' }
        [ordered]@{ id = 'hermana'; nombre = $null; alias = @('mi hermana', 'hermana'); relacion = 'hermana del usuario' }
        [ordered]@{ id = 'luis'; nombre = 'Luis'; alias = @('luis', 'lucho'); relacion = 'una de sus dos mejores amistades' }
        [ordered]@{ id = 'melly'; nombre = 'Melly'; alias = @('melly', 'meli', 'mely', 'melli'); relacion = 'una de sus dos mejores amistades' }
    )
    foreach ($s in $semillas) {
        $f = Join-Path $PERSONAS_DIR "$($s.id).json"
        if (-not (Test-Path $f)) {
            $s['hechos'] = @(); $s['preguntas_hechas'] = @()
            [IO.File]::WriteAllText($f, ($s | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
        }
    }
}

function Leer-Personas {
    Asegurar-Personas
    @(Get-ChildItem $PERSONAS_DIR -Filter '*.json' | ForEach-Object { [IO.File]::ReadAllText($_.FullName, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json })
}

function Guardar-Persona($p) {
    [IO.File]::WriteAllText((Join-Path $PERSONAS_DIR "$($p.id).json"), ($p | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
}

# Quien sale en la pregunta: por alias o por nombre, palabra entera.
function Personas-Mencionadas([string]$q, $personas) {
    $pq = " $(Plano-P $q) " -replace '[^a-z0-9 ]', ' '
    @($personas | Where-Object {
        $p = $_
        $claves = @(@($p.alias) + @($p.nombre) | Where-Object { $_ } | ForEach-Object { Plano-P $_ })
        @($claves | Where-Object { $pq -match "\b$([regex]::Escape($_))\b" }).Count -gt 0
    })
}

# "No se de que hablar": se le da pie a la curiosidad.
function Pide-Tema([string]$q) {
    $q -match '(?i)cu[eé]ntame algo|de qu[eé] hablamos|habl(ame|emos) de algo|me aburro|estoy aburrid|dime algo|sorpr[eé]ndeme|qu[eé] me cuentas'
}

function Ficha-Texto($p) {
    $quien = if ($p.id -eq 'yo') { 'EL USUARIO (con quien hablas)' } else { $p.relacion }
    $nom = if ($p.nombre) { "se llama $($p.nombre)" } else { 'AUN NO SABES SU NOMBRE' }
    $h = @($p.hechos | Select-Object -Last 12 | ForEach-Object { "  - $($_.hecho) ($($_.fecha))" })
    $ya = @($p.preguntas_hechas | Select-Object -Last 6 | ForEach-Object { "  - $_" })
    "[$($p.id)] $quien; $nom." +
        $(if ($p.resumen) { "`n en resumen (de sus hechos): $($p.resumen)" } else { '' }) +
        $(if ($h) { "`n lo que sabes (te lo dijo el usuario):`n" + ($h -join "`n") } else { "`n aun no sabes nada de esta persona." }) +
        $(if ($ya) { "`n preguntas que YA le hiciste (no las repitas):`n" + ($ya -join "`n") } else { '' })
}

# El bloque para el prompt: el usuario siempre (corto); las personas nombradas
# (o, si pide tema, la que menos conoces), enteras.
function Personas-Texto([string]$q, $personas) {
    $yo = $personas | Where-Object id -eq 'yo' | Select-Object -First 1
    $nombradas = @(Personas-Mencionadas $q $personas | Where-Object id -ne 'yo')
    $tema = $false
    if (-not $nombradas.Count -and (Pide-Tema $q)) {
        $nombradas = @($personas | Where-Object id -ne 'yo' | Sort-Object { @($_.hechos).Count } | Select-Object -First 1)
        $tema = $true
    }
    $t = "`n`nPERSONAS DE SU VIDA (su memoria; solo lo que te conto):`n" + (Ficha-Texto $yo)
    foreach ($p in $nombradas) { $t += "`n" + (Ficha-Texto $p) }
    if ($tema -and $nombradas.Count) { $t += "`n(No tiene tema: pregunta con curiosidad por [$($nombradas[0].id)].)" }
    [pscustomobject]@{ texto = $t; ids = @($nombradas | ForEach-Object { $_.id }); tema = $tema }
}

# Lo que el modelo quiere recordar, guardado SOLO si sale de las palabras del
# usuario: al menos dos palabras de 4+ letras del hecho (o el nombre propio)
# tienen que estar en la pregunta. Si trae "se llama X", se apunta el nombre.
#
# Y SOLO si CONTO algo, no si pregunto: a "¿Quien gano el ultimo mundial de
# League of Legends?" el 8B "recordo" el perfil del usuario ("juego League of
# Legends, Hearthstone...") y paso el cotejo por compartir "league" y
# "legends" (banco-verdad, 2026-09-23).
function Guardar-Recuerdos([string]$q, $recordar, $personas) {
    if (-not (Conto-Algo $q)) { return @() }
    $pq = Plano-P $q
    $guardados = @()
    foreach ($r in @($recordar)) {
        if (-not $r -or -not "$($r.hecho)".Trim()) { continue }
        $p = $personas | Where-Object id -eq "$($r.persona)" | Select-Object -First 1
        if (-not $p) { continue }
        $hecho = "$($r.hecho)".Trim()
        $pal = @((Plano-P $hecho) -split '[^a-z0-9]+' | Where-Object { $_.Length -ge 4 } | Select-Object -Unique)
        $enPregunta = @($pal | Where-Object { $pq.Contains($_) }).Count
        $nombre = if ($hecho -match '(?i)se llama ([\p{Lu}][\p{L}]+)') { $Matches[1] } elseif ($hecho -match '(?i)su nombre es ([\p{Lu}][\p{L}]+)') { $Matches[1] }
        if ($nombre -and -not $pq.Contains((Plano-P $nombre))) { $nombre = $null }
        if ($enPregunta -lt 2 -and -not $nombre) { continue }
        if ($nombre) {
            $p.nombre = $nombre
            $p.alias = @(@($p.alias) + (Plano-P $nombre) | Select-Object -Unique)
        }
        # El mas nuevo gana: se quita un hecho viejo casi igual (mismas primeras palabras).
        $ini = ($pal | Select-Object -First 3) -join ' '
        $p.hechos = @(@($p.hechos) | Where-Object { (((Plano-P $_.hecho) -split '[^a-z0-9]+' | Where-Object { $_.Length -ge 4 } | Select-Object -First 3) -join ' ') -ne $ini }) +
                    [pscustomobject]@{ hecho = $hecho; fecha = (Get-Date -Format 'yyyy-MM-dd'); capa = (Capa-De $hecho) }
        Guardar-Persona $p
        $guardados += "$($p.id): $hecho"
    }
    $guardados
}

# La curiosidad, apuntada para no repetirla. Solo vale para alguien que salio
# en la pregunta (o el elegido cuando no hay tema).
function Apuntar-Curiosidad($curiosidad, $idsValidos, $personas) {
    if (-not $curiosidad -or -not "$($curiosidad.pregunta)".Trim()) { return $null }
    if (@($idsValidos) -notcontains "$($curiosidad.persona)") { return $null }
    $p = $personas | Where-Object id -eq "$($curiosidad.persona)" | Select-Object -First 1
    $preg = "$($curiosidad.pregunta)".Trim()
    if (@($p.preguntas_hechas | ForEach-Object { Plano-P $_ }) -contains (Plano-P $preg)) { return $null }
    $p.preguntas_hechas = @(@($p.preguntas_hechas) + $preg | Select-Object -Last 20)
    Guardar-Persona $p
    $preg
}

# Los NOMBRES dichos tal cual ("me llamo X", "mi hermana se llama X") se
# guardan aqui, sin esperar al modelo: en la prueba, a "Me llamo Bishop" el 8B
# no relleno "recordar". Devuelve lo que guardo.
function Nombres-Directos([string]$q, $personas) {
    $hechos = @()
    $reglas = @(
        @('yo', '(?i)\b(?:me llamo|mi nombre es|ll[aá]mame)\s+([\p{Lu}][\p{L}]+)'),
        @('hermana', '(?i)\bmi hermana se llama\s+([\p{Lu}][\p{L}]+)')
    )
    foreach ($r in $reglas) {
        if ($q -cmatch $r[1] -or $q -match $r[1]) {
            $nombre = $Matches[1]
            $nombre = $nombre.Substring(0, 1).ToUpper() + $nombre.Substring(1)
            $p = $personas | Where-Object id -eq $r[0] | Select-Object -First 1
            if ($p -and $p.nombre -ne $nombre) {
                $p.nombre = $nombre
                $p.alias = @(@($p.alias) + (Plano-P $nombre) | Where-Object { $_ } | Select-Object -Unique)
                Guardar-Persona $p
                $hechos += "$($r[0]): se llama $nombre"
            }
        }
    }
    $hechos
}

# ---- Conversacion reciente ---------------------------------------------------

# En PowerShell 5.1, ConvertFrom-Json saca un array JSON como UN objeto
# (Object[]): sin desenrollarlo, $_.t era un array y [datetime] reventaba, y
# con el toda la memoria de personas de esa pregunta.
function Leer-Historial {
    $j = try { [IO.File]::ReadAllText($HISTORIAL, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json } catch { $null }
    $j | ForEach-Object { $_ } | Where-Object { $_ -and $_.t -is [string] }
}

function Historial-Texto {
    $h = @(Leer-Historial)
    $h = @($h | Where-Object { $_ -and [datetime]$_.t -gt (Get-Date).AddMinutes(-15) } | Select-Object -Last 4)
    if (-not $h.Count) { return '' }
    "`n`nCONVERSACION RECIENTE (ultimos 15 min; para entender 'y ella', 'seguro?'):`n" +
        (($h | ForEach-Object { "usuario: $($_.q)`nojo: $($_.a)" }) -join "`n")
}

function Apuntar-Historial([string]$q, [string]$a) {
    $h = @(@(Leer-Historial) + [pscustomobject]@{ t = (Get-Date).ToString('o'); q = $q; a = $a } | Select-Object -Last 10)
    [IO.File]::WriteAllText($HISTORIAL, (ConvertTo-Json @($h) -Depth 3), [Text.UTF8Encoding]::new($false))
}

if ($MyInvocation.InvocationName -eq '.') { return }
Leer-Personas | ForEach-Object { Ficha-Texto $_; '' }
