#Requires -Version 5.1
<#
La build que se esta jugando AHORA para un campeon en un modo, sacada de la
web (op.gg), con la fuente citada.

POR QUE LA WEB: "que me armo" es opinion que cambia cada parche, y ningun dato
local lo tiene. Data Dragon dejo de publicar las builds recomendadas (el campo
`recommended` viene vacio). La regla del usuario es que Ojo no invente ni diga
"no se": que lo busque y cite.

POR QUE op.gg: sirve la build en la propia pagina (HTML del servidor), cubre
la Grieta, ARAM y ARAM Mayhem, y su robots.txt permite leer esas rutas
(`User-Agent: * / Allow: /`; lo prohibido son las rutas con parametros para
algunos buscadores). metasrc devuelve 403 y blitz tiene reglas especificas
para los agentes de Claude: descartados. Comprobado el 2026-09-22.

LO QUE SE TOMA, y como:
  - items por su NUMERO (/item/6657.png), traducidos con el catalogo es_MX:
    asi coinciden con los nombres del cliente del usuario
  - aumentos por su CLAVE interna (aram-augment/Marksmage_large.png),
    traducidos con la lista oficial de aumentos del cliente
  - SIN porcentajes de victoria de aumentos: la politica de Riot prohibe
    mostrarlos en productos de terceros

Una lectura por campeon, modo y parche: se cachea en ddragon\<parche>\builds\.

    .\builds.ps1 Sylas KIWI        la build, legible
    .\builds.ps1 -Prueba           comprobaciones contra una pagina guardada
    . .\builds.ps1                 (con punto) solo las funciones
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\ddragon.ps1"

$BUILDS_URL = @{
    KIWI    = 'https://op.gg/lol/modes/aram-mayhem/{0}/build'
    ARAM    = 'https://op.gg/lol/modes/aram/{0}/build'
    CLASSIC = 'https://op.gg/lol/champions/{0}/build'
}
# La CLASIFICACION ENTERA de aumentos para el campeon (solo Mayhem): la pagina
# de build trae 10, y en cada eleccion te ofrecen 3 de 291 -- casi nunca
# estarian. Esta trae ~170, en el orden en que op.gg los clasifica. Se usa solo
# el ORDEN, nunca porcentajes (politica de Riot).
$BUILDS_URL_AUMENTOS = 'https://op.gg/lol/modes/aram-mayhem/{0}/augments'

# Aumentos de una pagina, en orden de primera aparicion, traducidos al nombre
# del cliente (es_MX) por su clave interna.
function Aumentos-De($html, $cat) {
    # Cada imagen lleva alt="<nombre en ingles>" y la clave en la ruta. Se
    # traduce por la clave y, si no esta, por el nombre ingles.
    @([regex]::Matches($html, '<img alt="([^"]*)"[^>]*?aram-augment/([A-Za-z0-9_]+?)_(?:large|small)\.png') |
      ForEach-Object {
          $clave = ($_.Groups[2].Value.ToLowerInvariant()) -replace '^aram_', '' -replace '^quest_?', ''
          $es = $cat.aumentos_k.$clave
          if (-not $es) { $es = $cat.aumentos_en.((Normalizar-Texto ([Net.WebUtility]::HtmlDecode($_.Groups[1].Value))).Trim()) }
          $es
      } | Where-Object { $_ } | Select-Object -Unique)
}
$BUILDS_NAVEGADOR = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36'

# El HTML de la pagina, en UTF-8, por curl (como el resto: sin tocar el
# ServicePointManager del proceso).
function Bajar-Pagina($url) {
    $tmp = Join-Path $env:TEMP 'ojo-build.html'
    & curl.exe -sL -A $BUILDS_NAVEGADOR --max-time 20 -o $tmp $url 2>$null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmp)) { return $null }
    try { [IO.File]::ReadAllText($tmp, [Text.UTF8Encoding]::new($false)) } finally { Remove-Item $tmp -EA SilentlyContinue }
}

