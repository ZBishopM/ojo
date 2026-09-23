#Requires -Version 5.1
<#
La memoria de personas de punta a punta, con el modelo y SIN tocar la memoria
real: se copia personas\ aparte, se prueba, y se deja como estaba.

Lo esperado, escrito antes de correr:
  1. "Mi hermana se llama Ana y estudia medicina"  -> recuerda nombre Ana y el hecho
  2. "¿Cómo se llama mi hermana?"                  -> dice Ana
  3. "Hoy vi a Luis en el cine"                     -> una curiosidad sobre Luis
  4. "Luis me contó que se muda a Cusco"            -> otra curiosidad, NO la misma
  5. "¿Qué sabes de Melly?"                         -> no inventa nada (no sabe nada)
  6. "Me llamo Bishop"                              -> recuerda el nombre del usuario
  7. "Cuéntame algo"                                -> curiosidad sobre alguien

    .\prueba-personas.ps1
#>
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$dir = Join-Path $raiz 'personas'
$copia = Join-Path $env:TEMP "ojo-personas-copia-$PID"
if (Test-Path $dir) { Copy-Item $dir $copia -Recurse -Force }
$histCopia = if (Test-Path "$raiz\historial.json") { [IO.File]::ReadAllText("$raiz\historial.json") }
Remove-Item $dir -Recurse -Force -EA SilentlyContinue
Remove-Item "$raiz\historial.json" -EA SilentlyContinue

function Preguntar($q) {
    $ErrorActionPreference = 'Continue'
    $null = & "$raiz\ojo.ps1" -Pregunta $q -Voz '' -Segundos 0 *>&1
    [IO.File]::ReadAllText("$raiz\ultima-medida.json", [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
}
$fallos = @()
try {
    $m = Preguntar 'Mi hermana se llama Ana y estudia medicina'
    "1 dijo: $($m.dijo)`n  recordo: $($m.recordo)"
    $h = [IO.File]::ReadAllText("$dir\hermana.json") | ConvertFrom-Json
    if ($h.nombre -ne 'Ana') { $fallos += "1: nombre de la hermana = '$($h.nombre)'" }
    if (-not (@($h.hechos) | Where-Object { $_.hecho -match '(?i)medicina' })) { $fallos += '1: no recordo lo de medicina' }

    $m = Preguntar '¿Cómo se llama mi hermana?'
    "2 dijo: $($m.dijo)"
    if ($m.dijo -notmatch 'Ana') { $fallos += "2: no dijo Ana: $($m.dijo)" }

    $m = Preguntar 'Hoy vi a Luis en el cine'
    "3 dijo: $($m.dijo)`n  curiosidad: $($m.curiosidad)"
    $c1 = $m.curiosidad
    # La curiosidad cuenta tanto en su campo como dicha en la respuesta.
    if (-not $c1 -and $m.dijo -notmatch '\?') { $fallos += '3: sin curiosidad sobre Luis' }

    $m = Preguntar 'Luis me contó que se muda a Cusco'
    "4 dijo: $($m.dijo)`n  curiosidad: $($m.curiosidad)`n  recordo: $($m.recordo)"
    if ($m.curiosidad -and $m.curiosidad -eq $c1) { $fallos += '4: repitio la curiosidad' }

    $m = Preguntar '¿Qué sabes de Melly?'
    "5 dijo: $($m.dijo)"
    $mel = [IO.File]::ReadAllText("$dir\melly.json") | ConvertFrom-Json
    if (@($mel.hechos).Count) { $fallos += "5: guardo hechos de Melly sin que se los contaran: $(@($mel.hechos).hecho -join '; ')" }
    # La primera vez busco en internet y contesto con un rapero homonimo.
    if ($m.dijo -match '(?i)rapero|YNW|seg[uú]n' -or $m.busco) { $fallos += "5: fue a internet por una persona de su vida: $($m.dijo)" }
    # Y sin atribuirle el perfil del usuario (le dijo "vive en Peru y juega League").
    if ($m.dijo -match '(?i)per[uú]|league|hearthstone|discord') { $fallos += "5: le atribuyo el perfil del usuario a Melly: $($m.dijo)" }

    $m = Preguntar 'Me llamo Bishop'
    "6 dijo: $($m.dijo)`n  recordo: $($m.recordo)"
    $yo = [IO.File]::ReadAllText("$dir\yo.json") | ConvertFrom-Json
    if ($yo.nombre -ne 'Bishop') { $fallos += "6: nombre del usuario = '$($yo.nombre)'" }
    if ($m.dijo -match '(?i)me llamo') { $fallos += "6: habla como si el fuera Bishop: $($m.dijo)" }

    $m = Preguntar 'Cuéntame algo'
    "7 dijo: $($m.dijo)`n  curiosidad: $($m.curiosidad)"
    if (-not $m.curiosidad -and $m.dijo -notmatch '\?') { $fallos += '7: sin tema y sin curiosidad' }
} finally {
    # La memoria real, como estaba.
    Remove-Item $dir -Recurse -Force -EA SilentlyContinue
    if (Test-Path $copia) { Move-Item $copia $dir }
    if ($histCopia) { [IO.File]::WriteAllText("$raiz\historial.json", $histCopia) } else { Remove-Item "$raiz\historial.json" -EA SilentlyContinue }
}
if ($fallos) { Write-Host "`nFALLA:`n  $($fallos -join "`n  ")" -ForegroundColor Red; exit 2 }
Write-Host "`n7 comprobaciones OK" -ForegroundColor Green
