#Requires -Version 5.1
<#
Comprobaciones de Verificar-Decir (ojo.ps1), sin modelo: frases escritas a
mano con lo que DEBE salir marcado como sin respaldo. Las funciones se leen del
propio ojo.ps1, asi que se prueba lo que corre.

    .\prueba-verificar.ps1
#>
$ErrorActionPreference = 'Stop'
$errores = $null
$ast = [Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot\ojo.ps1", [ref]$null, [ref]$errores)
if ($errores.Count) { $errores | ForEach-Object { "SINTAXIS $($_.Extent.StartLineNumber): $($_.Message)" }; exit 2 }
$ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -in 'Plano', 'Verificar-Decir', 'Hechos-Sistema' }, $true) |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

$ev = "HECHOS VERIFICADOS:`nhora: 11:28`nfecha: miércoles 23 de septiembre de 2026`n" +
      "WORKSPACES: Discord «ALAN»; firefox «WhatsApp»`n" +
      "RESULTADOS WEB: [elperu.pe] un dólar equivale a S/ 3.362 ... [dolargpt.pe] S/ 3.44 compra"
$casos = @(
    @{ d = 'Son las 11:28.';                                              faltan = @() }
    @{ d = 'Son las 12:05.';                                              faltan = @('12:05') }
    @{ d = 'Hoy es miércoles 23 de septiembre de 2026.';                  faltan = @() }
    @{ d = 'Según elperu.pe, el dólar está a 3.362 soles.';               faltan = @() }
    @{ d = 'El dólar está a 3,362 soles.';                                faltan = @() }
    @{ d = 'El dólar está a 3.51 soles.';                                 faltan = @('3.51') }
    @{ d = 'Tienes abiertos Discord y WhatsApp.';                         faltan = @() }
    @{ d = 'Tienes abiertos Discord y Spotify.';                          faltan = @('Spotify') }
    @{ d = '¿Quieres algo más? Déjame buscarlo.';                         faltan = @() }
    @{ d = "Discord: te escribieron 'Llegué' hace poco.";                  faltan = @() }
    # "23" esta en la fecha; "23H2" no esta en ningun sitio.
    @{ d = 'La última versión es la 23H2.';                                faltan = @('23H2') }
)
$mal = 0
foreach ($c in $casos) {
    $f = @(Verificar-Decir $c.d $ev)
    $ok = (($f -join '|') -eq ($c.faltan -join '|'))
    if (-not $ok) { $mal++; Write-Host "FALLA: '$($c.d)' -> [$($f -join ', ')], tocaba [$($c.faltan -join ', ')]" -ForegroundColor Red }
}
$h = Hechos-Sistema -SinVentana
if ($h -notmatch "hora: $(Get-Date -Format HH:mm)") { $mal++; Write-Host "FALLA: Hechos-Sistema sin la hora: $h" -ForegroundColor Red }
if ($mal) { exit 2 }
Write-Host "$($casos.Count + 1) comprobaciones OK" -ForegroundColor Green
