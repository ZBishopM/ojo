#Requires -Version 5.1
<#
Los hechos de la partida de League of Legends, en un JSON pequeno para el
prompt.

POR QUE ESTO EXISTE, Y POR QUE NO SE MIRA LA PANTALLA:

El juego sirve sus propios datos en local. Es la Live Client Data API, puerto
2999, documentada por Riot en developer.riotgames.com/docs/lol y SIN CLAVE:

    GET https://127.0.0.1:2999/liveclientdata/allgamedata

Ahi estan, exactos: tu campeon, tus items con nombre y precio, tu oro, las dos
composiciones, el marcador y el minuto. Leerlo cuesta milisegundos y no se
equivoca.

La alternativa era capturar la pantalla y preguntarle al modelo de vision que
ve. Eso es mas lento, gasta el mmproj (1,08 GB de VRAM que durante la partida
no sobran) y da respuestas que PARECEN seguras y no lo son. Aqui el dato lo
declara el juego.

Tampoco se lee memoria del juego ni se inyecta nada: es una peticion HTTP a un
puerto que el propio cliente abre. Es lo mismo que hacen Blitz y Porofessor.

    .\lol.ps1              los hechos, como JSON de una linea
    .\lol.ps1 -Legible     lo mismo con sangria, para leerlo tu
    .\lol.ps1 -Crudo       la respuesta entera de la API, sin resumir

Si no hay partida sale codigo 1 y no imprime nada: asi `ojo.ps1` puede
preguntar "hay partida?" sin tratarlo como un error.
#>
param(
    [switch]$Legible,
    [switch]$Crudo,
    # Pasa por el mismo resumen una partida inventada, con las diez plazas y
    # con items. Es la unica forma de comprobar esto sin estar jugando, y hace
    # falta: los campos que mas se tuercen -- el reparto por equipo y el minuto
    # -- no se ven con la respuesta de ejemplo de Riot, que es de nivel 1 y con
    # el inventario vacio.
    [switch]$Prueba,
    [int]$Puerto = 2999,
    [int]$TimeoutSeg = 3
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# El cliente del juego usa un certificado AUTOFIRMADO. Riot lo dice en su propia
# documentacion y ofrece dos salidas: ignorar el error o instalar su raiz.
# Aqui se ignora, porque el destino es 127.0.0.1 y el proceso es el juego.
#
# Hacen falta las DOS ramas: `-SkipCertificateCheck` existe desde PowerShell 6,
# y `ojo.ps1` corre en 5.1 (lo lanza `powershell`, no `pwsh`). En 5.1 hay que
# tocar ServicePointManager, y eso es GLOBAL AL PROCESO.
#
# Y ahi esta la trampa, que me comi entera: la primera version devolvia
# `r.RequestUri.IsLoopback` a secas, con un comentario mio que decia "da igual,
# este proceso no habla con nadie mas". Dejo de ser verdad en cuanto anadi el
# catalogo de Data Dragon: la politica rechazaba ddragon.leagueoflegends.com
# con "No se puede establecer una relacion de confianza para el canal seguro
# SSL/TLS", y el catalogo salia vacio sin decir por que.
#
# Ahora: loopback pasa siempre -- ahi vive el certificado autofirmado del juego
# --, y CUALQUIER OTRO destino se valida como siempre. `p` es el codigo de
# problema que ya calculo la plataforma: 0 es "ningun problema".
$esPS7 = $PSVersionTable.PSVersion.Major -ge 6
if (-not $esPS7) {
    Add-Type -TypeDefinition @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class SoloLocalhost : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate c, WebRequest r, int p) {
        if (r.RequestUri.IsLoopback) return true;   // el cliente del juego
        return p == 0;                              // el resto, validacion normal
    }
}
'@ -ErrorAction SilentlyContinue
    [Net.ServicePointManager]::CertificatePolicy = New-Object SoloLocalhost
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

function Pedir($ruta) {
    $url = "https://127.0.0.1:$Puerto/liveclientdata/$ruta"
    $args = @{ Uri = $url; TimeoutSec = $TimeoutSeg; UseBasicParsing = $true }
    if ($esPS7) { $args['SkipCertificateCheck'] = $true }
    Invoke-RestMethod @args
}

