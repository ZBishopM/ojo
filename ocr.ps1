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

# Como Leer-Texto, pero cada linea con su rectangulo NORMALIZADO (0-1 sobre la
# imagen), para poder decir donde esta cada texto y senalarlo con exactitud.
# El rectangulo de la linea es la union de los de sus palabras.
function Leer-Palabras([string]$ruta, [string]$idioma = 'es-MX', [double]$escala = 1) {
    $f = Esperar-WinRT ([Windows.Storage.StorageFile]::GetFileFromPathAsync((Resolve-Path $ruta).Path)) ([Windows.Storage.StorageFile])
    $s = Esperar-WinRT ($f.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    try {
        $dec = Esperar-WinRT ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($s)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bmp = if ($escala -ne 1) {
            $tr = New-Object Windows.Graphics.Imaging.BitmapTransform
            $tr.ScaledWidth = [uint32]($dec.PixelWidth * $escala); $tr.ScaledHeight = [uint32]($dec.PixelHeight * $escala)
            $tr.InterpolationMode = [Windows.Graphics.Imaging.BitmapInterpolationMode]::Fant
            Esperar-WinRT ($dec.GetSoftwareBitmapAsync([Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
                [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied, $tr,
                [Windows.Graphics.Imaging.ExifOrientationMode]::IgnoreExifOrientation,
                [Windows.Graphics.Imaging.ColorManagementMode]::DoNotColorManage)) ([Windows.Graphics.Imaging.SoftwareBitmap])
        } else { Esperar-WinRT ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap]) }
        $W = [double]$bmp.PixelWidth; $H = [double]$bmp.PixelHeight
        $motor = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new($idioma))
        $r = Esperar-WinRT ($motor.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
        @($r.Lines | ForEach-Object {
            $rs = @($_.Words | ForEach-Object { $_.BoundingRect })
            $x1 = ($rs | Measure-Object X -Minimum).Minimum; $y1 = ($rs | Measure-Object Y -Minimum).Minimum
            $x2 = ($rs | ForEach-Object { $_.X + $_.Width } | Measure-Object -Maximum).Maximum
            $y2 = ($rs | ForEach-Object { $_.Y + $_.Height } | Measure-Object -Maximum).Maximum
            # Y cada PALABRA con su rectangulo: una barra de estado entera sale
            # como UNA linea ("218W 0.75kWh ... RAM 45% CPU ..."), y senalar su
            # centro no es senalar "RAM".
            $palabras = @($_.Words | ForEach-Object {
                $b = $_.BoundingRect
                [pscustomobject]@{ texto = $_.Text; x = ($b.X + $b.Width / 2) / $W; y = ($b.Y + $b.Height / 2) / $H; w = $b.Width / $W; h = $b.Height / $H }
            })
            [pscustomobject]@{ texto = $_.Text; x = ($x1 + $x2) / 2 / $W; y = ($y1 + $y2) / 2 / $H
                               w = ($x2 - $x1) / $W; h = ($y2 - $y1) / $H; palabras = $palabras }
        })
    } finally { $s.Dispose() }
}

# Segunda oportunidad para texto de BAJO CONTRASTE (gris sobre gris): la imagen
# en grises con el contraste estirado alrededor de su brillo medio, y otra
# pasada de OCR. banco-pantalla (2026-09-23): "Codigo de acceso: 7169-B" en gris
# sobre gris no salia en la primera pasada. Con ColorMatrix de GDI+ (rapido):
# recorrer 3,7 millones de pixeles en PowerShell no es opcion.
function Leer-Contraste([string]$ruta, [double]$factor = 3.0) {
    Add-Type -AssemblyName System.Drawing
    $src = [Drawing.Bitmap]::FromFile((Resolve-Path $ruta).Path)
    # Brillo medio, de una miniatura (2.304 pixeles).
    $mini = New-Object Drawing.Bitmap $src, 64, 36
    $suma = 0.0
    for ($y = 0; $y -lt 36; $y++) { for ($x = 0; $x -lt 64; $x++) { $c = $mini.GetPixel($x, $y); $suma += (0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B) / 255 } }
    $mini.Dispose()
    $m = $suma / (64 * 36)
    # Grises y contraste x$factor centrado en el brillo medio: (v - m) * f + m.
    $gr = 0.299 * $factor; $gg = 0.587 * $factor; $gb = 0.114 * $factor; $off = $m * (1 - $factor)
    $cm = New-Object Drawing.Imaging.ColorMatrix(,[single[][]]@(
        [single[]]@($gr, $gr, $gr, 0, 0), [single[]]@($gg, $gg, $gg, 0, 0), [single[]]@($gb, $gb, $gb, 0, 0),
        [single[]]@(0, 0, 0, 1, 0), [single[]]@($off, $off, $off, 0, 1)))
    $ia = New-Object Drawing.Imaging.ImageAttributes; $ia.SetColorMatrix($cm)
    $dst = New-Object Drawing.Bitmap $src.Width, $src.Height
    $g = [Drawing.Graphics]::FromImage($dst)
    $g.DrawImage($src, (New-Object Drawing.Rectangle 0, 0, $src.Width, $src.Height), 0, 0, $src.Width, $src.Height, [Drawing.GraphicsUnit]::Pixel, $ia)
    $g.Dispose(); $src.Dispose()
    $tmp = Join-Path $env:TEMP "ojo-contraste-$PID-$([Environment]::TickCount).bmp"
    $dst.Save($tmp, [Drawing.Imaging.ImageFormat]::Bmp); $dst.Dispose()
    Leer-Palabras $tmp 'es-MX' 2
}

if ($MyInvocation.InvocationName -eq '.') { return }
$img = $args | Select-Object -First 1
$sw = [Diagnostics.Stopwatch]::StartNew()
$lineas = Leer-Texto $img
$lineas
Write-Host ("--- {0} lineas en {1:N0} ms" -f @($lineas).Count, $sw.Elapsed.TotalMilliseconds)
