#Requires -Version 5.1
# Clips MP3 para la escucha a ciegas: cada voz recibe una letra al azar, y la
# clave (letra -> voz) se guarda en salida\escucha-clave.json, NO en la pagina.
param(
    [string]$Destino = (Join-Path $PSScriptRoot 'salida\escucha'),
    # Carpetas de salida\ a comparar, y que frases de frases.txt.
    [string[]]$Voces = @('supertonic_gpu-F4', 'supertonic_gpu-F2', 'piper-es_AR-daniela-high', 'piper-es_MX-claude-high'),
    [int[]]$Frases = @(1, 3, 5, 7)
)
$ErrorActionPreference = 'Stop'
$ffmpeg = 'C:\Program Files\ImageMagick-7.1.1-Q16-HDRI\ffmpeg.exe'
$voces = $Voces; $frases = $Frases
New-Item -ItemType Directory -Force $Destino | Out-Null
Get-ChildItem $Destino -Filter *.mp3 | Remove-Item
$letras = [char[]]'ABCDEFGHIJKL'[0..($voces.Count - 1)] | Get-Random -Count $voces.Count
$clave = [ordered]@{}
for ($i = 0; $i -lt $voces.Count; $i++) {
    $l = [string]$letras[$i]; $clave[$l] = $voces[$i]
    foreach ($f in $frases) {
        & $ffmpeg -y -loglevel error -i (Join-Path $PSScriptRoot "salida\$($voces[$i])\$f.wav") -ac 1 -b:a 64k (Join-Path $Destino "$l-$f.mp3")
    }
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'salida\escucha-clave.json'), ($clave | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
"$(@(Get-ChildItem $Destino -Filter *.mp3).Count) clips, $([math]::Round((Get-ChildItem $Destino | Measure-Object Length -Sum).Sum / 1MB, 1)) MB"
