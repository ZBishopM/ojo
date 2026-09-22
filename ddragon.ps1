#Requires -Version 5.1
<#
El catalogo de items de League, cacheado en disco.

QUE ES: Data Dragon, el CDN publico de Riot. Sin clave, sin limite de peticiones
documentado, y en espanol:

    https://ddragon.leagueoflegends.com/api/versions.json
    https://ddragon.leagueoflegends.com/cdn/<version>/data/es_ES/item.json

POR QUE SE CACHEA: solo cambia cuando hay parche. Bajarlo en cada pregunta
seria pagar la red por un dato que lleva dos semanas igual, y la propia
documentacion de Riot pide cachearlo.

QUE **NO** ESTA AQUI, y conviene saberlo antes de buscarlo: la build
recomendada. El campo `recommended` de cada campeon viene **vacio** -- Riot dejo
de publicarlo (comprobado el 2026-09-22 con Lux en el parche 16.18.1). Lo que
se arma cada parche es opinion y cambia, y eso solo sale de la web.

Lo que si responde este catalogo:
  - cuanto cuesta un item, y cuanto queda para completarlo
  - de que piezas se hace y en que se convierte
  - que puedo permitirme con el oro que llevo

    .\ddragon.ps1                 asegura la cache y dice que hay
    .\ddragon.ps1 -Refrescar      la rehace aunque el parche no haya cambiado
    .\ddragon.ps1 -ComoModulo     no hace nada al cargarse; expone las funciones
#>
param(
    [switch]$Refrescar,
    [switch]$ComoModulo,
    [string]$Raiz = 'D:\2026-projects\ojo',
    [string]$Idioma = 'es_ES'
)
$ErrorActionPreference = 'Stop'

$DDragonCache = Join-Path $Raiz 'ddragon'

function Get-DDragonParche {
    (Invoke-RestMethod 'https://ddragon.leagueoflegends.com/api/versions.json' -TimeoutSec 20)[0]
}

# Se guarda RECORTADO, no el archivo entero.
#
# item.json pesa ~1 MB y trae descripciones en HTML, rutas de icono y bloques de
# estadisticas que aqui no sirven para nada. Lo que hace falta cabe en una
# decima parte, y lo que no se guarda no hay que filtrarlo en cada consulta.
#
# Solo el mapa 11 (la Grieta del Invocador): los items de ARAM y Arena
# confundirian una respuesta sobre una partida normal.
function Build-DDragonCache($parche) {
    $url = "https://ddragon.leagueoflegends.com/cdn/$parche/data/$Idioma/item.json"
    # WebClient con UTF-8 EXPLICITO, y no Invoke-RestMethod.
    #
    # En PowerShell 5.1, Invoke-RestMethod decodifica el cuerpo con el charset
    # de la cabecera Content-Type, y si no viene -- que es el caso de este CDN
    # -- cae en ISO-8859-1. Resultado: "Espada del guardian" salia como
    # "Espada del guardiAn" y asi se guardaba en la cache. El catalogo esta en
    # espanol, o sea que esto toca a la mitad de los nombres.
    #
    # Esto funciona igual en 5.1 y en 7, que es lo que hace falta: `ojo.ps1`
    # corre en 5.1 y el resto del rice en 7.
    $wc = New-Object Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    try { $crudo = $wc.DownloadString($url) | ConvertFrom-Json } finally { $wc.Dispose() }

    $items = @{}
    foreach ($p in $crudo.data.PSObject.Properties) {
        $i = $p.Value
        if (-not $i.maps.'11') { continue }
        $items[$p.Name] = [ordered]@{
            nombre     = $i.name
            total      = [int]$i.gold.total
            base       = [int]$i.gold.base
            comprable  = [bool]$i.gold.purchasable
            tags       = @($i.tags   | Where-Object { $_ })
            # `| Where-Object { $_ }` Y NO `@($i.into)` a secas.
            #
            # En PowerShell `@($null)` NO es un array vacio: es un array de UN
            # elemento nulo, con Count = 1. Un item sin `into` -- o sea, un item
            # COMPLETO, que es justo el que queremos proponer -- pasaba a
            # parecer que sube a algo, y el filtro los descartaba todos. La
            # lista de asequibles salia vacia siempre.
            de         = @($i.from   | Where-Object { $_ })   # las piezas que lo forman
            sube_a     = @($i.into   | Where-Object { $_ })   # en que se convierte
        }
    }

    $destino = Join-Path $DDragonCache $parche
    New-Item -ItemType Directory -Force -Path $destino | Out-Null
    $salida = Join-Path $destino 'items.json'
    [IO.File]::WriteAllText($salida,
        ($items | ConvertTo-Json -Depth 6 -Compress),
        [Text.UTF8Encoding]::new($false))
    $salida
}

function Get-DDragonItems {
    param([switch]$Forzar)
    $parche = Get-DDragonParche
    $ruta = Join-Path (Join-Path $DDragonCache $parche) 'items.json'
    if ($Forzar -or -not (Test-Path $ruta)) { $ruta = Build-DDragonCache $parche }
    $obj = [IO.File]::ReadAllText($ruta, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    @{ parche = $parche; ruta = $ruta; items = $obj }
}

# Que items COMPLETOS me puedo permitir ahora mismo.
#
# "Completo" = no sube a nada (`sube_a` vacio). Sin ese filtro la lista se llena
# de componentes de 400 de oro y no dice nada util: nadie pregunta si puede
# permitirse una capa de nulidad.
#
# `$yaLlevo` son los NOMBRES de los items que ya tienes, para no proponerte lo
# que ya tienes puesto.
function Get-DDragonAsequibles($items, $oro, $yaLlevo = @(), $cuantos = 8) {
    $r = foreach ($p in $items.PSObject.Properties) {
        $i = $p.Value
        if (-not $i.comprable) { continue }
        # El mismo cuidado con los nulos que al construir la cache: despues de
        # pasar por JSON un array vacio puede volver como un nulo suelto.
        if (@($i.sube_a | Where-Object { $_ }).Count) { continue }
        if ($i.total -le 0 -or $i.total -gt $oro) { continue }
        if ($yaLlevo -contains $i.nombre) { continue }
        [pscustomobject]@{ nombre = $i.nombre; precio = $i.total; tags = ($i.tags -join ',') }
    }
    @($r | Sort-Object precio -Descending | Select-Object -First $cuantos)
}

if ($ComoModulo) { return }

$c = Get-DDragonItems -Forzar:$Refrescar
$n = @($c.items.PSObject.Properties).Count
"parche $($c.parche): $n items de la Grieta en cache"
"   $($c.ruta)  ($([int]((Get-Item $c.ruta).Length/1KB)) KB)"
