<#
Cuanta VRAM ocupa una configuracion de llama-server, desglosada, y a que
velocidad genera. Para comparar palancas de una en una.

POR QUE EXISTE: el 2026-09-22 el 8B paso de 50,66 a 12,4 tok/s en 25 minutos
SIN ningun juego abierto. Firefox, dwm y Discord crecieron un poco y Windows
desalojo 888 MiB del modelo a RAM, porque el 8B dejaba solo ~300 MiB libres.
Para darle margen hay que saber primero en que se va cada MiB.

    .\medir-vram.ps1 -Nombre base
    .\medir-vram.ps1 -Nombre kv8 -Extra '-ctk','q8_0','-ctv','q8_0'

Deja una fila en medir-vram.json. Necesita el puerto 8099 libre: para el
supervisor antes, o lo revive encima.
#>
param(
    [Parameter(Mandatory)][string]$Nombre,
    [string[]]$Extra = @(),
    [string]$Modelo = 'F:\ai\models\qwen3-vl-8b\Qwen3-VL-8B-Instruct-Q8_0.gguf',
    [string]$Mmproj = 'F:\ai\models\qwen3-vl-8b\mmproj-F16.gguf',
    [int]$Ctx = 8192,
    [string]$Imagen = 'D:\2026-projects\ojo\escenas\captura-referencia.jpg',
    [string]$Raiz = 'D:\2026-projects\ojo'
)
$ErrorActionPreference = 'Stop'
$llama = 'F:\ai\llama.cpp\llama-server.exe'
$log = "$Raiz\medir-vram.log"

function Libre { [int](((& nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits) | Select-Object -First 1).Trim()) }
function Matar { Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" | Where-Object { $_.CommandLine -match '--port 8099' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue } }

# Memoria de GPU del proceso, por los contadores de rendimiento. Es la unica
# forma de ver la parte DESALOJADA: nvidia-smi en WDDM solo cuenta la
# dedicada. Se lee por WMI y no con Get-Counter, que en es-ES falla en silencio
# porque los nombres de contador van traducidos.
function Memoria-Gpu($procId) {
    $c = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory |
         Where-Object { $_.Name -like "pid_$($procId)_*" }
    @{ dedicada = [int](($c | Measure-Object DedicatedUsage -Sum).Sum / 1MB)
       compartida = [int](($c | Measure-Object SharedUsage -Sum).Sum / 1MB) }
}

Matar; Start-Sleep -Seconds 3
$libreAntes = Libre

$a = @('--model', $Modelo) + @(if ($Mmproj) { '--mmproj', $Mmproj }) +
     @('--ctx-size', "$Ctx", '--n-gpu-layers', '99', '--flash-attn', 'on', '--threads', '6',
       '--parallel', '1', '--load-mode', 'none', '--cache-ram', '1024',
       '--port', '8099', '--host', '127.0.0.1', '-lv', '4') + $Extra
$p = Start-Process $llama -ArgumentList $a -WindowStyle Hidden -PassThru `
        -RedirectStandardError $log -RedirectStandardOutput "$log.out"
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 180) {
    Start-Sleep -Milliseconds 300
    try { if ((Invoke-RestMethod http://127.0.0.1:8099/health -TimeoutSec 2).status -eq 'ok') { break } } catch { }
}
$carga = [math]::Round($sw.Elapsed.TotalSeconds, 1)

# Una pregunta CON imagen, que es lo que hace Ojo: asi se reservan tambien los
# bufers de la vision, que no existen hasta la primera imagen.
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Imagen))
$img = @{ messages = @(@{ role = 'user'; content = @(
            @{ type = 'image_url'; image_url = @{ url = "data:image/jpeg;base64,$b64" } },
            @{ type = 'text'; text = 'Describe esta pantalla en una frase.' }) })
          max_tokens = 40; chat_template_kwargs = @{ enable_thinking = $false } } | ConvertTo-Json -Depth 8 -Compress
$ri = Invoke-RestMethod http://127.0.0.1:8099/v1/chat/completions -Method Post -ContentType 'application/json' `
        -Body ([Text.Encoding]::UTF8.GetBytes($img)) -TimeoutSec 300

$txt = @{ messages = @(@{ role = 'user'; content = 'Escribe exactamente cien palabras sobre el mar.' })
          max_tokens = 150; chat_template_kwargs = @{ enable_thinking = $false } } | ConvertTo-Json -Depth 5
$rt = Invoke-RestMethod http://127.0.0.1:8099/v1/chat/completions -Method Post -ContentType 'application/json' `
        -Body ([Text.Encoding]::UTF8.GetBytes($txt)) -TimeoutSec 300

$mg = Memoria-Gpu $p.Id
$libreDespues = Libre

# Los bufers, tal como los declara el propio servidor.
$bufs = Select-String -Path $log -Pattern 'buffer size\s*=\s*([\d.]+) MiB' |
        ForEach-Object { ($_.Line -replace '^.*?\b(\w+)\s*:\s*', '$1: ').Trim() } |
        Select-Object -Unique

$fila = [ordered]@{
    nombre          = $Nombre
    extra           = ($Extra -join ' ')
    carga_s         = $carga
    libre_antes     = $libreAntes
    libre_despues   = $libreDespues
    usa_mib         = $libreAntes - $libreDespues
    dedicada        = $mg.dedicada
    compartida      = $mg.compartida
    imagen_fichas   = $ri.timings.prompt_n
    imagen_ms       = [math]::Round($ri.timings.prompt_ms)
    tok_s           = [math]::Round($rt.timings.predicted_per_second, 1)
    bufers          = @($bufs)
}
Matar

$f = "$Raiz\medir-vram.json"
$todas = @(if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json }) + [pscustomobject]$fila
$todas | ConvertTo-Json -Depth 5 | Set-Content $f -Encoding utf8
[pscustomobject]$fila
