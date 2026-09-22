# Mide si el modelo apunta cuando NO se le ha preguntado por un sitio.
#
# El sintoma que lo motiva: preguntando "cuanta RAM reserva llama-server por
# defecto", contesto bien Y ADEMAS senalo el control 'Send a gift' de Discord.
# El esquema dice que `senalar` es opcional, pero nada le decia cuando callarse,
# y una flecha sobre un sitio cualquiera es peor que ninguna flecha: parece que
# significa algo.
#
# Dos grupos de preguntas sobre la misma pantalla:
#
#   PANTALLA     preguntan por un sitio   -> DEBEN apuntar
#   CONOCIMIENTO no preguntan por un sitio -> NO deben apuntar
#
# Un cambio en el prompt sin una medida al lado es una intencion, no un arreglo.
#
#   .\probar-senalar.ps1
#   .\probar-senalar.ps1 -Ventana firefox -Vueltas 2
param(
    [string]$Ventana = 'discord',
    [int]$Vueltas = 1,
    [string]$Raiz = 'D:\2026-projects\ojo'
)
$ErrorActionPreference = 'Stop'

$PANTALLA = @(
    'donde silencio el microfono?'
    'donde estan los ajustes de usuario?'
    'donde esta el boton de cerrar?'
    'donde escribo un mensaje?'
    'donde desactivo el sonido de los auriculares?'
)

# Preguntas de conocimiento del proyecto: la respuesta esta en las memorias, no
# en la pantalla. Se hacen CON la pantalla delante a proposito, que es la
# situacion real en la que aparecio el fallo.
$CONOCIMIENTO = @(
    'cuanta RAM reserva llama-server por defecto para la cache de prompts?'
    'en que disco viven los modelos y por que?'
    'que hace n-cpu-moe?'
    'cuanto tarda whisper en transcribir?'
    'por que el overlay no sale en la captura?'
)

# Se mira `senalo`, no `via`. `via` es texto explicativo y cambia; `senalo` es
# el dato: trae las coordenadas o "(nada)". Medir por `via` daba falsos
# positivos en cuanto se añadio el motivo entre parentesis.
function Apunto($salida) {
    $s = ([regex]'senalo\s+:\s*(.+)').Match($salida).Groups[1].Value.Trim()
    $s -and $s -ne '(nada)'
}

function Correr($preguntas, $deben) {
    $n = 0; $total = 0; $detalle = @()
    foreach ($q in $preguntas) {
        foreach ($v in 1..$Vueltas) {
            $o = & powershell -NoProfile -ExecutionPolicy Bypass -File "$Raiz\ojo.ps1" $q -Ventana $Ventana -Segundos 0 2>&1 | Out-String
            $a = Apunto $o
            $total++
            if ($a -eq $deben) { $n++ }
            else {
                $via = ([regex]'via\s+:\s*(.+)').Match($o).Groups[1].Value.Trim()
                $detalle += "  {0,-50} -> {1}" -f $q, $(if ($a) { "apunto a $via" } else { 'no apunto' })
            }
        }
    }
    @{ bien = $n; total = $total; detalle = $detalle }
}

Write-Host 'PANTALLA (deben apuntar)...'
$p = Correr $PANTALLA $true
Write-Host 'CONOCIMIENTO (NO deben apuntar)...'
$c = Correr $CONOCIMIENTO $false

Write-Host ''
"pantalla      {0}/{1} apuntaron, como debe ser" -f $p.bien, $p.total
"conocimiento  {0}/{1} se callaron, como debe ser" -f $c.bien, $c.total
if ($p.detalle) { Write-Host "`nde pantalla, no apuntaron:"; $p.detalle | ForEach-Object { Write-Host $_ } }
if ($c.detalle) { Write-Host "`nde conocimiento, apuntaron sin venir a cuento:"; $c.detalle | ForEach-Object { Write-Host $_ } }
