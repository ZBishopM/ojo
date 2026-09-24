<#
Latencia de Ojo por pregunta, medida como la percibe `hablar.ps1`: desde que se
lanza `ojo.ps1` hasta que la escena sale hacia el overlay.

POR QUE EXISTE: en la tanda limpia del 2026-09-21, entre 830 y 1.122 ms de
cada frase se iban FUERA de todas las etapas medidas (captura, UIA, memoria,
modelo). Es el segundo mayor coste despues del modelo, y no aparecia en
ninguna columna.

    .\medir-latencia.ps1 -Nombre antes
    .\medir-latencia.ps1 -Nombre despues -Vueltas 2

Las preguntas son fijas y no piden un sitio concreto, para que el modelo haga
siempre un trabajo parecido y lo que cambie sea la fontaneria.
#>
param(
    [Parameter(Mandatory)][string]$Nombre,
    [int]$Vueltas = 1,
    [string]$Raiz = 'D:\2026-projects\ojo',
    [string]$Shell = 'powershell',
    # Mide el camino ENTERO del atajo: lanza hablar.ps1 (con -Texto, sin
    # microfono) en vez de ojo.ps1. Asi entran los dos arranques de PowerShell.
    [switch]$PorHablar
)
$ErrorActionPreference = 'Stop'
$PREGUNTAS = @(
    'que aplicacion es esta?'
    'que hora es segun la barra?'
    'cuanta RAM estoy usando?'
    'que archivo tengo abierto?'
    'que hay en la esquina inferior derecha?'
)
$filas = @()
for ($v = 1; $v -le $Vueltas; $v++) {
    foreach ($q in $PREGUNTAS) {
        $t0 = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
        if ($PorHablar) {
            & $Shell -NoProfile -ExecutionPolicy Bypass -File "$Raiz\hablar.ps1" -Texto $q -Segundos 0 *> $null
        } else {
            & $Shell -NoProfile -ExecutionPolicy Bypass -File "$Raiz\ojo.ps1" $q -Segundos 0 *> $null
        }
        $j = [IO.File]::ReadAllText("$Raiz\ultima-medida.json", [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        if ($j.pregunta -ne $q) { Write-Warning "la medida no es de esta pregunta: '$($j.pregunta)'"; continue }
        $total = $j.fin_epoch_ms - $t0
        $etapas = 0
        foreach ($k in 'captura_ms', 'uia_ms', 'memoria_ms', 'modelo_ms') { if ($j.$k) { $etapas += [int]$j.$k } }
        $filas += [pscustomobject]@{ q = $q; total = $total; modelo = $j.modelo_ms; etapas = $etapas; fuera = $total - $etapas }
    }
}
$med = { param($xs) $s = @($xs | Sort-Object); $s[[int]($s.Count / 2)] }
$res = [ordered]@{
    nombre   = $Nombre
    n        = $filas.Count
    total    = & $med $filas.total
    modelo   = & $med $filas.modelo
    fuera    = & $med $filas.fuera
    filas    = $filas
}
$f = "$Raiz\medir-latencia.json"
$todas = @(if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json | ForEach-Object { $_ } }) + [pscustomobject]$res
$todas | ConvertTo-Json -Depth 5 | Set-Content $f -Encoding utf8
[pscustomobject]$res