# Los numeros de item de un trozo de pagina, en orden y sin repetir.
function Ids-De($trozo) {
    @([regex]::Matches($trozo, '/item/(\d{4,6})\.png') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
}

# El trozo de pagina de una seccion: de su titulo al titulo siguiente. La
# pagina repite el contenido (una version para movil); vale la primera vez.
function Seccion($html, $titulo, $siguientes) {
    $i = $html.IndexOf(">$titulo<")
    if ($i -lt 0) { return '' }
    $fin = $html.Length
    foreach ($s in $siguientes) {
        $j = $html.IndexOf(">$s<", $i + 1)
        if ($j -gt $i -and $j -lt $fin) { $fin = $j }
    }
    $html.Substring($i, $fin - $i)
}

function Leer-Build($html, $cat) {
    $titulos = 'Starter items', 'Boots', 'Core builds', 'Augments', 'Skills', 'Skill order', 'Runes'
    $nombre = { param($id) $n = $cat.items.$id.nombre; if ($n) { $n } else { $null } }
    $iniciales = @(Ids-De (Seccion $html 'Starter items' $titulos) | ForEach-Object { & $nombre $_ } | Where-Object { $_ })
    # Solo lo que ES botas: en la pagina de la Grieta la seccion se alarga hasta
    # los items de soporte (salian la Espina de Zaz'Zak y Oposicion Celestial).
    $botas     = @(Ids-De (Seccion $html 'Boots' $titulos) | Where-Object { @($cat.items.$_.tags) -contains 'Boots' } |
                   ForEach-Object { & $nombre $_ } | Where-Object { $_ })
    # La primera fila de "Core builds" es la mas jugada; con las siguientes se
    # llega a los items que mas se repiten. Se quitan las botas y lo inicial.
    $nucleo    = @(Ids-De (Seccion $html 'Core builds' $titulos) | ForEach-Object { & $nombre $_ } |
                   Where-Object { $_ -and $botas -notcontains $_ -and $iniciales -notcontains $_ } | Select-Object -First 6)
    # Los aumentos, de TODA la pagina: el primer ">Augments<" es una pestana de
    # navegacion, no la seccion, y cortando por titulos salian cero. Sus
    # imagenes solo aparecen en las secciones de aumentos, en orden.
    $aum = @([regex]::Matches($html, 'aram-augment/([A-Za-z0-9_]+?)_(?:large|small)\.png') |
             ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique |
             ForEach-Object { $cat.aumentos_k.($_.ToLowerInvariant() -replace '^aram_', '') } | Where-Object { $_ } | Select-Object -First 5)
    [ordered]@{ iniciales = $iniciales; botas = $botas; nucleo = $nucleo; aumentos = $aum }
}

# La build de un campeon en un modo. Cacheada por parche: una lectura de la web
# por campeon y modo cada dos semanas.
# Del id del campeon ("MonkeyKing", el de rawChampionName sin prefijo) al nombre
# que usa op.gg en la ruta. Casi siempre es el mismo en minusculas.
function Slug-Campeon($id) {
    $s = ("$id" -replace '^game_character_displayname_', '' -replace '[^A-Za-z]', '').ToLowerInvariant()
    if ($s -eq 'monkeyking') { 'wukong' } else { $s }
}

function Archivo-Build($campeon, $modo, $cat) {
    $modo = if ($BUILDS_URL[$modo]) { $modo } else { 'CLASSIC' }
    $dir = Join-Path $cat.dir 'builds'
    New-Item -ItemType Directory -Force $dir | Out-Null
    Join-Path $dir "$modo-$(Slug-Campeon $campeon).json"
}

# Solo la cache: para contestar YA, sin esperar a la web (la primera lectura
# tarda ~8 s). Si no esta, $null.
# En Mayhem, una build sin la clasificacion de aumentos es de antes de que se
# leyera: cuenta como que no esta, y se vuelve a bajar.
function Get-BuildCacheada($campeon, $modo, $cat) {
    $f = Archivo-Build $campeon $modo $cat
    if (-not (Test-Path $f)) { return }
    $b = [IO.File]::ReadAllText($f, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    if ($modo -eq 'KIWI' -and -not @($b.ranking_aumentos).Count) { return }
    $b
}

# De los aumentos que ofrecen ("Nombre: resumen"), el mejor clasificado por
# op.gg para el campeon. $null si ninguno esta en la clasificacion.
function Elegir-Aumento($ofrecidos, $ranking) {
    $ranking = @($ranking)
    @($ofrecidos) | ForEach-Object { [pscustomobject]@{ texto = $_; puesto = [array]::IndexOf($ranking, ($_ -split ':')[0]) } } |
        Where-Object { $_.puesto -ge 0 } | Sort-Object puesto | Select-Object -First 1
}

function Get-Build($campeon, $modo, $cat) {
    $modo = if ($BUILDS_URL[$modo]) { $modo } else { 'CLASSIC' }
    $slug = Slug-Campeon $campeon
    $f = Archivo-Build $campeon $modo $cat
    $b = Get-BuildCacheada $campeon $modo $cat
    if ($b) { return $b }
    $url = $BUILDS_URL[$modo] -f $slug
    $html = Bajar-Pagina $url
    if (-not $html) { return $null }
    $b = Leer-Build $html $cat
    if (-not $b.nucleo.Count) { return $null }     # pagina cambiada o vacia: no se cachea basura
    $b['fuente'] = "op.gg, parche $($cat.parche)"
    if ($modo -eq 'KIWI') {
        $ha = Bajar-Pagina ($BUILDS_URL_AUMENTOS -f $slug)
        if ($ha) { $b['ranking_aumentos'] = @(Aumentos-De $ha $cat) }
    }
    [IO.File]::WriteAllText($f, ($b | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    [pscustomobject]$b
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ($args -contains '-Prueba') {
    # Contra una pagina guardada (op.gg, Sylas en ARAM Mayhem, 2026-09-22). Lo
    # esperado, escrito a mano mirando la pagina: la Vara de las Edades (6657)
    # y el Agrietador (4633) en el nucleo, y Tirador Magico entre los aumentos.
    $cat = Get-DDragon
    $html = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'prueba-lol\muestra-opgg-sylas-mayhem.html'), [Text.UTF8Encoding]::new($false))
    $b = Leer-Build $html $cat
    $fallos = @()
    foreach ($id in '6657', '4633') { if ($b.nucleo -notcontains $cat.items.$id.nombre) { $fallos += "falta $($cat.items.$id.nombre) en el nucleo: $($b.nucleo -join ', ')" } }
    if ($b.aumentos -notcontains 'Tirador Mágico') { $fallos += "falta Tirador Magico en los aumentos: $($b.aumentos -join ', ')" }
    if (-not $b.botas.Count) { $fallos += 'sin botas' }
    if (@($b.nucleo | Where-Object { $b.botas -contains $_ }).Count) { $fallos += 'botas repetidas en el nucleo' }
    $b | ConvertTo-Json -Depth 4 | Write-Host
    if ($fallos) { Write-Host "`nFALLA:`n  $($fallos -join "`n  ")" -ForegroundColor Red; exit 2 }
    Write-Host "`n6 comprobaciones OK" -ForegroundColor Green
    exit 0
}

if ($args -contains '-Precargar') {
    # Lo lanza el supervisor cuando ARRANCA el juego (proceso "League of
    # Legends"): durante la pantalla de carga hay de sobra para bajar la build
    # (~8 s) y la primera eleccion de aumento ya la encuentra en cache. El
    # campeon y el modo, del cliente: la API de la partida aun no esta abierta.
    . "$PSScriptRoot\lcu.ps1"
    $cat = Get-DDragon
    $con = Get-LcuConexion
    if (-not $con) { exit 1 }
    $s = Invoke-Lcu $con '/lol-gameflow/v1/session'
    $yo = (Invoke-Lcu $con '/lol-summoner/v1/current-summoner').puuid
    $n = (@($s.gameData.playerChampionSelections) | Where-Object puuid -eq $yo | Select-Object -First 1).championId
    $nombre = $cat.campeones_n.([string]$n)
    $id = ($cat.campeones.PSObject.Properties | Where-Object { $_.Value.nombre -eq $nombre } | Select-Object -First 1).Name
    if (-not $id) { exit 1 }
    $b = Get-Build $id "$($s.gameData.queue.gameMode)" $cat
    "$id $($s.gameData.queue.gameMode): $(if ($b) { "$(@($b.ranking_aumentos).Count) aumentos clasificados" } else { 'sin build' })"
    exit 0
}

$campeon = $args | Where-Object { $_ -notlike '-*' } | Select-Object -First 1
$modo = $args | Where-Object { $_ -notlike '-*' } | Select-Object -Skip 1 -First 1
$b = Get-Build $campeon $modo (Get-DDragon)
if (-not $b) { exit 1 }
$b | ConvertTo-Json -Depth 4
