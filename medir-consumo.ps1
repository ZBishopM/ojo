#Requires -Version 5.1
<#
Cuanto gasta el PC en cada situacion, con la MISMA cuenta que rice\consumo
(dotfiles\crates\consumo): GPU medida por nvidia-smi, CPU estimada por su uso
(cpu_idle_w + (cpu_max_w - cpu_idle_w) * uso, porque LibreHardwareMonitor no
corre), mas la base del equipo, las perdidas de la fuente y los monitores.
Es una ESTIMACION: el numero de verdad solo sale con un enchufe medidor.

    .\medir-consumo.ps1 -Escenario reposo-con-ojo
    .\medir-consumo.ps1 -Escenario ojo-8b -Carga ojo            (preguntas sin parar a Ojo)
    .\medir-consumo.ps1 -Escenario ojo-m1 -Carga ojo -Puerto 8097
    .\medir-consumo.ps1 -Escenario voz-pocket -Carga voz        (Pocket hablando en CPU)
#>
param([Parameter(Mandatory)][string]$Escenario, [int]$Segundos = 90, [ValidateSet('ninguna', 'ojo', 'voz')][string]$Carga = 'ninguna', [int]$Puerto = 8099)
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg = ([IO.File]::ReadAllText("$env:USERPROFILE\.config\rice.json", [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json).consumo
function Valor($v, $d) { if ($null -ne $v) { [double]$v } else { $d } }
$base = Valor $cfg.base_w 65; $psu = Valor $cfg.eficiencia_psu 0.87; $mon = Valor $cfg.monitores_w 60
$margen = Valor $cfg.margen 1.10; $cIdle = Valor $cfg.cpu_idle_w 25; $cMax = Valor $cfg.cpu_max_w 120; $precio = Valor $cfg.precio_kwh 0.70

# La carga, en otro proceso, mientras se muestrea.
$proc = $null
$marca = Join-Path $env:TEMP "ojo-consumo-$PID.txt"
Remove-Item $marca -EA SilentlyContinue
if ($Carga -eq 'ojo') {
    $img = @(Get-ChildItem "$raiz\escenas\reales" -Recurse -Filter 'monitor2.png' | Select-Object -First 1)[0].FullName
    $bucle = "`$n = 0; while (`$true) { `$null = & '$raiz\ojo.ps1' -Pregunta '¿Qué hay abierto en esta pantalla?' -Imagen '$img' -Voz '' -Segundos 0 -Puerto $Puerto *>&1; `$n++; Set-Content '$marca' `$n }"
    $proc = Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $bucle -WindowStyle Hidden -PassThru
} elseif ($Carga -eq 'voz') {
    $proc = Start-Process 'F:\ai\tts\pocket\.venv\Scripts\python.exe' -ArgumentList "$raiz\voz\probar_ligera.py", 'pocket', 'lola', '--hilos', '2', '--vueltas', '20' -WorkingDirectory "$raiz\voz" -WindowStyle Hidden -PassThru
}
if ($proc) { Start-Sleep -Seconds 10 }   # que arranque antes de medir

$filas = for ($i = 0; $i -lt $Segundos; $i++) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    $gpu = [double]::Parse(((& nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits) | Select-Object -First 1).Trim(), [Globalization.CultureInfo]::InvariantCulture)
    $uso = [double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime / 100
    $cpu = $cIdle + ($cMax - $cIdle) * $uso
    $pared = ($gpu + $cpu + $base) / $psu * $margen + $mon
    [pscustomobject]@{ gpu = $gpu; cpu = $cpu; uso = $uso; pared = $pared }
    $resto = 1000 - $t.ElapsedMilliseconds; if ($resto -gt 0) { Start-Sleep -Milliseconds $resto }
}
$preguntas = if (Test-Path $marca) { [int](Get-Content $marca) } else { $null }
if ($proc) { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue }
Get-CimInstance Win32_Process -EA SilentlyContinue | Where-Object { $_.CommandLine -match [regex]::Escape($marca) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
Remove-Item $marca -EA SilentlyContinue

$m = { param($k) [math]::Round(($filas | Measure-Object $k -Average).Average, 1) }
$res = [ordered]@{
    escenario = $Escenario; fecha = Get-Date -Format 'yyyy-MM-dd HH:mm'; segundos = $Segundos; carga = $Carga
    gpu_w = & $m 'gpu'; cpu_w_estimada = & $m 'cpu'; uso_cpu_pct = [math]::Round((& $m 'uso') * 100); pared_w = & $m 'pared'
    preguntas = $preguntas
    wh_por_pregunta = if ($preguntas) { [math]::Round((& $m 'pared') * $Segundos / 3600 / $preguntas, 3) } else { $null }
    soles_por_hora = [math]::Round((& $m 'pared') / 1000 * $precio, 4)
}
$f = "$raiz\consumo-escenarios.json"
$todas = @(if (Test-Path $f) { [IO.File]::ReadAllText($f, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json | ForEach-Object { $_ } }) + [pscustomobject]$res
[IO.File]::WriteAllText($f, (ConvertTo-Json @($todas) -Depth 3), [Text.UTF8Encoding]::new($false))
[pscustomobject]$res
