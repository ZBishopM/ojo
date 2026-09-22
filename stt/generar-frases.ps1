# Genera frases EN ESPANOL para medir la precision del STT.
#
# Por que hace falta: los .wav de F:\ai\muletillas son gruñidos -- "mm-hmm",
# "uh-huh" -- sin una sola palabra. Sirven para cronometrar y para nada mas; el
# motor los transcribio como interjecciones inglesas, que es lo correcto para un
# gruñido y no dice nada sobre el espanol.
#
# Se usa la voz del PROPIO Windows (SAPI) y no un TTS del proyecto: no hay que
# instalar nada, no toca la VRAM, y para lo que se quiere saber -- si el motor
# entiende palabras en espanol -- una voz sintetica vale.
#
# LO QUE ESTO NO ES: una medida con su microfono y su voz. Una voz sintetica no
# tiene ruido de sala, ni acento peruano, ni la prosodia de quien habla rapido.
# Eso queda pendiente y necesita que hable el.
param(
    [string]$Salida = 'D:\2026-projects\ojo\stt\frases'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech

# Las frases son las que Ojo va a oir de verdad: ordenes cortas sobre la
# pantalla y preguntas de conocimiento. No frases de ejemplo de un manual.
#
# CON TILDES Y EÑES, y no es cosmetico. La primera version las escribio en
# ASCII y la voz leyo lo que estaba escrito: "senala" sono "se-nala" y "boton"
# perdio el acento. Los dos motores fallaron esa frase y parecia cosa suya --
# era el audio, que decia otra cosa. El comparador ya quita las tildes antes de
# contar errores, asi que escribirlas bien no cuesta nada.
$FRASES = [ordered]@{
    f01 = 'dónde silencio el micrófono'
    f02 = 'dónde están los ajustes de usuario'
    f03 = 'cuánta memoria RAM reserva el servidor por defecto'
    f04 = 'señala el botón de cerrar la ventana'
    f05 = 'qué aplicación estoy usando ahora mismo'
    f06 = 'abre la configuración de sonido'
    f07 = 'cuántos paneles hay en esta pantalla'
    f08 = 'en qué disco están guardados los modelos'
}

$s = New-Object Speech.Synthesis.SpeechSynthesizer
$voces = $s.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo }
$es = $voces | Where-Object { $_.Culture.Name -like 'es*' } | Select-Object -First 1
if ($es) { $s.SelectVoice($es.Name); Write-Host "voz: $($es.Name) ($($es.Culture.Name))" }
else {
    Write-Warning "no hay voz en espanol instalada; se usa $($voces[0].Name). Las palabras saldran con acento ingles y la medida valdra menos."
}

New-Item -ItemType Directory -Force $Salida | Out-Null
$FRASES.GetEnumerator() | ForEach-Object {
    $wav = Join-Path $Salida "$($_.Key).wav"
    $s.SetOutputToWaveFile($wav)
    $s.Speak($_.Value)
    "$($_.Key)  $($_.Value)"
}
$s.SetOutputToNull(); $s.Dispose()

# La referencia, para que el banco compare contra algo y no contra mi criterio.
$FRASES | ConvertTo-Json | Set-Content (Join-Path $Salida 'referencia.json') -Encoding utf8
Write-Host "`nguardadas en $Salida"
