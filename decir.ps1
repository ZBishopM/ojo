<#
Limpia la frase que Ojo va a decir antes de que llegue al usuario.

POR QUE EXISTE: el modelo elige el control por su NUMERO en la lista (asi
señala exacto), y a veces ese numero se le escapa a la frase: "El boton de
cerrar esta en la lista de controles, numero 23", "esta en el control numero
26". El usuario lo puntuo como "imposible de digerir". En las sesiones grabadas
del 21 y 22 de septiembre pasa en 2 de las 10 respuestas que señalaron un
control.

El prompt ya lo pide, pero un prompt es una peticion, no una garantia. Esto lo
arregla siempre: cambia la referencia numerica por el NOMBRE del control.

    . .\decir.ps1                (con punto) solo define la funcion
    .\decir.ps1                  corre las comprobaciones

Sin bloque param(), por la misma razon que lol.ps1 y ddragon.ps1.
#>

# "(en) (el|la) boton|control|elemento|opcion|lista de controles (,) (numero|n.) N"
$DECIR_PATRON = '(?i)(?<en>\ben\s+)?(?:(?:el|la)\s+)?(?:lista\s+de\s+controles|control|bot[oó]n|elemento|opci[oó]n)\s*,?\s*(?:n[uú]mero\s*|n[º°.]\s*)?(?<n>\d{1,3})\b'

function Limpiar-Decir([string]$texto, $controles) {
    if (-not $texto -or -not @($controles).Count) { return $texto }
    [regex]::Replace($texto, $DECIR_PATRON, {
        param($m)
        $n = [int]$m.Groups['n'].Value
        $c = @($controles | Where-Object { [int]$_.n -eq $n }) | Select-Object -First 1
        # Un numero que no es de la lista (un "paso 2", una hora) se deja como
        # esta: solo se toca lo que es de verdad un indice de control.
        if (-not $c) { return $m.Value }
        $prefijo = if ($m.Groups['en'].Success) { 'en ' } else { '' }
        "$prefijo`"$($c.nombre)`""
    })
}

if ($MyInvocation.InvocationName -eq '.') { return }

# ---- Comprobaciones, con las frases reales de las sesiones --------------------
$ctl = @(
    [pscustomobject]@{ n = 19; nombre = 'Mute' }
    [pscustomobject]@{ n = 23; nombre = 'Cerrar' }
    [pscustomobject]@{ n = 26; nombre = 'Mute' }
)
# La coma delante de cada par NO sobra: sin ella PowerShell aplana los pares
# en una sola lista de frases sueltas.
$casos = @(
    ,@('El silencio del micrófono está en el botón 19.',                    'El silencio del micrófono está en "Mute".')
    ,@('El botón de cerrar está en la lista de controles, número 23.',      'El botón de cerrar está en "Cerrar".')
    ,@('El botón de silencio está en el control número 26.',                'El botón de silencio está en "Mute".')
    ,@("Para silenciar el micrófono, haz clic en el botón 'Mute'.",         "Para silenciar el micrófono, haz clic en el botón 'Mute'.")
    ,@('Primero pulsa el paso 2 y espera 30 segundos.',                     'Primero pulsa el paso 2 y espera 30 segundos.')
    ,@('Está en el botón 99.',                                              'Está en el botón 99.')
)
$mal = 0
foreach ($c in $casos) {
    $r = Limpiar-Decir $c[0] $ctl
    if ($r -ne $c[1]) { $mal++; Write-Host "FALLA:`n  entra: $($c[0])`n  sale:  $r`n  debia: $($c[1])" -ForegroundColor Red }
}
if ($mal) { exit 2 }
Write-Host "$($casos.Count) comprobaciones OK" -ForegroundColor Green
