#Requires -Version 5.1
<#
El catalogo de League -- items y clase de cada campeon -- cacheado en disco.

QUE ES: Data Dragon, el CDN publico de Riot. Sin clave y en espanol:

    https://ddragon.leagueoflegends.com/api/versions.json
    https://ddragon.leagueoflegends.com/cdn/<version>/data/es_ES/item.json
    https://ddragon.leagueoflegends.com/cdn/<version>/data/es_ES/champion.json

LA CONSULTA NO TOCA LA RED. Se lee la cache mas reciente que haya en disco. La
red solo se usa al REFRESCAR (`-Refrescar`), que lo lanza `ojo.ps1` cuando el
servidor arranca en perfil de partida -- el evento de "empieza a jugar", que ya
existe --, y no en cada pregunta. La primera version consultaba versions.json
en cada pregunta: 100-300 ms de red por un dato que cambia cada dos semanas.

QUE **NO** ESTA AQUI: la build recomendada. El campo `recommended` de cada
campeon viene vacio -- Riot dejo de publicarlo (comprobado el 2026-09-22 con
Lux en el 16.18.1). Lo que conviene armarse cada parche es opinion, y eso solo
sale de la web.

Lo que si responde:
  - que items completos me puedo permitir, de los que encajan con mi clase
  - que item termino con las piezas que ya llevo y el oro que tengo

    .\ddragon.ps1                 dice que cache hay
    .\ddragon.ps1 -Refrescar      mira el parche actual y la rehace si cambio
    . .\ddragon.ps1               (con punto) solo define las funciones

SIN BLOQUE param(), A PROPOSITO. Un archivo que se carga con punto ejecuta su
param() en el ambito de QUIEN LO CARGA, y cada parametro pisa la variable del
mismo nombre de alli. Paso el 2026-09-22: lol.ps1 cargaba este archivo, su
-ComoModulo ponia el de lol.ps1 a verdadero, y lol.ps1 salia sin hacer nada
con codigo 0 -- y su prueba "pasaba". Es la sexta vez que esa familia de fallos
muerde en este proyecto. Sin param() no hay nada que pisar.
#>
$ErrorActionPreference = 'Stop'

# es_MX y no es_ES: el cliente del usuario (servidor LAS) escribe "Orbe del
# Guardian" con mayuscula, que es como lo da es_MX; es_ES lo da en minuscula.
# Los nombres tienen que coincidir con los que devuelve la API de la partida.
$DDragonIdioma = 'es_MX'
$DDragonCache = Join-Path $PSScriptRoot 'ddragon'
# Sube cuando cambia lo que se guarda: una cache vieja no se lee como buena.
$DDragonFormato = 'formato-v8'

