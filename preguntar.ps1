# Una pregunta con imagen contra un llama-server YA cargado, cronometrando el
# primer token. Se separa de medir-vlm.ps1 a proposito: recargar el modelo para
# cada prueba cuesta minutos y aqui interesa iterar sobre el prompt.
#
# El primer token es la cifra que manda: es el silencio que el usuario oye antes
# de que la voz pueda empezar. El total importa mucho menos porque el TTS va
# arrancando con la primera frase.
param(
    [int]$Puerto = 8099,
    [string]$Imagen = 'D:\2026-projects\ojo\muestra.jpg',
    [string]$Pregunta = 'Describe en una frase corta que aplicacion se ve en esta pantalla.',
    [int]$MaxTokens = 80,
    [int]$Repetir = 1
)
$ErrorActionPreference = 'Stop'

$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Imagen))
$cuerpo = @{
    model = 'x'; stream = $true; max_tokens = $MaxTokens; temperature = 0.2
    # IMPRESCINDIBLE. Qwen3.x razona por defecto aunque la documentacion diga lo
    # contrario: el razonamiento va a `reasoning_content`, `content` sale VACIO,
    # y se agota el limite de tokens pensando. Medido aqui sobre el 35B:
    # 4.465 ms y respuesta vacia con razonamiento; 361 ms y "Discord" sin el.
    chat_template_kwargs = @{ enable_thinking = $false }
    messages = @(@{ role = 'user'; content = @(
        @{ type = 'text'; text = $Pregunta },
        @{ type = 'image_url'; image_url = @{ url = "data:image/jpeg;base64,$b64" } }
    )})
} | ConvertTo-Json -Depth 8 -Compress
$bytes = [Text.Encoding]::UTF8.GetBytes($cuerpo)

$primeros = @(); $totales = @(); $ultimo = ''
for ($i = 0; $i -lt $Repetir; $i++) {
    $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$Puerto/v1/chat/completions")
    $req.Method = 'POST'; $req.ContentType = 'application/json'; $req.Timeout = 300000
    # Sin esto .NET junta escrituras y el reloj del primer token sale tarde.
    $req.AllowWriteStreamBuffering = $false
    $req.ContentLength = $bytes.Length

    $t = [Diagnostics.Stopwatch]::StartNew()
    $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
    $resp = $req.GetResponse()
    $sr = New-Object IO.StreamReader($resp.GetResponseStream())

    $primer = $null; $texto = ''
    while ($true) {
        $l = $sr.ReadLine()
        # ReadLine devuelve $null al cerrarse el flujo; EndOfStream se queda
        # bloqueado en SSE y por eso se comprueba asi.
        if ($null -eq $l) { break }
        if (-not $l.StartsWith('data: ')) { continue }
        $d = $l.Substring(6)
        if ($d -eq '[DONE]') { break }
        $c = ($d | ConvertFrom-Json).choices[0].delta.content
        if ($c) {
            if ($null -eq $primer) { $primer = $t.Elapsed.TotalMilliseconds }
            $texto += $c
        }
    }
    $t.Stop(); $sr.Dispose(); $resp.Dispose()
    if ($null -eq $primer) {
        throw "no llego ningun token en la pasada $i. Casi siempre significa que el modelo razono y dejo `content` vacio: comprobar enable_thinking."
    }
    $primeros += $primer; $totales += $t.Elapsed.TotalMilliseconds; $ultimo = $texto
}

function Mediana($v) { $s = @($v) | Sort-Object; $s[[math]::Floor($s.Count/2)] }
[pscustomobject]@{
    pasadas              = $Repetir
    primer_token_ms      = [math]::Round((Mediana $primeros))
    total_ms             = [math]::Round((Mediana $totales))
    caracteres           = $ultimo.Length
    respuesta            = $ultimo.Trim()
} | ConvertTo-Json
