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
$ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -in 'Plano', 'Verificar-Decir', 'Hechos-Sistema', 'Distancia-Corta' }, $true) |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }

$ev = "HECHOS VERIFICADOS:`nhora: 11:28`nfecha: miércoles 23 de septiembre de 2026`n" +
      "WORKSPACES: Discord «ALAN»; firefox «WhatsApp»`n" +
      "RESULTADOS WEB: [elperu.pe] un dólar equivale a S/ 3.362 ... [dolargpt.pe] S/ 3.44 compra`n" +
      "[es.lugares.org] La capital de Australia es Canberra. El campeón es T1."
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
    # Cifra con letras en mayusculas contra evidencia en minusculas.
    @{ d = 'Lo ganó T1, según elperu.';                                    faltan = @() }
    # Una letra de diferencia en un nombre largo vale; dos no.
    @{ d = 'Según elperu, la capital es Camberra.';                        faltan = @() }
    @{ d = 'Según Wikipedia, la capital es Canberra.';                     faltan = @('Wikipedia') }
)
$mal = 0
foreach ($c in $casos) {
    $f = @(Verificar-Decir $c.d $ev)
    $ok = (($f -join '|') -eq ($c.faltan -join '|'))
    if (-not $ok) { $mal++; Write-Host "FALLA: '$($c.d)' -> [$($f -join ', ')], tocaba [$($c.faltan -join ', ')]" -ForegroundColor Red }
}
$ast.FindAll({ $args[0] -is [Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Motivo-Sin-Web' }, $true) |
    ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
$m = Motivo-Sin-Web ([pscustomobject]@{ caidos = @{ duckduckgo = 'CAPTCHA'; brave = 'too many requests' } }) 'dolar hoy'
if ($m -notmatch 'Duckduckgo me pide un CAPTCHA' -or $m -notmatch 'Brave dice que son demasiadas') { $mal++; Write-Host "FALLA: Motivo-Sin-Web: $m" -ForegroundColor Red }
$m2 = Motivo-Sin-Web ([pscustomobject]@{ caidos = @{} }) 'x'
if ($m2 -notmatch 'ningún buscador encontró') { $mal++; Write-Host "FALLA: Motivo-Sin-Web sin caidos: $m2" -ForegroundColor Red }
$h = Hechos-Sistema -SinVentana
if ($h -notmatch "hora: $(Get-Date -Format HH:mm)") { $mal++; Write-Host "FALLA: Hechos-Sistema sin la hora: $h" -ForegroundColor Red }
if ($mal) { exit 2 }
Write-Host "$($casos.Count + 3) comprobaciones OK" -ForegroundColor Green