function Partida-Inventada {
    $eq = @()
    $campeones = @('Annie','Garen','Lux','Jinx','Thresh','Ahri','Darius','Yasuo','Caitlyn','Leona')
    for ($i = 0; $i -lt 10; $i++) {
        $eq += [pscustomobject]@{
            summonerName = "jug$i"
            championName = $campeones[$i]
            level        = 9 + $i % 3
            team         = if ($i -lt 5) { 'ORDER' } else { 'CHAOS' }
            position     = @('TOP','JUNGLE','MIDDLE','BOTTOM','UTILITY')[$i % 5]
            items        = if ($i -eq 2) {
                @([pscustomobject]@{ displayName = 'Sombrero Mortal de Rabadon'; price = 3600 },
                  [pscustomobject]@{ displayName = 'Botas de Hechicero';        price = 1100 })
            } else { @() }
            scores       = [pscustomobject]@{ kills = $i; deaths = 1; assists = 2; creepScore = 100 + $i }
        }
    }
    [pscustomobject]@{
        activePlayer = [pscustomobject]@{ summonerName = 'jug2'; level = 11; currentGold = 1543.7 }
        allPlayers   = $eq
        gameData     = [pscustomobject]@{ gameMode = 'CLASSIC'; gameTime = 754.0 }
    }
}

if ($Prueba) {
    $d = Partida-Inventada
} else {
    try {
        $d = Pedir 'allgamedata'
    } catch {
        # No hay partida, o el juego aun no ha abierto el puerto. No es un fallo.
        exit 1
    }
}

if ($Crudo) {
    $d | ConvertTo-Json -Depth 12
    exit 0
}

# --- Resumen ---
#
# NOMBRES, NO IDs. El modelo no tiene por que saber que el 3153 es Cuchilla del
# Rey Arruinado, y meterle numeros crudos es pedirle que invente. La API ya trae
# `displayName` y `price` en cada item, asi que Data Dragon no hace falta para
# esto -- solo haria falta para el CATALOGO de lo que se puede comprar, que es
# otra pregunta y otro dia.
$yo = $d.activePlayer
$miNombre = $yo.summonerName

function Resumir-Jugador($p) {
    $items = @($p.items | ForEach-Object { $_.displayName }) -join ', '
    [ordered]@{
        campeon  = $p.championName
        puesto   = if ($p.position) { $p.position } else { '' }
        nivel    = $p.level
        kda      = "{0}/{1}/{2}" -f $p.scores.kills, $p.scores.deaths, $p.scores.assists
        cs       = $p.scores.creepScore
        items    = $items
        soy_yo   = ($p.summonerName -eq $miNombre)
    }
}

# ORDER y CHAOS son los nombres internos de los dos equipos (azul y rojo). Se
# reparte por el mio, no por el color, porque "nuestro equipo" es lo que se
# pregunta.
$miEquipo = (@($d.allPlayers) | Where-Object { $_.summonerName -eq $miNombre }).team
$nuestros = @($d.allPlayers | Where-Object { $_.team -eq $miEquipo })
$suyos    = @($d.allPlayers | Where-Object { $_.team -ne $miEquipo })

# [math]::Floor Y NO [int], en los dos.
#
# El cast a [int] de PowerShell REDONDEA (redondeo bancario), no trunca. La
# prueba lo caza: 754 segundos son el minuto 12:34, y con [int] salia 13:34
# porque 754/60 = 12,57 y eso redondea a 13. Un minuto de mas en cada consulta.
#
# Con el oro es peor que feo: 1543,7 se convertia en 1544, y con eso el modelo
# diria que te llega para algo que cuesta 1544 y no te llega.
$seg = [int][math]::Floor([double]$d.gameData.gameTime)
$hechos = [ordered]@{
    modo         = $d.gameData.gameMode
    minuto       = "{0}:{1:00}" -f [math]::Floor($seg / 60), ($seg % 60)
    mi_campeon   = (@($d.allPlayers | Where-Object { $_.summonerName -eq $miNombre }).championName)
    mi_oro       = [int][math]::Floor([double]$yo.currentGold)
    mi_nivel     = $yo.level
    mi_equipo    = @($nuestros | ForEach-Object { Resumir-Jugador $_ })
    equipo_rival = @($suyos    | ForEach-Object { Resumir-Jugador $_ })
}

