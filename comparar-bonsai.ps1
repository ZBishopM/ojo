<#
Bonsai contra el 8B de Ojo, con los mismos bancos que decidieron el Q6_K. Sin
microfono: para correr cuando nadie use el PC (para el supervisor y ocupa la
tarjeta unos 20-30 minutos).

CRITERIO, escrito ANTES de medir (2026-09-22): Bonsai pasa a la sesion con
microfono solo si gana al 8B en VISION o en PARTIDA y no pierde mas de un 20%
de velocidad de generacion. Si no, se cierra y se anota por que.

POR QUE ASI: la sesion con microfono mide sobre todo la fontaneria (oido,
captura, overlay), que es igual para los dos modelos. Lo que depende del modelo
-- ver, senalar, contestar en partida, razonar -- ya tiene bancos automaticos y
reproducibles, y no gasta el tiempo del usuario.

    .\comparar-bonsai.ps1
#>
param([string]$Raiz = 'D:\2026-projects\ojo')
$ErrorActionPreference = 'Stop'

$MODELOS = [ordered]@{
    '8b' = @{
        exe = 'F:\ai\llama.cpp\llama-server.exe'
        gguf = 'F:\ai\models\qwen3-vl-8b\Qwen3-VL-8B-Instruct-Q6_K.gguf'
        mmproj = 'F:\ai\models\qwen3-vl-8b\mmproj-F16.gguf'
        extra = @('-ctk', 'q8_0', '-ctv', 'q8_0', '--no-warmup')
    }
    'bonsai' = @{
        exe = 'F:\ai\llama.cpp-prism\llama-server.exe'
        gguf = 'F:\ai\models\bonsai-2-27b\Ternary-Bonsai-2-27B-PQ2_0.gguf'
        mmproj = 'F:\ai\models\bonsai-2-27b\Ternary-Bonsai-2-27B-mmproj-BF16.gguf'
        extra = @()
    }
}

function Matar-Llama { Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" -EA SilentlyContinue | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }; Start-Sleep -Seconds 3 }
function Libre { [int](((& nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits) | Select-Object -First 1).Trim()) }
function Levantar($m) {
    $a = @('--model', $m.gguf, '--mmproj', $m.mmproj, '--ctx-size', '8192', '--n-gpu-layers', '99',
           '--flash-attn', 'on', '--threads', '6', '--parallel', '1', '--load-mode', 'none', '--cache-ram', '1024',
           '--port', '8099', '--host', '127.0.0.1', '--log-file', "$Raiz\comparar-bonsai.log") + $m.extra
    Start-Process $m.exe -ArgumentList $a -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 600; $i++) { Start-Sleep -Milliseconds 500; try { if ((Invoke-RestMethod http://127.0.0.1:8099/health -TimeoutSec 2).status -eq 'ok') { return } } catch { } }
    throw "no arranco $($m.gguf)"
}
function Velocidad {
    $v = foreach ($i in 1..3) {
        $b = @{ messages = @(@{ role = 'user'; content = 'Escribe exactamente cien palabras sobre el mar.' }); max_tokens = 120
                chat_template_kwargs = @{ enable_thinking = $false } } | ConvertTo-Json -Depth 5
        (Invoke-RestMethod http://127.0.0.1:8099/v1/chat/completions -Method Post -ContentType 'application/json' `
            -Body ([Text.Encoding]::UTF8.GetBytes($b)) -TimeoutSec 600).timings.predicted_per_second
    }
    [math]::Round((@($v) | Sort-Object)[1], 1)   # mediana de tres
}

# ---- El supervisor fuera mientras tanto, o relanza el modelo de Ojo encima ----
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'rice-supervisor\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Matar-Llama

$res = [ordered]@{}
try {
    foreach ($k in $MODELOS.Keys) {
        $m = $MODELOS[$k]
        $v = & "$Raiz\banco-vision.ps1" -Nombre "comparar-$k" -Modelo $m.gguf -Mmproj $m.mmproj -Extra $m.extra -Exe $m.exe
        Matar-Llama
        $libreAntes = Libre
        Levantar $m
        $p = & "$Raiz\banco-partida.ps1" -Nombre "comparar-$k" -Prompt partida -Vueltas 3
        $res[$k] = [ordered]@{
            vision_leer = $v.leer; vision_senalar = $v.senalar; vision_px = $v.px_mediana
            partida = $p.aciertos; partida_ms = $p.ms_medio
            tok_s = Velocidad
            vram_mib = $libreAntes - (Libre)
        }
        Matar-Llama
    }
} finally {
    # Supervisor de vuelta, LIMPIO (sin el entorno de quien lance esto).
    & pwsh -NoProfile -File "$env:USERPROFILE\.config\rice-lanzar-limpio.ps1" wscript.exe "$env:USERPROFILE\.config\rice-supervisor.vbs"
}

# ---- La decision, con el criterio de arriba ----
$ocho = $res['8b']; $bon = $res['bonsai']
$frac = { param($s) $a = $s -split '/'; [double]$a[0] / [double]$a[1] }
$ganaVision  = (& $frac $bon.vision_senalar) -gt (& $frac $ocho.vision_senalar) -or (& $frac $bon.vision_leer) -gt (& $frac $ocho.vision_leer)
$ganaPartida = (& $frac $bon.partida) -gt (& $frac $ocho.partida)
$velocidadOk = $bon.tok_s -ge 0.8 * $ocho.tok_s
$pasa = ($ganaVision -or $ganaPartida) -and $velocidadOk

$salida = [ordered]@{
    fecha = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    '8b' = $ocho; bonsai = $bon
    gana_vision = $ganaVision; gana_partida = $ganaPartida; velocidad_ok = $velocidadOk
    decision = if ($pasa) { 'Bonsai pasa a la sesion con microfono' } else { 'Bonsai se descarta para Ojo' }
}
$salida | ConvertTo-Json -Depth 4 | Set-Content "$Raiz\comparar-bonsai.json" -Encoding utf8
[pscustomobject]$salida
