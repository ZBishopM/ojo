<#
Banco de preguntas DE PARTIDA, con respuesta conocida, para elegir el prompt
con el que Ojo contesta mientras juegas.

POR QUE EXISTE: con el prompt de siempre ("miras la pantalla del usuario..."),
a "como es nuestra composicion?" el 8B contesto "Tu equipo lidera en KDA y CS"
sin nombrar un solo campeon, teniendo los cinco en los datos. El dia anterior,
con un prompt corto de partida, los nombro todos. Un cambio de prompt sin una
medida al lado es una intencion, no un arreglo.

La partida es la inventada de lol.ps1 (Lux en mid, 3.500 de oro, una Vara
innecesariamente grande, Yasuo muerto 13 s). Las respuestas correctas salen de
ella, no del modelo.

    .\banco-partida.ps1 -Nombre 8b-actual -Prompt actual
    .\banco-partida.ps1 -Nombre 8b-partida -Prompt partida
#>
param(
    [Parameter(Mandatory)][string]$Nombre,
    [ValidateSet('actual', 'partida')][string]$Prompt = 'partida',
    [int]$Vueltas = 2,
    [int]$Puerto = 8099,
    # Usa la partida REAL congelada (ARAM Mayhem, 2026-09-22) y las preguntas
    # que fallaron en ella, con la frase literal del usuario.
    [switch]$Real,
    [string]$Raiz = 'D:\2026-projects\ojo'
)
$ErrorActionPreference = 'Stop'
. "$Raiz\lol.ps1"
$cat = Get-DDragon
$partidaDatos = if ($Real) {
    [IO.File]::ReadAllText("$Raiz\prueba-lol\muestra-aram-mayhem.json", [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
} else { Partida-Inventada 'riotid' 3500 2 }
# Por pregunta: los aumentos que se mencionan cambian los datos.
function Hechos-De($q) { Resumir-Partida $partidaDatos $cat $q | ConvertTo-Json -Depth 6 -Compress }

# El prompt de Ojo de hoy, leido de ojo.ps1 para no desincronizarse.
$fuente = Get-Content "$Raiz\ojo.ps1" -Raw
$ACTUAL = [regex]::Match($fuente, "(?s)\`$SISTEMA = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
$PARTIDA = [regex]::Match($fuente, "(?s)\`$SISTEMA_PARTIDA = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
if ($Prompt -eq 'partida' -and -not $PARTIDA) { throw 'ojo.ps1 aun no tiene $SISTEMA_PARTIDA' }

# (pregunta, patron que DEBE aparecer en `decir`, sin tildes y en minusculas)
$CASOS = @(
    # Con tildes y el signo de apertura, que es como lo dice el usuario. Sin
    # ellos el 4B enumeraba el equipo; con ellos lo VALORABA ("tu equipo es muy
    # fragil") sin nombrarlo: 0 de 3.
    @{ q = '¿Cómo es nuestra composición?';         todos = @('annie', 'garen', 'lux', 'jinx', 'thresh') }
    @{ q = 'contra quien juego en mid?';            todos = @('yasuo') }
    @{ q = 'quien del equipo rival esta muerto?';   todos = @('yasuo', '13') }
    @{ q = 'cuanto oro tengo?';                     todos = @('3500|3\.500|3 500') }
    @{ q = 'en que minuto vamos?';                  todos = @('12') }
    @{ q = 'quien va mas fuerte en el equipo rival?'; todos = @('leona') }
    # Cualquiera de los cuatro que se terminan con la Vara que lleva. La primera
    # version solo aceptaba Rabadon o Zhonya, y el 4B contesto el Velo del hada
    # de la muerte -- que es el PRIMERO de la lista, el mas barato de terminar.
    # El fallo era de la prueba.
    # (Con los nombres del cliente latino: Llamasombria pasa a ser Lumbria.)
    @{ q = 'que item termino con lo que llevo?';    todos = @('velo|lumbria|llamasombria|zhonya|rabadon') }
    # "quien es SU jungla" era ambigua: "su" tambien es "de usted". El 8B
    # contesto con la del usuario, y no era un fallo suyo.
    @{ q = 'quien es la jungla del equipo rival?';  todos = @('darius') }
)

# La partida real: lo que fallo en la primera partida de verdad. `nunca` son
# cosas que NO deben aparecer (lo que invento aquel dia).
if ($Real) {
    $CASOS = @(
        # La frase literal, tal como la escribio el reconocimiento de voz. Debe
        # entender Jax, no inventar "la Locomotora de Jaxa", y proponer algo de
        # resistencia magica real (el usuario dice que Jax va AP).
        @{ q = 'Veo un Jacksa P con locomotora.¿Qué podría sacar?'
           todos = @('jax', 'caliz de la armonia|capa de negatrones|nucleo hex|anulamagia')
           nunca = @('jaxa', 'jacksa', 'locomotora de') }
        @{ q = '¿Qué hace Locomotora?';          todos = @('derribo|tamano|vida'); nunca = @() }
        # Aquel dia dijo "En este parche, Sylas suele ser fuerte..." sin ningun
        # dato que lo dijera.
        @{ q = '¿Cómo va la partida?';           todos = @('.');  nunca = @('parche', 'meta') }
        @{ q = '¿Qué daño hace el equipo rival?'; todos = @('elise'); nunca = @() }
    )
}

function Sin-Tildes($s) {
    $n = "$s".ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    -join ($n.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
}

$filas = @()
for ($v = 1; $v -le $Vueltas; $v++) {
    foreach ($c in $CASOS) {
        $hechos = Hechos-De $c.q
        $msgs = if ($Prompt -eq 'actual') {
            # Tal cual lo arma ojo.ps1 hoy: la pregunta, y los datos al final como memoria.
            @(@{ role = 'system'; content = $ACTUAL },
              @{ role = 'user'; content = "$($c.q)`n`nDATOS EXACTOS DE LA PARTIDA EN CURSO (te los da el propio juego, no los inventes ni los contradigas):`n$hechos" })
        } else {
            # Los datos primero y la pregunta al final: es el orden que se midio
            # mejor para la cache de prompts, y la pregunta queda donde el modelo
            # la lee ultima.
            @(@{ role = 'system'; content = $PARTIDA },
              @{ role = 'user'; content = "DATOS DE LA PARTIDA:`n$hechos`n`nPREGUNTA: $($c.q)" })
        }
        $cuerpo = @{ stream = $false; max_tokens = 200; temperature = 0.1
                     chat_template_kwargs = @{ enable_thinking = $false }; messages = $msgs } | ConvertTo-Json -Depth 8 -Compress
        $r = Invoke-RestMethod "http://127.0.0.1:$Puerto/v1/chat/completions" -Method Post -ContentType 'application/json' `
                -Body ([Text.Encoding]::UTF8.GetBytes($cuerpo)) -TimeoutSec 120
        $t = $r.choices[0].message.content
        $m = [regex]::Match($t, '(?s)\{.*\}')
        $dijo = if ($m.Success) { try { ($m.Value | ConvertFrom-Json).decir } catch { $t } } else { $t }
        $plano = Sin-Tildes $dijo
        $ok = -not ($c.todos | Where-Object { $plano -notmatch $_ }) -and
              -not (@($c.nunca) | Where-Object { $_ -and $plano -match $_ })
        $filas += [pscustomobject]@{ q = $c.q; ok = $ok; ms = [math]::Round($r.timings.prompt_ms + $r.timings.predicted_ms); dijo = $dijo }
    }
}
$modelo = [IO.Path]::GetFileNameWithoutExtension((Invoke-RestMethod "http://127.0.0.1:$Puerto/props").model_path)
$res = [ordered]@{
    nombre   = $Nombre
    modelo   = $modelo
    prompt   = $Prompt
    aciertos = "{0}/{1}" -f @($filas | Where-Object ok).Count, $filas.Count
    ms_medio = [math]::Round(($filas | Measure-Object ms -Average).Average)
    filas    = $filas
}
$f = "$Raiz\banco-partida.json"
$todas = @(if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json }) + [pscustomobject]$res
$todas | ConvertTo-Json -Depth 5 | Set-Content $f -Encoding utf8
[pscustomobject]$res
