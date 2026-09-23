<#
Una hora de uso normal del escritorio, midiendo cada 5 minutos si el modelo de
Ojo sigue a su velocidad -- y, si no, QUIEN estaba usando la GPU.

POR QUE EXISTE: el 2026-09-22 el 8B paso de 50,66 a 12,4 tok/s en 25 minutos
sin ningun juego (desalojo de VRAM, ya arreglado con margen). En la hora de
prueba de despues quedaron dos bajones, 63 -> 53 tok/s, con la VRAM libre igual
y sin nada en los registros del sistema: sin datos, no habia forma de saber que
los causo. Ahora cada muestra lleva:

  - tres generaciones (mediana y minima): separa un bajon real del ruido
  - reloj, estado de energia, consumo, temperatura y uso de la GPU
  - los procesos que estaban usando la GPU, por motor (3D, copia, codificador)

    .\medir-hora.ps1 -Minutos 60 -Cada 5
#>
param([int]$Minutos = 60, [int]$Cada = 5, [string]$Raiz = 'D:\2026-projects\ojo')
$salida = "$Raiz\medir-hora.csv"

function Usuarios-Gpu {
    # Contador GPUEngine por WMI (no Get-Counter: en es-ES los nombres van
    # traducidos y falla en silencio). Se suma por proceso y motor.
    Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -EA SilentlyContinue |
        Where-Object { $_.UtilizationPercentage -gt 1 } |
        ForEach-Object {
            $procId = [int](($_.Name -split '_')[1])
            [pscustomobject]@{ p = (Get-Process -Id $procId -EA SilentlyContinue).ProcessName; m = ($_.Name -replace '.*engtype_', ''); u = $_.UtilizationPercentage }
        } |
        Group-Object p, m | ForEach-Object { [pscustomobject]@{ n = $_.Name -replace ', ', ':'; u = ($_.Group | Measure-Object u -Sum).Sum } } |
        Sort-Object u -Descending | Select-Object -First 5 | ForEach-Object { "$($_.n)=$($_.u)%" }
}

$fin = (Get-Date).AddMinutes($Minutos)
while ($true) {
    $fila = [ordered]@{ hora = (Get-Date).ToString('HH:mm:ss') }
    # Quien usa la GPU JUSTO ANTES de medir (durante la medida saldria el propio modelo).
    $fila.gpu_usada_por = (Usuarios-Gpu) -join ' '
    try {
        $v = foreach ($i in 1..3) {
            $b = @{ messages = @(@{ role = 'user'; content = 'Escribe exactamente cien palabras sobre el mar.' }); max_tokens = 100
                    chat_template_kwargs = @{ enable_thinking = $false } } | ConvertTo-Json -Depth 5
            (Invoke-RestMethod http://127.0.0.1:8099/v1/chat/completions -Method Post -ContentType 'application/json' `
                -Body ([Text.Encoding]::UTF8.GetBytes($b)) -TimeoutSec 600).timings.predicted_per_second
        }
        $o = @($v | Sort-Object)
        $fila.tok_s = [math]::Round($o[1], 1)
        $fila.tok_s_min = [math]::Round($o[0], 1)
        $fila.modelo = [IO.Path]::GetFileNameWithoutExtension((Invoke-RestMethod http://127.0.0.1:8099/props).model_path)
    } catch { $fila.tok_s = -1; $fila.tok_s_min = -1; $fila.modelo = "error: $($_.Exception.Message)" }
    $g = ((& nvidia-smi --query-gpu=memory.free,clocks.sm,pstate,power.draw,temperature.gpu,utilization.gpu --format=csv,noheader,nounits) | Select-Object -First 1) -split ',\s*'
    $fila.vram_libre = [int]$g[0]; $fila.reloj_mhz = [int]$g[1]; $fila.pstate = $g[2]
    $fila.watts = [double]$g[3]; $fila.temp_c = [int]$g[4]; $fila.uso_gpu = [int]$g[5]
    [pscustomobject]$fila | Export-Csv $salida -NoTypeInformation -Append -Encoding utf8
    if ((Get-Date) -ge $fin) { break }
    Start-Sleep -Seconds ($Cada * 60)
}