# --- Que me puedo permitir ahora mismo ---
#
# Es la mitad de "que items me armo" que SI se puede contestar con datos
# exactos. La otra mitad -- que conviene este parche, contra que campeon -- es
# opinion, cambia cada dos semanas y no esta en Data Dragon: el campo
# `recommended` de cada campeon viene vacio desde que Riot dejo de publicarlo
# (comprobado con Lux en el 16.18.1). Eso necesita web, y no esta hecho.
#
# Se envuelve en try: si no hay red o la cache no esta, los hechos de la
# partida siguen valiendo. Es un extra, no un requisito.
try {
    . "$PSScriptRoot\ddragon.ps1" -ComoModulo
    $cat = Get-DDragonItems
    $mios = @($hechos.mi_equipo | Where-Object { $_.soy_yo }).items -split ',\s*' | Where-Object { $_ }
    $hechos['parche'] = $cat.parche
    $hechos['puedo_comprar'] = @(Get-DDragonAsequibles $cat.items $hechos.mi_oro $mios |
        ForEach-Object { "$($_.nombre) ($($_.precio))" })
} catch {
    # Se dice POR QUE. Un catch mudo aqui convierte "no hay red" y "la cache
    # esta rota" en el mismo silencio, y se tarda media hora en descubrir cual
    # de los dos era.
    $hechos['puedo_comprar'] = @()
    $hechos['catalogo_fallo'] = "$_"
}

if ($Prueba) {
    # Comprobaciones, no adorno: cada una falla si se tuerce el resumen.
    $fallos = @()
    if ($hechos.mi_campeon -ne 'Lux')          { $fallos += "mi_campeon = '$($hechos.mi_campeon)', se esperaba Lux" }
    if ($hechos.minuto     -ne '12:34')        { $fallos += "minuto = '$($hechos.minuto)', se esperaba 12:34" }
    if ($hechos.mi_oro     -ne 1543)           { $fallos += "mi_oro = $($hechos.mi_oro), se esperaba 1543" }
    if ($hechos.mi_equipo.Count    -ne 5)      { $fallos += "mi_equipo tiene $($hechos.mi_equipo.Count), se esperaban 5" }
    if ($hechos.equipo_rival.Count -ne 5)      { $fallos += "equipo_rival tiene $($hechos.equipo_rival.Count), se esperaban 5" }
    # El reparto es por MI equipo, no por el color: jug2 es ORDER, asi que los
    # cinco de ORDER tienen que caer en mi_equipo.
    if (@($hechos.mi_equipo | Where-Object { $_.soy_yo }).Count -ne 1) { $fallos += 'soy_yo no marca exactamente a uno' }
    if ($hechos.mi_equipo[2].items -notmatch 'Rabadon')  { $fallos += "los items no llegan: '$($hechos.mi_equipo[2].items)'" }
    if ($hechos.mi_equipo[2].kda   -ne '2/1/2')          { $fallos += "kda = '$($hechos.mi_equipo[2].kda)', se esperaba 2/1/2" }
    # El catalogo: con 1543 de oro tiene que proponer algo, y nada que cueste
    # mas de lo que llevas ni nada que ya tengas puesto.
    if (-not $hechos.puedo_comprar.Count) { $fallos += 'puedo_comprar vacio: la cache de Data Dragon no cargo' }
    foreach ($s in $hechos.puedo_comprar) {
        if ($s -match '\((\d+)\)$' -and [int]$Matches[1] -gt $hechos.mi_oro) {
            $fallos += "propone '$s' con solo $($hechos.mi_oro) de oro"
        }
        if ($s -match 'Rabadon') { $fallos += "propone '$s', que ya lo lleva puesto" }
    }

    $hechos | ConvertTo-Json -Depth 6
    if ($fallos) { Write-Host "`nFALLA:`n  $($fallos -join "`n  ")" -ForegroundColor Red; exit 2 }
    Write-Host "`n8 comprobaciones OK" -ForegroundColor Green
    exit 0
}

if ($Legible) { $hechos | ConvertTo-Json -Depth 6 }
else          { $hechos | ConvertTo-Json -Depth 6 -Compress }