# PowerShell 5.1 corre sobre un .NET que por defecto solo ofrece SSL3 y TLS 1.0,
# y el CDN de Riot los rechaza ("Se ha terminado la conexion: Error inesperado
# de envio"). Solo toca la parte de la red: se anade, no se quita nada.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor
    [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# WebClient con UTF-8 EXPLICITO, y no Invoke-RestMethod.
#
# En PowerShell 5.1, Invoke-RestMethod decodifica con el charset de la cabecera
# Content-Type, y este CDN no lo manda: cae en ISO-8859-1 y "Espada del
# guardian" se guardaba como "Espada del guardiAn". Esto va igual en 5.1 y 7.
function Bajar-Json($url) {
    $wc = New-Object Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    try { $wc.DownloadString($url) | ConvertFrom-Json } finally { $wc.Dispose() }
}

function Guardar($ruta, $obj) {
    [IO.File]::WriteAllText($ruta, ($obj | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
}

# Se guarda RECORTADO: item.json pesa ~1 MB con HTML, iconos y estadisticas que
# aqui no sirven.
#
# TODOS los mapas, y cada item con los suyos. La primera version guardaba solo
# la Grieta (mapa 11), y la primera partida real fue ARAM Mayhem (mapa 12): el
# modelo recibio el catalogo de otro mapa. Ahora se filtra al consultar, con el
# mapa que dice la propia partida.
function Build-DDragonCache($parche) {
    $crudo = Bajar-Json "https://ddragon.leagueoflegends.com/cdn/$parche/data/$DDragonIdioma/item.json"
    $items = @{}
    foreach ($p in $crudo.data.PSObject.Properties) {
        $i = $p.Value
        $mapas = @($i.maps.PSObject.Properties | Where-Object { $_.Value } | ForEach-Object { $_.Name })
        if (-not $mapas.Count) { continue }
        $items[$p.Name] = [ordered]@{
            nombre    = $i.name
            mapas     = $mapas
            rm        = [bool]($i.stats.FlatSpellBlockMod -gt 0)    # resistencia magica
            armadura  = [bool]($i.stats.FlatArmorMod -gt 0)
            total     = [int]$i.gold.total
            comprable = [bool]$i.gold.purchasable
            # `| Where-Object { $_ }` y NO `@($i.into)`: en PowerShell `@($null)`
            # es un array de UN elemento nulo, Count = 1. Un item completo -- sin
            # `into` -- parecia subir a algo y el filtro los descartaba todos.
            tags      = @($i.tags | Where-Object { $_ })
            de        = @($i.from | Where-Object { $_ })   # sus piezas
            sube_a    = @($i.into | Where-Object { $_ })   # en que se convierte
            # Lo que el item DA de verdad. Las etiquetas de Riot no son fiables
            # (comprobado): Bandlemusa lleva `AttackSpeed` y no da velocidad de
            # ataque; el Elixir de colera lleva `Damage` y es un consumible.
            ap        = [bool]($i.stats.FlatMagicDamageMod -gt 0)
            ad        = [bool]($i.stats.FlatPhysicalDamageMod -gt 0 -or $i.stats.FlatCritChanceMod -gt 0 -or $i.stats.PercentAttackSpeedMod -gt 0)
            defensa   = [bool]($i.stats.FlatHPPoolMod -gt 0 -or $i.stats.FlatArmorMod -gt 0 -or $i.stats.FlatSpellBlockMod -gt 0)
            # Lo que distingue a un tirador de un luchador: critico o velocidad.
            tirador   = [bool]($i.stats.FlatCritChanceMod -gt 0 -or $i.stats.PercentAttackSpeedMod -gt 0)
        }
    }
    $campeones = @{}
    $c = Bajar-Json "https://ddragon.leagueoflegends.com/cdn/$parche/data/$DDragonIdioma/champion.json"
    foreach ($p in $c.data.PSObject.Properties) {
        # La clave es el id interno ("MonkeyKing"), que es lo que trae la API de
        # la partida en `rawChampionName`; el nombre visible va aparte.
        $campeones[$p.Name] = [ordered]@{
            nombre = $p.Value.name; tags = @($p.Value.tags)
            # Valoraciones de Riot de 1 a 10. Dicen si pega con dano fisico o
            # magico mejor que la etiqueta: Katarina es "Assassin" y es de AP.
            ataque = [int]$p.Value.info.attack; magia = [int]$p.Value.info.magic
        }
    }
    # El historial de partidas del cliente habla en NUMEROS: championId 517,
    # playerAugment1 2087. Hacen falta las dos traducciones.
    $porNumero = @{}
    foreach ($p in $c.data.PSObject.Properties) { $porNumero[[string]$p.Value.key] = $p.Value.name }
    $aumId = @{}
    try {
        $ca = Bajar-Json 'https://raw.communitydragon.org/latest/plugins/rcp-be-lol-game-data/global/es_mx/v1/cherry-augments.json'
        foreach ($a in @($ca)) { if ($a.nameTRA) { $aumId[[string]$a.id] = $a.nameTRA } }
    } catch { }

    $destino = Join-Path $DDragonCache $parche
    New-Item -ItemType Directory -Force -Path $destino | Out-Null
    Guardar (Join-Path $destino 'items.json') $items
    Guardar (Join-Path $destino 'campeones.json') $campeones
    Guardar (Join-Path $destino 'campeones-por-numero.json') $porNumero
    Guardar (Join-Path $destino 'aumentos.json') (Build-Aumentos)
    Guardar (Join-Path $destino 'aumentos-por-numero.json') $aumId
    Set-Content (Join-Path $destino $DDragonFormato) 'ok'
    $destino
}

# Los AUMENTOS de ARAM Mayhem, con su resumen en espanol latino.
#
# POR QUE: en la primera partida real el usuario pregunto por un Jax AP "con
# Locomotora", y el modelo contesto con "la Locomotora de Jaxa" como si fuera
# un item. Locomotora es un aumento de oro de Mayhem, y la API de la partida NO
# trae los aumentos: el modelo no tenia forma de saberlo.
#
# De donde: Data Dragon no los tiene. CommunityDragon sirve la tabla de textos
# del propio cliente (es_mx, 33 MB), con `kiwi_<clave>_summary` -- "kiwi" es el
# nombre interno de Mayhem -- y el nombre en `kiwi_aram_<clave>_name`. 135
# aumentos con nombre y resumen (comprobado el 2026-09-22).
#
# Se lee con una expresion regular y no con ConvertFrom-Json: parsear 33 MB en
# PowerShell 5.1 es lento y se come la memoria, y solo hacen falta unas cientos
# de claves.
function Build-Aumentos {
    $tmp = Join-Path $env:TEMP 'ojo-stringtable-es_mx.json'
    & curl.exe -sSL --max-time 180 -o $tmp 'https://raw.communitydragon.org/latest/game/es_mx/data/menu/en_us/lol.stringtable.json'
    if ($LASTEXITCODE -ne 0) { return @{} }
    $txt = [IO.File]::ReadAllText($tmp, [Text.UTF8Encoding]::new($false))
    Remove-Item $tmp -EA SilentlyContinue
    $t = @{}
    foreach ($m in [regex]::Matches($txt, '"((?:kiwi|cherry)_[a-z0-9_]+)"\s*:\s*"((?:[^"\\]|\\.)*)"')) {
        $t[$m.Groups[1].Value] = [regex]::Unescape($m.Groups[2].Value)
    }

    # LOS NOMBRES salen de la lista oficial de aumentos del cliente, y el
    # conjunto de Mayhem de sus listas por modo (augment-lists.json) mas los
    # que empiezan por ARAM_: 293 aumentos.
    #
    # La primera version sacaba los nombres de la tabla de textos buscando
    # `kiwi_<x>_summary` y se quedo en 135: las claves son irregulares
    # (`kiwi_aram_archmage` sin `_name`, `kiwi_augment_burstingteeth_name`,
    # `cherry_frombeginningtoend_name`...) y se perdieron Archimago y De
    # Principio a Fin -- dos de los cuatro que el usuario eligio en su partida.
    $b = 'https://raw.communitydragon.org/latest/plugins/rcp-be-lol-game-data/global/es_mx/v1'
    # SIN @(...) alrededor: en 5.1, ConvertFrom-Json devuelve un array JSON como
    # UN solo objeto, y @(...) lo anida -- el bucle recorria "un aumento" que
    # era la lista entera, y la cache salia con una sola clave hecha de los 291
    # nombres pegados. Asignado a secas, PowerShell lo deja como array.
    $ca = Bajar-Json "$b/cherry-augments.json"
    $listas = Bajar-Json "$b/augment-lists.json"
    $enListas = @{}
    foreach ($l in $listas) { foreach ($x in @($l.augmentList)) { $enListas[($x -split '/')[-1]] = $true } }

    $aum = @{}
    foreach ($a in $ca) {
        if (-not $a.nameTRA) { continue }
        if (-not ($enListas[$a.augmentNameId] -or $a.augmentNameId -like 'ARAM_*')) { continue }
        # El resumen, probando todas las formas de clave que usa el cliente.
        $x = ($a.augmentNameId -replace '^ARAM_', '').ToLowerInvariant()
        $r = $null
        foreach ($k in "kiwi_$($x)_summary", "kiwi_augment_$($x)_summary", "kiwi_aram_$($x)_summary", "cherry_$($x)_summary",
                       "kiwi_$($x)_tooltip", "kiwi_augment_$($x)_tooltip", "cherry_$($x)_tooltip") {
            if ($t[$k]) { $r = $t[$k]; break }
        }
        # Sin etiquetas HTML ni los @Variable@ del motor, que el modelo no sabe leer.
        $limpio = if ($r) { ($r -replace '<br\s*/?>', ' ' -replace '<[^>]+>', '' -replace '@[^@]+@', 'X' -replace '\s+', ' ').Trim() } else { '' }
        if (-not $aum.ContainsKey($a.nameTRA) -or (-not $aum[$a.nameTRA] -and $limpio)) { $aum[$a.nameTRA] = $limpio }
    }
    $aum
}

function Leer-Cache($dir) {
    $leer = { param($f) [IO.File]::ReadAllText((Join-Path $dir $f), [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json }
    @{ parche = (Split-Path $dir -Leaf); items = (& $leer 'items.json'); campeones = (& $leer 'campeones.json'); aumentos = (& $leer 'aumentos.json')
       campeones_n = (& $leer 'campeones-por-numero.json'); aumentos_n = (& $leer 'aumentos-por-numero.json') }
}

# La cache mas reciente en disco, SIN red. Solo si no hay ninguna se baja, que
# pasa una vez en la vida del equipo.
function Get-DDragon {
    $dirs = @(Get-ChildItem $DDragonCache -Directory -EA SilentlyContinue |
              Where-Object { Test-Path (Join-Path $_.FullName $DDragonFormato) } |
              Sort-Object { [version]($_.Name -replace '[^\d.]', '') } -Descending)
    if ($dirs.Count) { return Leer-Cache $dirs[0].FullName }
    Update-DDragon
}

# Con red: el parche actual, y la cache se rehace solo si cambio.
function Update-DDragon {
    $parche = (Invoke-RestMethod 'https://ddragon.leagueoflegends.com/api/versions.json' -TimeoutSec 20)[0]
    $dir = Join-Path $DDragonCache $parche
    if (-not (Test-Path (Join-Path $dir $DDragonFormato))) { $dir = Build-DDragonCache $parche }
    Leer-Cache $dir
}

# Que items encajan con un campeon: su ROL y su tipo de DANO.
#
# Por que las dos cosas. La primera version miraba solo la primera etiqueta
# del campeon y aceptaba cualquier item que compartiera una etiqueta con ella.
# A Lux se le colaron items de tanque ("Llegada del invierno", "Convergencia de
# Zeke") porque llevan `Mana`, que parecia de mago; y antes aun, sin filtro, se
# le propusieron Grebas de metal y el modelo dijo que "mejoran tu dano".
#
# Ahora: un tanque o un soporte compra defensa y utilidad. Cualquier otro -- el
# que tiene que pegar -- necesita su tipo de dano. El del CAMPEON sale de las
# valoraciones de Riot (Katarina, Akali y Diana salen de magia; Ezreal y Kai'Sa,
# de fisico). El del ITEM sale de sus ESTADISTICAS, no de sus etiquetas, porque
# las etiquetas mienten (ver Build-DDragonCache). Es una aproximacion, no una
# build: lo que conviene cada parche es opinion y sale de la web.
$DDRAGON_APOYO = @('Aura', 'Active', 'ManaRegen')

# El campeon del catalogo a partir de lo que trae la API de la partida.
#
# La API real manda `rawChampionName = "game_character_displayname_Sylas"`, no
# "Sylas" (visto en la primera partida real, 2026-09-22): con el id a secas el
# perfil salia vacio y el filtro de clase se desactivaba sin avisar. Se quita el
# prefijo, y si aun asi no esta, se busca por el nombre visible.
function Get-DDragonCampeon($cat, $raw, $nombre = $null) {
    $id = "$raw" -replace '^game_character_displayname_', ''
    $c = $cat.campeones.$id
    if (-not $c -and $nombre) {
        $c = ($cat.campeones.PSObject.Properties | Where-Object { $_.Value.nombre -eq $nombre } | Select-Object -First 1).Value
    }
    $c
}

function Get-DDragonPerfil($cat, $campeonId, $nombre = $null) {
    $c = Get-DDragonCampeon $cat $campeonId $nombre
    if (-not $c) { return $null }
    @{
        rol  = @($c.tags)[0]
        dano = if ($c.magia -gt $c.ataque) { 'AP' } else { 'AD' }
    }
}

function Test-DDragonEncaja($item, $perfil) {
    if (-not $perfil) { return $true }
    if ($perfil.rol -in 'Tank', 'Support') {
        return $item.defensa -or [bool](@($item.tags) | Where-Object { $DDRAGON_APOYO -contains $_ })
    }
    if ($perfil.dano -eq 'AP') { return $item.ap }
    # Un tirador AD vive de critico y velocidad de ataque; sin esto a Jinx le
    # salian Hidra titanica y Baile de la muerte, que son de luchador.
    if ($perfil.rol -eq 'Marksman') { return $item.tirador }
    $item.ad
}

# Items COMPLETOS (no suben a nada) que me puedo permitir y que encajan con mi
# clase. `$yaLlevo` son itemIDs, para no proponer lo que ya tienes.
function Get-DDragonAsequibles($cat, $oro, $yaLlevo = @(), $clase = $null, $cuantos = 6, $mapa = '11') {
    $r = foreach ($p in $cat.items.PSObject.Properties) {
        $i = $p.Value
        if (-not $i.comprable) { continue }
        if (@($i.mapas) -notcontains "$mapa") { continue }
        # Completo = no sube a nada Y TIENE RECETA. Sin lo segundo se colaban
        # los items de inicio (Espada del guardian), consumibles y abalorios,
        # que tampoco suben a nada.
        if (@($i.sube_a | Where-Object { $_ }).Count) { continue }
        if (-not @($i.de | Where-Object { $_ }).Count) { continue }
        if ($i.total -le 0 -or $i.total -gt $oro) { continue }
        if ($yaLlevo -contains $p.Name) { continue }
        if (-not (Test-DDragonEncaja $i $clase)) { continue }
        [pscustomobject]@{ id = $p.Name; nombre = $i.nombre; precio = $i.total }
    }
    # Sin duplicados: Data Dragon tiene varios IDs con el MISMO nombre, y salia
    # "Mandato imperial" dos veces. Y con desempate por nombre, para que 5.1 y 7
    # den la misma lista: el orden de las propiedades del JSON no es el mismo.
    @($r | Sort-Object @{ e = 'precio'; Descending = $true }, nombre |
        Group-Object nombre | ForEach-Object { $_.Group[0] } |
        Sort-Object @{ e = 'precio'; Descending = $true }, nombre |
        Select-Object -First $cuantos)
}

# Que item TERMINO con las piezas que ya llevo.
#
# Es la pregunta util a mitad de partida -- "vuelvo a base, que me hago?" -- y
# se contesta exacto: lo que falta es el precio total menos el de las piezas
# que ya tienes y que forman parte de la receta. Cada pieza cuenta una vez: si
# la receta pide dos Varas y llevas una, solo se descuenta una.
function Get-DDragonCompletables($cat, $misIds, $oro, $clase = $null, $mapa = '11') {
    $candidatos = @{}
    foreach ($id in $misIds) {
        foreach ($destino in @($cat.items.$id.sube_a)) { if ($destino) { $candidatos[$destino] = $true } }
    }
    $r = foreach ($dest in $candidatos.Keys) {
        $d = $cat.items.$dest
        if (-not $d -or -not $d.comprable) { continue }
        if (@($d.mapas) -notcontains "$mapa") { continue }
        if (-not (Test-DDragonEncaja $d $clase)) { continue }
        $bolsa = [Collections.Generic.List[string]]@($misIds)
        $descuento = 0
        foreach ($pieza in @($d.de)) {
            if ($bolsa.Remove([string]$pieza)) { $descuento += [int]$cat.items.$pieza.total }
        }
        $falta = $d.total - $descuento
        [pscustomobject]@{ id = $dest; nombre = $d.nombre; falta = $falta; me_llega = ($falta -le $oro) }
    }
    @($r | Sort-Object @{ e = 'me_llega'; Descending = $true }, falta)
}

# Items que dan la defensa que pide el dano rival ('rm' o 'armadura') y que te
# llegan con el oro que tienes. Primero los completos; si no llega para
# ninguno, las piezas.
#
# POR QUE: a "que me hago contra un Jax AP?" el modelo invento un item. Con la
# composicion rival resumida por tipo de dano y esta lista, tiene algo real que
# nombrar: dato, no opinion.
function Get-DDragonDefensa($cat, $oro, $tipo, $yaLlevo = @(), $mapa = '11', $cuantos = 4) {
    $r = foreach ($p in $cat.items.PSObject.Properties) {
        $i = $p.Value
        if (-not $i.comprable -or -not $i.$tipo) { continue }
        if (@($i.mapas) -notcontains "$mapa") { continue }
        if ($i.total -le 0 -or $i.total -gt $oro) { continue }
        if ($yaLlevo -contains $p.Name) { continue }
        $completo = -not @($i.sube_a | Where-Object { $_ }).Count
        # Sin receta y sin nada a lo que subir: consumible, abalorio o de inicio.
        if ($completo -and -not @($i.de | Where-Object { $_ }).Count) { continue }
        [pscustomobject]@{ nombre = $i.nombre; precio = $i.total; completo = $completo }
    }
    @($r | Sort-Object @{ e = 'completo'; Descending = $true }, @{ e = 'precio'; Descending = $true }, nombre |
        Group-Object nombre | ForEach-Object { $_.Group[0] } | Select-Object -First $cuantos)
}

function Normalizar-Texto($s) {
    $n = "$s".ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    (-join ($n.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })) -replace '[^a-z0-9 ]', ' '
}

# Clave de COMO SUENA en espanol, sin espacios.
#
# El reconocimiento de voz escribio "Jax AP" como "Jacksa P". Letra a letra se
# parecen poco (distancia 3), pero suenan igual: con x->ks, ck/c/qu->k, z->s,
# v->b, sin h y sin espacios, las dos dan "jaksap". Asi se reconoce un campeon
# dicho de viva voz sin inventar una correccion.
function Clave-Fonetica($s) {
    $t = (Normalizar-Texto $s) -replace '\s+', ''
    $t = $t -replace 'ck', 'k' -replace 'qu', 'k' -replace 'c(?=[aou])', 'k' -replace 'c(?=[ei])', 's'
    $t = $t -replace 'x', 'ks' -replace 'z', 's' -replace 'v', 'b' -replace 'h', '' -replace 'll', 'y' -replace 'w', 'u'
    $t -replace '(.)\1+', '$1'      # letras dobles, una
}

# Levenshtein con dos filas (una matriz de dos dimensiones dentro de una
# llamada a metodo no la parsea PowerShell 5.1).
function Distancia([string]$a, [string]$b) {
    $prev = 0..$b.Length
    for ($i = 1; $i -le $a.Length; $i++) {
        $cur = @($i) + @(0) * $b.Length
        for ($j = 1; $j -le $b.Length; $j++) {
            $coste = if ($a[$i - 1] -eq $b[$j - 1]) { 0 } else { 1 }
            $cur[$j] = [math]::Min([math]::Min($prev[$j] + 1, $cur[$j - 1] + 1), $prev[$j - 1] + $coste)
        }
        $prev = $cur
    }
    $prev[$b.Length]
}

# Los aumentos que la pregunta menciona, con lo que hacen.
#
# La pregunta llega del reconocimiento de voz, asi que se compara sin tildes ni
# mayusculas, y un nombre de UNA palabra se acepta a un error de distancia
# ("locomotor" -> Locomotora). Solo nombres de 5 letras o mas: con los cortos el
# margen de error convertiria palabras normales en aumentos.
function Buscar-Aumentos($cat, $texto) {
    if (-not $cat.aumentos) { return @() }
    $t = Normalizar-Texto $texto
    $palabras = @($t -split '\s+' | Where-Object { $_.Length -ge 5 })
    foreach ($p in $cat.aumentos.PSObject.Properties) {
        $n = (Normalizar-Texto $p.Name).Trim()
        if ($n.Length -lt 5) { continue }
        $hit = $t.Contains($n)
        if (-not $hit -and $n -notmatch ' ') { $hit = [bool]($palabras | Where-Object { (Distancia $_ $n) -le 1 }) }
        if ($hit) { "$($p.Name): $($p.Value)" }
    }
}

# Cargado con punto: solo las funciones.
if ($MyInvocation.InvocationName -eq '.') { return }

$c = if ($args -contains '-Refrescar') { Update-DDragon } else { Get-DDragon }
"parche $($c.parche): $(@($c.items.PSObject.Properties).Count) items, $(@($c.campeones.PSObject.Properties).Count) campeones, $(@($c.aumentos.PSObject.Properties).Count) aumentos de Mayhem"
