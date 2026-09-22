# El puente entre soltar el atajo y que Ojo conteste.
#
# Lo lanza ojo-hotkey.ahk al soltar Ctrl+Win. Vive fuera de AHK porque esto
# tarda segundos -- transcribir, capturar, preguntar al modelo -- y bloquear el
# bucle de mensajes de AHK dejaria el teclado sordo mientras tanto.
#
#   .\hablar.ps1              lo normal: para de grabar, transcribe, pregunta
#   .\hablar.ps1 -SoloTexto   transcribe y lo imprime, sin llamar a ojo.ps1
param(
    [int]$Puerto = 17494,
    [switch]$SoloTexto,
    [string]$Raiz = 'D:\2026-projects\ojo',
    [int]$Segundos = 12,
    # Que modelo usa `ojo.ps1`. Para la sesion con microfono se dicen las mismas
    # frases con los dos y se comparan en `sesion.csv`.
    [ValidateSet('35b', '8b', 'bonsai')][string]$Modelo = '8b'
)
$ErrorActionPreference = 'Stop'
$log = "$Raiz\hablar.log"

function Apuntar($msg) {
    "{0:HH:mm:ss}  {1}" -f (Get-Date), $msg | Add-Content $log -Encoding utf8
}

try {
    $t = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod "http://127.0.0.1:$Puerto/parar" -TimeoutSec 60
    $t.Stop()
} catch {
    Apuntar "el oido no respondio: $_"
    exit 1
}

$texto = ($r.texto ?? '').Trim()
Apuntar ("oido {0:N0} ms, {1} s de audio, stt {2} ms: '{3}'" -f `
    $t.Elapsed.TotalMilliseconds, $r.segundos, $r.ms, $texto)

if (-not $texto) {
    # Silencio o un roce de tecla. No se llama al modelo: preguntarle con la
    # cadena vacia hace que conteste "¿en que puedo ayudarte?", que es ruido.
    Apuntar 'nada que decir; no se llama al modelo'
    exit 0
}

if ($SoloTexto) { $texto; exit 0 }

# El reloj arranca AL SOLTAR LA TECLA, que es cuando empieza la espera del
# usuario. Todo lo de antes lo paso hablando.
$t0 = Get-Date

# `ojo.ps1` hace el resto: captura, controles de UIA, memorias y dibujo.
$salida = & powershell -NoProfile -ExecutionPolicy Bypass -File "$Raiz\ojo.ps1" $texto -Segundos $Segundos -Modelo $Modelo 2>&1 | Out-String
$salida | Add-Content $log -Encoding utf8

# Una fila por frase, con TODAS las etapas juntas. Antes los tiempos del oido
# vivian aqui y los del modelo en la salida de ojo.ps1, en otro archivo: asi no
# se puede responder "que es lo que mas demora", que es la pregunta de la
# sesion con microfono.
# Se lee del ARCHIVO y no de la salida capturada: el texto que cruza de un
# proceso a otro pasa por la pagina de codigos de la consola en los dos
# extremos, y eso convirtio "¿Dónde" en "┬┐D├│nde" dentro del CSV. Con
# codificacion explicita a los dos lados no hay ambiguedad.
$medidaFile = "$Raiz\ultima-medida.json"
$crudo = if (Test-Path $medidaFile) { [IO.File]::ReadAllText($medidaFile, [Text.UTF8Encoding]::new($false)) } else { $null }
if ($crudo) {
    try {
        $j = $crudo | ConvertFrom-Json
        # De soltar la tecla a que el dibujo sale hacia el overlay. Es el numero
        # que el usuario PERCIBE; los de etapa solo explican en que se fue.
        $hastaDibujo = [int](([DateTimeOffset]::FromUnixTimeMilliseconds($j.fin_epoch_ms)).LocalDateTime - $t0).TotalMilliseconds
        $fila = [pscustomobject]@{
            hora            = (Get-Date).ToString('HH:mm:ss')
            frase           = $j.pregunta
            modelo          = $j.modelo
            audio_s         = $r.segundos
            stt_ms          = $r.ms
            captura_ms      = $j.captura_ms
            uia_ms          = $j.uia_ms
            memoria_ms      = $j.memoria_ms
            modelo_ms       = $j.modelo_ms
            hasta_dibujo_ms = $hastaDibujo
            # Sin esta columna no hay forma de saber, mirando el CSV, si una
            # tanda lenta lo fue por el modelo o porque habia un juego abierto
            # comiendose la tarjeta. Paso el 2026-09-22 y costo la sesion entera.
            vram_libre_mib  = $j.vram_libre_mib
            controles       = $j.controles
            memorias        = $j.memorias
            via             = $j.via
            senalo          = $j.senalo
            trazos          = $j.trazos
            dijo            = $j.dijo
        }
        $csv = "$Raiz\sesion.csv"
        $fila | Export-Csv $csv -NoTypeInformation -Append -Encoding utf8
        Apuntar ("fila anotada: hasta_dibujo {0} ms (stt {1}, modelo {2})" -f $hastaDibujo, $r.ms, $j.modelo_ms)
    } catch { Apuntar "no pude anotar la fila: $_" }
} else {
    Apuntar 'ojo.ps1 no emitio linea MEDIDA; la frase no queda en sesion.csv'
}
