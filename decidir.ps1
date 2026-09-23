#Requires -Version 5.1
<#
Decisiones de ruta TIPADAS, "a lo Jev", con el modelo local.

POR QUE: Jev (TypeSafe AI, 2026-09) popularizo el patron de pedirle a un modelo
DECISIONES con tipo y probabilidad en vez de texto. Jev es de nube, con lista de
espera y solo texto; mandarle las preguntas del usuario rompe el "todo local".
Aqui se hace lo mismo con el modelo que ya esta cargado: llama-server obliga
la forma con un esquema JSON (response_format) y da la probabilidad de cada
token (logprobs), que es la confianza de cada si/no.

Las decisiones son las mismas que toma hoy Decidir-Con-Reglas en ojo.ps1 con
expresiones regulares. banco-decidir.ps1 compara las dos; solo se usa esto si
gana.

Entrada: SOLO la pregunta. Nada de texto de la pantalla: es la via de
inyeccion documentada con Jev (un campo plantado movio una decision de 0,76 a
0,48).

    . .\decidir.ps1                    (con punto) Decidir-Con-Modelo
    .\decidir.ps1 "donde esta el boton de guardar"
#>
$ErrorActionPreference = 'Stop'

$DECIDIR_CAMPOS = 'lectura', 'sitio', 'web', 'personal', 'aumento', 'workspaces', 'metricas'
$DECIDIR_SISTEMA = @'
Clasificas la PREGUNTA que un usuario le hace a su asistente de escritorio.
No la contestas. Para cada campo, true o false:

- lectura: para contestar hay que LEER texto exacto que se ve en su pantalla
  (un mensaje, un numero, un titulo, lo que marca algo en pantalla).
- sitio: pide DONDE esta algo EN LA PANTALLA, o que se lo senale o muestre.
- web: la respuesta cambia con el tiempo y hay que buscarla en internet
  (precios, noticias, resultados, clima, versiones, parches, "lo ultimo").
  La hora y la fecha de hoy NO: las da el sistema.
- personal: es sobre SUS cosas (su pantalla, sus ventanas, sus archivos, su
  correo, su PC): internet no lo sabe.
- aumento: pide elegir entre los aumentos que le ofrecen ahora en el juego.
- workspaces: pregunta que ventanas o programas tiene abiertos.
- metricas: pregunta por RAM, VRAM, CPU, GPU, temperatura o consumo de su PC.
'@

function Decidir-Con-Modelo([string]$pregunta, [int]$Puerto = 8099) {
    $props = [ordered]@{}
    foreach ($c in $DECIDIR_CAMPOS) { $props[$c] = @{ type = 'boolean' } }
    $cuerpo = @{
        stream = $false; max_tokens = 80; temperature = 0
        chat_template_kwargs = @{ enable_thinking = $false }
        response_format = @{ type = 'json_schema'; json_schema = @{ name = 'decisiones'
            schema = @{ type = 'object'; properties = $props; required = $DECIDIR_CAMPOS; additionalProperties = $false } } }
        logprobs = $true; top_logprobs = 1
        messages = @(@{ role = 'system'; content = $DECIDIR_SISTEMA }, @{ role = 'user'; content = "PREGUNTA: $pregunta" })
    } | ConvertTo-Json -Depth 10 -Compress
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod "http://127.0.0.1:$Puerto/v1/chat/completions" -Method Post `
        -Body ([Text.Encoding]::UTF8.GetBytes($cuerpo)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
    $ms = $sw.ElapsedMilliseconds
    $v = "$($r.choices[0].message.content)" | ConvertFrom-Json
    # La confianza de cada campo: la probabilidad del token true/false que
    # eligio, en el orden del esquema (el servidor lo impone en ese orden).
    $probs = @(@($r.choices[0].logprobs.content) | Where-Object { "$($_.token)".Trim() -in 'true', 'false' } |
               ForEach-Object { [math]::Exp([double]$_.logprob) })
    $valores = [ordered]@{}; $confianza = [ordered]@{}
    for ($i = 0; $i -lt $DECIDIR_CAMPOS.Count; $i++) {
        $c = $DECIDIR_CAMPOS[$i]
        $valores[$c] = [bool]$v.$c
        $confianza[$c] = if ($i -lt $probs.Count) { [math]::Round($probs[$i], 3) } else { $null }
    }
    [pscustomobject]@{ valores = $valores; confianza = $confianza; ms = $ms }
}

if ($MyInvocation.InvocationName -eq '.') { return }
$x = Decidir-Con-Modelo ($args -join ' ')
foreach ($c in $DECIDIR_CAMPOS) { '{0,-11} {1,-5} ({2})' -f $c, $x.valores[$c], $x.confianza[$c] }
"--- $($x.ms) ms"
