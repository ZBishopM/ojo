# El bucle real: captura NUEVA en cada pasada, luego pregunta.
#
# Existe aparte de preguntar.ps1 porque repetir la misma imagen da un numero
# falsamente bueno: llama.cpp cachea el prefijo del prompt, y con la imagen
# repetida el primer token sale en ~158 ms cuando en la vida real hay que
# evaluar ~550 tokens de imagen desde cero. Este script mide lo segundo.
param(
    [int]$Puerto = 8099,
    [int]$Repetir = 5,
    [int]$MaxTokens = 60,
    [string]$Pregunta = 'Que aplicacion se ve y que esta haciendo el usuario? Una frase corta.',
    [string]$Captura = 'D:\2026-projects\ojo\captura\target\release\ojo-captura.exe'
)
$ErrorActionPreference = 'Stop'
$tmp = Join-Path $env:TEMP 'ojo-bucle.jpg'

$filas = @()
for ($i = 0; $i -lt $Repetir; $i++) {
    $tCap = [Diagnostics.Stopwatch]::StartNew()
    & $Captura --salida $tmp | Out-Null
    $tCap.Stop()

    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($tmp))
    $cuerpo = @{
        model = 'x'; stream = $true; max_tokens = $MaxTokens; temperature = 0.2
        chat_template_kwargs = @{ enable_thinking = $false }
        messages = @(@{ role = 'user'; content = @(
            @{ type = 'text'; text = $Pregunta },
            @{ type = 'image_url'; image_url = @{ url = "data:image/jpeg;base64,$b64" } }
        )})
    } | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($cuerpo)

    $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$Puerto/v1/chat/completions")
    $req.Method = 'POST'; $req.ContentType = 'application/json'; $req.Timeout = 300000
    $req.AllowWriteStreamBuffering = $false; $req.ContentLength = $bytes.Length

    $t = [Diagnostics.Stopwatch]::StartNew()
    $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
    $resp = $req.GetResponse()
    $sr = New-Object IO.StreamReader($resp.GetResponseStream())
    $primer = $null; $texto = ''
    while ($true) {
        $l = $sr.ReadLine(); if ($null -eq $l) { break }
        if (-not $l.StartsWith('data: ')) { continue }
        $d = $l.Substring(6); if ($d -eq '[DONE]') { break }
        $c = ($d | ConvertFrom-Json).choices[0].delta.content
        if ($c) { if ($null -eq $primer) { $primer = $t.Elapsed.TotalMilliseconds }; $texto += $c }
    }
    $t.Stop(); $sr.Dispose(); $resp.Dispose()
    if ($null -eq $primer) { throw "pasada $i sin tokens: comprobar enable_thinking" }

    $filas += [pscustomobject]@{
        captura_ms      = [math]::Round($tCap.Elapsed.TotalMilliseconds)
        primer_token_ms = [math]::Round($primer)
        total_ms        = [math]::Round($t.Elapsed.TotalMilliseconds)
        # Lo que de verdad oye el usuario: captura + primer token, porque el TTS
        # arranca con la primera frase sin esperar al resto.
        hasta_hablar_ms = [math]::Round($tCap.Elapsed.TotalMilliseconds + $primer)
        texto           = $texto.Trim()
    }
    Start-Sleep -Milliseconds 300
}

function P($v, $q) { $s = @($v) | Sort-Object; $s[[math]::Min($s.Count-1, [math]::Floor(($s.Count-1)*$q))] }
$h = $filas.hasta_hablar_ms
[pscustomobject]@{
    pasadas                  = $Repetir
    captura_mediana_ms       = P $filas.captura_ms 0.5
    primer_token_mediana_ms  = P $filas.primer_token_ms 0.5
    hasta_hablar_mediana_ms  = P $h 0.5
    hasta_hablar_p95_ms      = P $h 0.95
    total_mediana_ms         = P $filas.total_ms 0.5
    ultima_respuesta         = $filas[-1].texto
} | ConvertTo-Json
