#Requires -Version 5.1
<#
El humor de Ojo, aprendido de internet: memes y tendencias ACTUALES.

POR QUE: el usuario quiere que la pulla no salga solo del entrenamiento del
modelo (desfasado), sino que "consulte en internet los ultimos memes y
tendencias y vaya apuntando lo que aprende". Aqui se apunta.

COMO: busca en el SearXNG local (buscar.ps1) memes y tendencias recientes, en
general, de Latinoamerica, de videojuegos y de League; el modelo de Ojo resume
cada referencia CON SUS PALABRAS (que es, de que va, como usarla en una pulla)
y se guarda con su fuente y fecha en humor\referencias.json. Caducan a los 30
dias: un meme viejo no es gracioso, es viejo.

No se copian textos de las paginas: solo el resumen propio y la fuente.

Lo lanza ojo.ps1 con la PRIMERA pregunta de cada dia, en segundo plano (un
evento, no un temporizador). ojo.ps1 pasa las mas recientes al modelo para la
pulla (Referencias-Humor).

    .\humor.ps1 -Aprender          busca y apunta (tarda ~30-60 s)
    .\humor.ps1                    lista lo aprendido
    . .\humor.ps1                  (con punto) Referencias-Humor
#>
$ErrorActionPreference = 'Stop'
$HUMOR_ARCHIVO = Join-Path $PSScriptRoot 'humor\referencias.json'
# Consultas que traen paginas que EXPLICAN el meme, no galerias de titulos: con
# "memes del momento" salian titulos sueltos de memedroid y el modelo los
# pegaba todos en una referencia de 150 caracteres.
$HUMOR_CONSULTAS = @(
    'que significa el meme viral de esta semana'
    'meme del momento explicado origen'
    'tendencias en redes sociales esta semana memes'
    'meme viral gamers significado'
)
# Lo que no entra aunque el modelo lo proponga: burlas del fisico, insultos,
# tragedias. ponytail: lista corta a mano; ampliarla si se cuela algo.
$HUMOR_VETADO = '(?i)gord|grasa|feo|fea\b|retrasad|mongol|negr[oa]s?\b|maric|put[ao]|violaci|suicid|muert[oa]s?\b|tragedi|nazi|terroris'

function Leer-Humor {
    if (-not (Test-Path $HUMOR_ARCHIVO)) { return [pscustomobject]@{ actualizado = ''; referencias = @() } }
    [IO.File]::ReadAllText($HUMOR_ARCHIVO, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
}

# Las N mas recientes, como bloque para el prompt de Ojo.
function Referencias-Humor([int]$n = 8) {
    $h = Leer-Humor
    $r = @($h.referencias | Sort-Object fecha -Descending | Select-Object -First $n)
    if (-not $r.Count) { return '' }
    "`n`nREFERENCIAS DE HUMOR ACTUALES (aprendidas de internet; opcionales, solo para la pulla):`n" +
        (($r | ForEach-Object { "- $($_.referencia): $($_.como_usarla)" }) -join "`n")
}

function Aprender-Humor([int]$Puerto = 8099) {
    . "$PSScriptRoot\buscar.ps1"
    $hoy = Get-Date -Format 'yyyy-MM-dd'
    $sistema = @'
Lees resultados de busqueda sobre memes y tendencias recientes y apuntas las
REFERENCIAS de humor que un asistente sarcastico podria usar en una pulla
corta, en espanol latino.

Respondes SOLO con un array JSON, sin texto alrededor:
[{"referencia": "<nombre corto del meme o tendencia>",
  "de_que_va": "<una frase, con tus palabras>",
  "como_usarla": "<una frase: en que situacion encaja en una pulla>",
  "fuente": "<el sitio de donde lo sacaste, tal como aparece entre corchetes>"}]

Reglas:
- Solo referencias que aparezcan en los resultados. Nada de tu memoria.
- Con tus palabras: no copies frases de las paginas.
- Nada ofensivo, de odio, sexual ni sobre tragedias o personas privadas.
- UNA entrada por referencia: nunca juntes varios memes en una.
- Entre 0 y 4 referencias; ninguna si no hay material bueno.
'@
    # El esquema lo impone el servidor (llama-server, response_format): una
    # entrada por meme y con tope de largo. Sin el, juntaba cinco en una.
    $esquema = @{
        type = 'array'; maxItems = 4
        items = @{ type = 'object'; required = @('referencia', 'de_que_va', 'como_usarla', 'fuente')
                   properties = @{ referencia = @{ type = 'string'; maxLength = 50 }; de_que_va = @{ type = 'string'; maxLength = 160 }
                                   como_usarla = @{ type = 'string'; maxLength = 160 }; fuente = @{ type = 'string'; maxLength = 40 } } }
    }
    # Una llamada por busqueda: con todo junto se mezclaban.
    $nuevas = @(foreach ($q in $HUMOR_CONSULTAS) {
        $b = Buscar-Web @($q)
        if (-not @($b.fuentes).Count) { continue }
        $cuerpo = @{
            stream = $false; max_tokens = 700; temperature = 0.2
            chat_template_kwargs = @{ enable_thinking = $false }
            response_format = @{ type = 'json_schema'; json_schema = @{ name = 'referencias'; schema = $esquema } }
            messages = @(@{ role = 'system'; content = $sistema }, @{ role = 'user'; content = (Texto-Web $b) })
        } | ConvertTo-Json -Depth 10 -Compress
        try {
            $r = Invoke-RestMethod "http://127.0.0.1:$Puerto/v1/chat/completions" -Method Post `
                -Body ([Text.Encoding]::UTF8.GetBytes($cuerpo)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 120
            @("$($r.choices[0].message.content)" | ConvertFrom-Json)
        } catch { Write-Warning "no pude resumir '$q': $_" }
    }) | Where-Object { $_.referencia -and $_.como_usarla -and "$($_.referencia) $($_.de_que_va) $($_.como_usarla)" -notmatch $HUMOR_VETADO } |
        ForEach-Object { [pscustomobject]@{ referencia = "$($_.referencia)"; de_que_va = "$($_.de_que_va)"; como_usarla = "$($_.como_usarla)"
                                            fuente = "$($_.fuente)"; fecha = $hoy } }
    if (-not $nuevas.Count) { Write-Warning 'no salio ninguna referencia buena'; return }
    # Se juntan con lo ya aprendido: sin repetir (por nombre) y sin lo caducado.
    $limite = (Get-Date).AddDays(-30).ToString('yyyy-MM-dd')
    $vistas = @{}
    $todas = @(@($nuevas) + @((Leer-Humor).referencias) | Where-Object { $_ -and $_.fecha -ge $limite } | Where-Object {
        $k = "$($_.referencia)".ToLowerInvariant().Trim()
        if ($vistas[$k]) { $false } else { $vistas[$k] = 1; $true }
    } | Select-Object -First 40)
    New-Item -ItemType Directory -Force (Split-Path $HUMOR_ARCHIVO) | Out-Null
    $h = [ordered]@{ actualizado = $hoy; referencias = $todas }
    [IO.File]::WriteAllText($HUMOR_ARCHIVO, ($h | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    "$($nuevas.Count) nuevas, $($todas.Count) en total"
}

if ($MyInvocation.InvocationName -eq '.') { return }
if ($args -contains '-Aprender') { Aprender-Humor; exit 0 }
(Leer-Humor).referencias | Format-Table referencia, fecha, fuente -AutoSize
