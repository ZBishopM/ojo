<#
Cuanto tarda el supervisor en cambiar de perfil al empezar y al acabar una
partida. Usa la partida falsa (partida.ps1): proceso "League of Legends" + API.

    .\medir-cambio.ps1 -Nombre antes

Mide de "aparece el proceso del juego" a "el 8099 contesta con el modelo de
texto", y al reves al cerrarlo. Es el tiempo durante el que el 8B y el juego
comparten tarjeta.
#>
param([Parameter(Mandatory)][string]$Nombre, [int]$Tope = 180)
$ErrorActionPreference = 'Stop'
$aqui = $PSScriptRoot

function Modelo {
    try { [IO.Path]::GetFileNameWithoutExtension((Invoke-RestMethod http://127.0.0.1:8099/props -TimeoutSec 2).model_path) }
    catch { '(ninguno)' }
}
function Esperar($patron) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Tope) {
        if ((Modelo) -match $patron) { return [math]::Round($sw.Elapsed.TotalSeconds, 1) }
        Start-Sleep -Milliseconds 500
    }
    $null
}

"modelo al empezar: $(Modelo)"
& pwsh -NoProfile -File "$aqui\partida.ps1" -Empezar | Out-Null
$ida = Esperar 'Qwen3\.5-4B'
"entra en partida -> texto en: $(if ($ida) { "$ida s" } else { "NO cambio en $Tope s" })"

& pwsh -NoProfile -File "$aqui\partida.ps1" -Terminar | Out-Null
$vuelta = Esperar 'Qwen3-VL-8B'
"sale de partida -> vision en: $(if ($vuelta) { "$vuelta s" } else { "NO volvio en $Tope s" })"

$f = Join-Path (Split-Path $aqui) 'medir-cambio.json'
$todas = @(if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json | ForEach-Object { $_ } }) + [pscustomobject]@{ nombre = $Nombre; ida_s = $ida; vuelta_s = $vuelta; hora = (Get-Date).ToString('HH:mm:ss') }
$todas | ConvertTo-Json | Set-Content $f -Encoding utf8
