# Lectura secuencial real de cada disco, con la cache de Windows evitada.
#
# Importa porque un modelo de 5-17 GB se lee entero en cada arranque en frio, y
# ahi es donde se decide si un asistente "a demanda" tarda 10 s o 110 s en estar
# listo. El preset de voicebox ya dejaba escrito ~110 s desde I:.
param([int]$MB = 512)

$origen = @{
    'I: Barracuda HDD' = 'I:\ai\models\Qwen3.5-4B-UD-Q5_K_XL.gguf'
    'F: WD_BLACK SSD'  = 'F:\ai\models\Qwen3.5-4B-UD-Q5_K_XL.gguf'
}

foreach ($nombre in $origen.Keys) {
    $ruta = $origen[$nombre]
    if (-not (Test-Path $ruta)) { "{0,-18} (sin archivo todavia)" -f $nombre; continue }

    # FILE_FLAG_NO_BUFFERING no se expone desde .NET sin P/Invoke, asi que en su
    # lugar se lee MAS de lo que cabe en cache y se descarta la primera pasada.
    $buf = New-Object byte[] (4MB)
    $fs = [System.IO.File]::Open($ruta, 'Open', 'Read', 'ReadWrite')
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $leidos = 0L
        $tope = $MB * 1MB
        while ($leidos -lt $tope) {
            $n = $fs.Read($buf, 0, $buf.Length)
            if ($n -le 0) { $fs.Position = 0; continue }
            $leidos += $n
        }
        $sw.Stop()
        $mbs = ($leidos / 1MB) / $sw.Elapsed.TotalSeconds
        "{0,-18} {1,7:N0} MB/s   ({2:N0} MB en {3:N1} s)" -f $nombre, $mbs, ($leidos / 1MB), $sw.Elapsed.TotalSeconds
    } finally { $fs.Dispose() }
}
