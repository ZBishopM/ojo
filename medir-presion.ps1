<#
Resiste el modelo de Ojo a que otro proceso le quite VRAM?

Se mide la velocidad del servidor que haya en el 8099 (el que mantiene el
supervisor, sin tocarlo), se arranca un "ladron" -- el 4B de texto con N capas
en GPU, en el 8097 -- y se vuelve a medir, y otra vez al quitarlo.

POR QUE EXISTE: el 2026-09-22, con el 8B en Q8_0 y ~300 MiB libres, un ladron
de ~1,4 GB lo hundio de 43 a 4,4 tok/s: Windows no da error, desaloja parte del
modelo a RAM. Es lo que pasaba sin juego ninguno cuando Firefox o Discord
crecian. Esta prueba dice si el margen nuevo aguanta.

    .\medir-presion.ps1 -Nombre q6 -Capas 12
#>
param([Parameter(Mandatory)][string]$Nombre, [int]$Capas = 12, [string]$Raiz = 'D:\2026-projects\ojo')
$ErrorActionPreference = 'Stop'
function Libre { [int](((& nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits) | Select-Object -First 1).Trim()) }
function Tok {
    $b = @{ messages = @(@{ role = 'user'; content = 'Escribe exactamente cien palabras sobre el mar.' }); max_tokens = 120
            chat_template_kwargs = @{ enable_thinking = $false } } | ConvertTo-Json -Depth 5
    $r = Invoke-RestMethod http://127.0.0.1:8099/v1/chat/completions -Method Post -ContentType 'application/json' `
            -Body ([Text.Encoding]::UTF8.GetBytes($b)) -TimeoutSec 600
    [math]::Round($r.timings.predicted_per_second, 1)
}
$modelo = [IO.Path]::GetFileNameWithoutExtension((Invoke-RestMethod http://127.0.0.1:8099/props).model_path)
$f = [ordered]@{ nombre = $Nombre; modelo = $modelo; capas_ladron = $Capas }
$f.solo = Tok; $f.libre_solo = Libre

$h = @('--model', 'F:\ai\models\Qwen3.5-4B-UD-Q5_K_XL.gguf', '--ctx-size', '512', '--n-gpu-layers', "$Capas",
       '--port', '8097', '--host', '127.0.0.1', '--load-mode', 'none', '--cache-ram', '0')
$ladron = Start-Process 'F:\ai\llama.cpp\llama-server.exe' -ArgumentList $h -WindowStyle Hidden -PassThru
for ($i = 0; $i -lt 200; $i++) { Start-Sleep -Milliseconds 300; try { if ((Invoke-RestMethod http://127.0.0.1:8097/health -TimeoutSec 2).status -eq 'ok') { break } } catch { } }
Start-Sleep -Seconds 2
$f.con_ladron = Tok; $f.libre_con_ladron = Libre
Start-Sleep -Seconds 20
$f.con_ladron_20s = Tok

Stop-Process -Id $ladron.Id -Force
Start-Sleep -Seconds 5
$f.sin_ladron = Tok

$j = "$Raiz\medir-presion.json"
$todas = @(if (Test-Path $j) { Get-Content $j -Raw | ConvertFrom-Json }) + [pscustomobject]$f
$todas | ConvertTo-Json | Set-Content $j -Encoding utf8
[pscustomobject]$f
