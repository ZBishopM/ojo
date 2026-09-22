<#
Una hora de uso normal del escritorio, midiendo cada 5 minutos si el modelo de
Ojo sigue a su velocidad. Es la prueba que habria delatado el fallo del
2026-09-22: el 8B paso de 50,66 a 12,4 tok/s en 25 minutos sin ningun juego,
porque el escritorio crecio y Windows lo desalojo de la VRAM.

    .\medir-hora.ps1 -Minutos 60 -Cada 5
#>
param([int]$Minutos = 60, [int]$Cada = 5, [string]$Raiz = 'D:\2026-projects\ojo')
$salida = "$Raiz\medir-hora.csv"
$fin = (Get-Date).AddMinutes($Minutos)
while ($true) {
    $fila = [ordered]@{ hora = (Get-Date).ToString('HH:mm:ss') }
    try {
        $b = @{ messages = @(@{ role = 'user'; content = 'Escribe exactamente cien palabras sobre el mar.' }); max_tokens = 100
                chat_template_kwargs = @{ enable_thinking = $false } } | ConvertTo-Json -Depth 5
        $r = Invoke-RestMethod http://127.0.0.1:8099/v1/chat/completions -Method Post -ContentType 'application/json' `
                -Body ([Text.Encoding]::UTF8.GetBytes($b)) -TimeoutSec 600
        $fila.tok_s = [math]::Round($r.timings.predicted_per_second, 1)
        $fila.modelo = [IO.Path]::GetFileNameWithoutExtension((Invoke-RestMethod http://127.0.0.1:8099/props).model_path)
    } catch { $fila.tok_s = -1; $fila.modelo = "error: $($_.Exception.Message)" }
    $fila.vram_libre = [int](((& nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits) | Select-Object -First 1).Trim())
    [pscustomobject]$fila | Export-Csv $salida -NoTypeInformation -Append -Encoding utf8
    if ((Get-Date) -ge $fin) { break }
    Start-Sleep -Seconds ($Cada * 60)
}
