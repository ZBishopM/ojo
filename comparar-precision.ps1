# Pinta sobre una captura real donde apunta cada via, para poder JUZGARLO.
#
# Verde = rectangulo que da UI Automation (dato del sistema).
# Rojo  = punto que adivina el modelo de vision solo.
#
#   .\comparar-precision.ps1 -Ventana firefox -Salida D:\...\comparacion.png
param(
    [string]$Ventana = 'discord',
    [string]$Salida  = 'D:\2026-projects\ojo\escenas\precision-uia-vs-vlm.png',
    # Por NOMBRE y no por numero. El numero caduca: el arbol de Discord cambia
    # entre ejecuciones (mensajes nuevos, presencias) y el control 18 de hace un
    # minuto es otro ahora. Se pinto una comparacion entera sobre el texto de un
    # chat por confiar en el indice.
    [object[]]$Casos = @(
        @{ q = 'silenciar micro';       uia = 'Mute';          vlm = @(0.52, 0.02) },
        @{ q = 'ajustes de usuario';    uia = 'User Settings'; vlm = @(0.98, 0.02) },
        @{ q = 'silenciar auriculares'; uia = 'Deafen';        vlm = @(0.95, 0.02) }
    )
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$uiaExe = 'D:\2026-projects\ojo\uia\target\release\ojo-uia.exe'

# UIA lee los rectangulos aunque la ventana este tapada o en otro espacio de
# trabajo -- que es justo lo que paso la primera vez: los rectangulos de Firefox
# cayeron sobre la captura de Zed y la imagen no valia nada. Para comparar hay
# que verla, asi que se le da el foco por GlazeWM y se devuelve al acabar.
$vs = (& glazewm query windows | ConvertFrom-Json).data.windows
$antes = $vs | Where-Object { $_.hasFocus } | Select-Object -First 1
$obj = $vs | Where-Object { $_.title -like "*$Ventana*" -or $_.processName -like "*$Ventana*" } | Select-Object -First 1
if (-not $obj) { throw "GlazeWM no conoce ninguna ventana '$Ventana'" }
& glazewm command focus --container-id $obj.id | Out-Null
Start-Sleep -Milliseconds 700

try {
    $j = & $uiaExe --max 300 --ventana $Ventana | ConvertFrom-Json
    $m = $j.monitor   # x, y, ancho, alto
    $bmp = New-Object Drawing.Bitmap $m[2], $m[3]
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($m[0], $m[1], 0, 0, (New-Object Drawing.Size $m[2], $m[3]))
} finally {
    if ($antes) { & glazewm command focus --container-id $antes.id | Out-Null }
}
$g.SmoothingMode = 'AntiAlias'

$verde = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(255, 80, 230, 120)), 4
$rojo  = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(255, 245, 70, 70)), 4
$fuente = New-Object Drawing.Font 'Segoe UI', 13, ([Drawing.FontStyle]::Bold)
$fondo = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(230, 20, 18, 16))
$blanco = [Drawing.Brushes]::White

function Etiqueta($g, $t, $x, $y, $color) {
    $s = $g.MeasureString($t, $fuente)
    $g.FillRectangle($fondo, $x, $y, $s.Width + 10, $s.Height + 4)
    $g.DrawRectangle($color, $x, $y, $s.Width + 10, $s.Height + 4)
    $g.DrawString($t, $fuente, $blanco, ($x + 5), ($y + 2))
}

$i = 0
foreach ($c in $Casos) {
    # Escalonar las etiquetas: los tres botones estan pegados y las cajas de
    # texto se tapaban entre ellas.
    $desvio = 26 * $i; $i++
    $ctl = $j.controles | Where-Object { $_.nombre -eq $c.uia } | Select-Object -First 1
    if (-not $ctl) { Write-Warning "no hay control llamado '$($c.uia)'" }
    if ($ctl) {
        $w = $ctl.w * $m[2]; $h = $ctl.h * $m[3]
        $x = $ctl.x * $m[2] - $w / 2; $y = $ctl.y * $m[3] - $h / 2
        $g.DrawRectangle($verde, $x, $y, $w, $h)
        Etiqueta $g ("UIA: " + $ctl.nombre) ([int]$x) ([int]($y + $h + 6 + $desvio)) $verde
    }
    # La cruz del modelo: dos aspas, que sobre una interfaz clara se ve mejor
    # que un circulo relleno.
    $px = $c.vlm[0] * $m[2]; $py = $c.vlm[1] * $m[3]
    $r = 18
    $g.DrawLine($rojo, ($px - $r), ($py - $r), ($px + $r), ($py + $r))
    $g.DrawLine($rojo, ($px + $r), ($py - $r), ($px - $r), ($py + $r))
    Etiqueta $g ("modelo solo: " + $c.q) ([int][Math]::Min($px - 120, $m[2] - 360)) ([int]($py + $r + 6 + $desvio)) $rojo
}

Etiqueta $g 'verde = rectangulo exacto de UI Automation   |   rojo = coordenada adivinada por el modelo' 20 20 $verde

New-Item -ItemType Directory -Force (Split-Path $Salida) | Out-Null
$bmp.Save($Salida, [Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Host "guardado $Salida"



