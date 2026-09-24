#Requires -Version 5.1
<#
La barra de lo que haya corriendo (progreso.json, lo escribe comparar-modelos):
cuanto va, cuanto falta al ritmo que lleva, y si se puede jugar mientras.

    .\progreso.ps1
#>
$f = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'progreso.json'
if (-not (Test-Path $f)) { 'nada corriendo'; return }
$p = [IO.File]::ReadAllText($f, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
$frac = [math]::Min(1.0, $p.paso / [double]$p.total)
$lleva = ((Get-Date) - [datetime]$p.inicio).TotalMinutes
$falta = if ($frac -gt 0 -and $frac -lt 1) { [math]::Ceiling($lleva / $frac - $lleva) } else { 0 }
$n = [int][math]::Round($frac * 20)
$barra = ('█' * $n) + ('░' * (20 - $n))
"{0}  [{1}] {2,3}%  · {3}" -f $p.tarea, $barra, [int]($frac * 100), $(if ($frac -ge 1) { 'terminado' } else { "faltan ~$falta min (lleva $([int]$lleva))" })
"ahora: $($p.ahora)"
if ($frac -lt 1 -and $p.juego_inerte) { 'NO abras LoL todavia: hay un "League of Legends" falso y dos modelos cargados.' }
