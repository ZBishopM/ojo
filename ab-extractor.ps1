#Requires -Version 5.1
<#
A/B de extractor de texto web: mi regex (Texto-De-Html) contra Trafilatura,
sobre las MISMAS paginas descargadas. Por pregunta, cuantas de las 3 paginas
leidas contienen el dato clave en el texto que le llegaria al modelo, y
cuanto tarda cada extractor.

    .\ab-extractor.ps1
#>
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$BUSCAR_EXTRACTOR = 'regex'
. "$raiz\buscar.ps1"

# Consulta y lo que DEBE aparecer en el texto extraido si la pagina trae el dato.
$CASOS = @(
    ,@('precio del dolar hoy en peru', 'S/\s?\d[.,]\d{2,3}|\d[.,]\d{2,3}\s*soles')
    ,@('quien gano el ultimo mundial de league of legends', '\bT1\b')
    ,@('ultima version de windows 11', '\b2[45]H2\b')
    ,@('clima hoy en lima', '\d+\s?°|\d+\s?grados')
    ,@('quien gano la ultima champions league', '(?i)psg|paris saint')
    ,@('capital de australia', '(?i)canberra')
)
$dir = Join-Path $env:TEMP 'ojo-paginas'
$filas = foreach ($c in $CASOS) {
    $q = $c[0]; $clave = $c[1]
    $null = Buscar-Web @($q)
    $html = @(Get-ChildItem $dir -Filter '*.html' -EA SilentlyContinue | Sort-Object Name | ForEach-Object FullName)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $reg = @($html | ForEach-Object { Lo-Relevante (Texto-De-Html ([IO.File]::ReadAllText($_, [Text.UTF8Encoding]::new($false)))) $q })
    $msR = $sw.ElapsedMilliseconds
    $sw.Restart()
    $tr = @(if ($html) { (& $BUSCAR_PYTHON "$raiz\extraer.py" @html 2>$null) -join "`n" | ConvertFrom-Json })
    $tr = @($tr | ForEach-Object { Lo-Relevante @("$_" -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -ge 20 }) $q })
    $msT = $sw.ElapsedMilliseconds
    [pscustomobject]@{
        consulta = $q; paginas = $html.Count
        regex = @($reg | Where-Object { $_ -match $clave }).Count; trafilatura = @($tr | Where-Object { $_ -match $clave }).Count
        chars_regex = ($reg | Measure-Object Length -Sum).Sum; chars_trafi = ($tr | Measure-Object Length -Sum).Sum
        ms_regex = $msR; ms_trafi = $msT
    }
}
$filas | Format-Table -AutoSize | Out-String -Width 200
"total con el dato: regex {0}, trafilatura {1} (de {2} paginas)" -f ($filas | Measure-Object regex -Sum).Sum, ($filas | Measure-Object trafilatura -Sum).Sum, ($filas | Measure-Object paginas -Sum).Sum
