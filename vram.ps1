#Requires -Version 5.1
<#
En qué se va la VRAM: una foto por proceso, para el diagrama de la página MVP.

POR QUE ASI: nvidia-smi en Windows (WDDM) no da la memoria por proceso ("N/A"),
y Get-Counter falla en silencio con Windows en español (nombres de contador
traducidos). La clase WMI de contadores de GPU tiene nombres en inglés siempre.
Viene alguna fila absurda (487.808 MiB en una tarjeta de 12 GB): se tira todo lo
que pase del total.

    .\vram.ps1 -Estado sin-juego      escribe vram-sin-juego.json
    .\vram.ps1 -Estado con-lol        (lo lanza el supervisor al cambiar de perfil)
#>
param([string]$Estado = 'ahora')
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path

$g = (& nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits) -split ',\s*'
$usada = [int]$g[0]; $total = [int]$g[1]

$procs = @{}
Get-CimInstance Win32_Process | ForEach-Object { $procs[[int]$_.ProcessId] = $_ }

# Nombre legible de cada proceso (los de Ojo, por su linea de comandos).
function Nombre($p) {
    $n = "$($p.Name)" -replace '\.exe$', ''
    $cl = "$($p.CommandLine)"
    if ($n -eq 'llama-server') {
        if ($cl -match 'Qwen3\.5-4B') { return 'Ojo: modelo 4B (texto)' }
        if ($cl -match 'Qwen3-VL-8B') { return 'Ojo: modelo 8B (visión)' }
        return 'llama-server (otro modelo)'
    }
    if ($n -match '^python' -and $cl -match 'servidor_voz') { return 'Ojo: voz' }
    if ($n -match '^python' -and $cl -match 'escuchar') { return 'Ojo: oído' }
    if ($n -match '^ojo-overlay') { return 'Ojo: overlay' }
    if ($n -match '^League of Legends$') { return 'LoL (partida)' }
    if ($n -match '^LeagueClient') { return 'LoL (cliente)' }
    if ($n -match '^dwm$') { return 'Windows (dwm)' }
    if ($n -match '^firefox') { return 'Firefox' }
    if ($n -match '^Discord') { return 'Discord' }
    if ($n -match '^Resolve') { return 'DaVinci Resolve' }
    $n
}

$filas = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory |
    Where-Object { $_.Name -match '^pid_(\d+)_' } | ForEach-Object {
        $pid_ = [int]($_.Name -replace '^pid_(\d+)_.*', '$1')
        $mib = [math]::Round($_.DedicatedUsage / 1MB)
        if ($mib -ge 1 -and $mib -le $total) {
            [pscustomobject]@{ nombre = if ($procs[$pid_]) { Nombre $procs[$pid_] } else { "pid $pid_" }; mib = $mib }
        }
    } | Group-Object nombre | ForEach-Object { [pscustomobject]@{ nombre = $_.Name; mib = [int]($_.Group | Measure-Object mib -Sum).Sum } } |
    Sort-Object mib -Descending

# Lo pequeño junto, para que el diagrama se lea.
$grandes = @($filas | Where-Object mib -ge 150)
$resto = [int](@($filas | Where-Object mib -lt 150) | Measure-Object mib -Sum).Sum
if ($resto) { $grandes += [pscustomobject]@{ nombre = 'otros'; mib = $resto } }
$res = [ordered]@{ estado = $Estado; fecha = Get-Date -Format 'yyyy-MM-dd HH:mm'; total_mib = $total; usada_mib = $usada; procesos = @($grandes) }
[IO.File]::WriteAllText((Join-Path $raiz "vram-$Estado.json"), ($res | ConvertTo-Json -Depth 3), [Text.UTF8Encoding]::new($false))
$grandes | ForEach-Object { '{0,6} MiB  {1}' -f $_.mib, $_.nombre }
"usada {0} de {1} MiB (nvidia-smi)" -f $usada, $total
