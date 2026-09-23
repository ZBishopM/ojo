#Requires -Version 5.1
# Clips MP3 para la escucha a ciegas: cada voz recibe una letra al azar, y la
# clave (letra -> voz) se guarda en salida\escucha-clave.json, NO en la pagina.
param([string]$Destino = (Join-Path $PSScriptRoot 'salida\escucha'))
$ErrorActionPreference = 'Stop'
$ffmpeg = 'C:\Program Files\ImageMagick-7.1.1-Q16-HDRI\ffmpeg.exe'
$voces = 'sapi', 'piper', 'supertonic-F1', 'supertonic-F2', 'supertonic-F3', 'supertonic-F4', 'supertonic-F5', 'chatterbox'
$frases = 1, 3, 5
New-Item -ItemType Directory -Force $Destino | Out-Null
$letras = [char[]]'ABCDEFGH' | Get-Random -Count $voces.Count
$clave = [ordered]@{}
for ($i = 0; $i -lt $voces.Count; $i++) {
    $l = [string]$letras[$i]; $clave[$l] = $voces[$i]
    foreach ($f in $frases) {
        & $ffmpeg -y -loglevel error -i (Join-Path $PSScriptRoot "salida\$($voces[$i])\$f.wav") -ac 1 -b:a 64k (Join-Path $Destino "$l-$f.mp3")
    }
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'salida\escucha-clave.json'), ($clave | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
"$(@(Get-ChildItem $Destino -Filter *.mp3).Count) clips, $([math]::Round((Get-ChildItem $Destino | Measure-Object Length -Sum).Sum / 1MB, 1)) MB"
