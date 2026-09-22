# Mide un modelo de vision servido por llama-server: arranque, primer token y
# respuesta completa, sobre una captura real de la pantalla.
#
# Las dos cifras que deciden si el proyecto es viable:
#   - arranque_s          cuanto tarda en estar listo tras un arranque en frio
#   - primer_token_ms     el hueco de silencio antes de que pueda empezar a hablar
#
# El presupuesto de Ojo da 400-900 ms al primer token. Si no entra, no suena a
# conversacion por mucho que el resto este optimizado.
param(
    [string]$Modelo = 'F:\ai\models\Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf',
    [string]$Mmproj = 'F:\ai\models\mmproj-F16.gguf',
    [string]$Llama  = 'F:\ai\llama.cpp\llama-server.exe',
    [int]$Puerto    = 8099,
    [int]$NCpuMoe   = 24,
    [int]$Ctx       = 8192,
    [string]$Imagen = 'D:\2026-projects\ojo\muestra.jpg',
    [string]$Pregunta = 'Describe en una frase corta que aplicacion se ve en esta pantalla.',
    # b11056 sustituyo --no-mmap por --load-mode. Modos: auto | none | mmap |
    # mmap+mlock. 'none' es el equivalente del viejo --no-mmap (carga a RAM).
    [ValidateSet('auto','none','mmap','mmap+mlock')][string]$Carga = 'none'
)

$ErrorActionPreference = 'Stop'
function Vram { (& nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits) -as [int] }

if (-not (Test-Path $Imagen)) { throw "falta la captura de prueba en $Imagen" }
Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

$vramAntes = Vram
$args = @(
    '--model', $Modelo, '--mmproj', $Mmproj,
    '--ctx-size', $Ctx, '--n-cpu-moe', $NCpuMoe, '--n-gpu-layers', '99',
    '--flash-attn', 'on', '--threads', '6', '--parallel', '1', '--load-mode', $Carga,
    '--port', $Puerto, '--host', '127.0.0.1'
)
$log = 'D:\2026-projects\ojo\llama-medicion.log'
$sw = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Process $Llama -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardError $log -RedirectStandardOutput "$log.out"

# Esperar a /health en vez de dormir a ojo: el arranque depende del disco y del
# reparto CPU/GPU, y dormir un numero fijo mide el sleep, no el servidor.
$listo = $false
while ($sw.Elapsed.TotalSeconds -lt 400) {
    Start-Sleep -Milliseconds 500
    if ($p.HasExited) { throw "llama-server murio. Ultimas lineas:`n" + (Get-Content $log -Tail 15 -EA SilentlyContinue | Out-String) }
    try {
        $h = Invoke-RestMethod "http://127.0.0.1:$Puerto/health" -TimeoutSec 2
        if ($h.status -eq 'ok') { $listo = $true; break }
    } catch { }
}
$sw.Stop()
if (-not $listo) { $p | Stop-Process -Force; throw "no arranco en 400 s" }
$arranque = $sw.Elapsed.TotalSeconds
$vramCargado = Vram

# La peticion se hace en streaming para poder cronometrar el PRIMER token, que
# es lo que fija cuando puede empezar a hablar. El total importa mucho menos.
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Imagen))
$cuerpo = @{
    model = 'x'; stream = $true; max_tokens = 120; temperature = 0.2
    messages = @(@{ role = 'user'; content = @(
        @{ type = 'text'; text = $Pregunta },
        @{ type = 'image_url'; image_url = @{ url = "data:image/jpeg;base64,$b64" } }
    )})
} | ConvertTo-Json -Depth 8 -Compress

$req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$Puerto/v1/chat/completions")
$req.Method = 'POST'; $req.ContentType = 'application/json'; $req.Timeout = 300000
$bytes = [Text.Encoding]::UTF8.GetBytes($cuerpo)
$t = [Diagnostics.Stopwatch]::StartNew()
$req.GetRequestStream().Write($bytes, 0, $bytes.Length)
$sr = New-Object IO.StreamReader($req.GetResponse().GetResponseStream())

$primer = $null; $texto = ''
while (-not $sr.EndOfStream) {
    $l = $sr.ReadLine()
    if (-not $l.StartsWith('data: ')) { continue }
    $d = $l.Substring(6); if ($d -eq '[DONE]') { break }
    $c = ($d | ConvertFrom-Json).choices[0].delta.content
    if ($c) { if ($null -eq $primer) { $primer = $t.Elapsed.TotalMilliseconds }; $texto += $c }
}
$t.Stop()
$sr.Dispose()

[pscustomobject]@{
    build           = (& $Llama --version 2>&1 | Select-String 'build' | ForEach-Object { $_.ToString().Trim() })
    disco           = $Modelo.Substring(0,2)
    gb_modelo       = [math]::Round((Get-Item $Modelo).Length/1GB, 2)
    n_cpu_moe       = $NCpuMoe
    carga           = $Carga
    arranque_s      = [math]::Round($arranque, 1)
    primer_token_ms = [math]::Round($primer, 0)
    total_ms        = [math]::Round($t.Elapsed.TotalMilliseconds, 0)
    tokens_aprox    = [math]::Round($texto.Length / 4)
    vram_antes_mb   = $vramAntes
    vram_cargado_mb = $vramCargado
    vram_modelo_mb  = $vramCargado - $vramAntes
    respuesta       = $texto.Trim()
} | ConvertTo-Json

$p | Stop-Process -Force

