#Requires -Version 5.1
<#
Lee el TEXTO de una imagen con el OCR que trae Windows (Windows.Media.Ocr).

POR QUE ESTE: viene con Windows, no gasta VRAM (en partida no sobra), no hay
que descargar nada, y tiene espanol de Mexico instalado (comprobado el
2026-09-22: en-US, es-ES, es-MX, it-IT, ja, zh-Hans-CN).

PARA QUE: en ARAM Mayhem la eleccion de aumento sale en momentos fijos
(inicio y niveles 7, 11 y 15) y la API de la partida no la cuenta. Leyendo la
pantalla en ese momento, Ojo sabe que tres aumentos te ofrecen. Es lo que hace
ezlol (github.com/aarlint/ezlol).

    .\ocr.ps1 imagen.jpg           una linea de texto por linea de la imagen
    . .\ocr.ps1                    (con punto) solo Leer-Texto

Es WinRT desde PowerShell 5.1: las operaciones son asincronas y se esperan con
AsTask. Sin bloque param(), como el resto de lo que se carga con punto.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]

$OCR_ASTASK = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1

function Esperar-WinRT($op, [Type]$tipo) {
    $t = $OCR_ASTASK.MakeGenericMethod($tipo).Invoke($null, @($op))
    $null = $t.Wait(10000)
    $t.Result
}

function Leer-Texto([string]$ruta, [string]$idioma = 'es-MX') {
    $f = Esperar-WinRT ([Windows.Storage.StorageFile]::GetFileFromPathAsync((Resolve-Path $ruta).Path)) ([Windows.Storage.StorageFile])
    $s = Esperar-WinRT ($f.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    try {
        $dec = Esperar-WinRT ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($s)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bmp = Esperar-WinRT ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $motor = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new($idioma))
        $r = Esperar-WinRT ($motor.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
        @($r.Lines | ForEach-Object { $_.Text })
    } finally { $s.Dispose() }
}

if ($MyInvocation.InvocationName -eq '.') { return }
$img = $args | Select-Object -First 1
$sw = [Diagnostics.Stopwatch]::StartNew()
$lineas = Leer-Texto $img
$lineas
Write-Host ("--- {0} lineas en {1:N0} ms" -f @($lineas).Count, $sw.Elapsed.TotalMilliseconds)
