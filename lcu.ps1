#Requires -Version 5.1
<#
La ULTIMA PARTIDA terminada, leida del cliente de League, para las preguntas de
despues ("como me fue?", "que aumentos cogi?", "quien hizo mas dano?").

POR QUE EL CLIENTE: la API de la partida (puerto 2999, ver lol.ps1) se cierra
al acabar. El cliente (LCU) se queda abierto y guarda el historial, con TODO:
resultado, KDA, dano, oro, items y -- lo que la API de la partida no da -- los
AUMENTOS de cada jugador (`playerAugment1..6`). Comprobado el 2026-09-22 con
una partida real de ARAM Mayhem.

Riot no da soporte a terceros sobre el LCU, pero es la misma via que usan
Blitz o Porofessor: HTTP local, solo lectura, con la contrasena que el propio
cliente deja en su `lockfile`. No se escribe nada, no se toca el juego.

    .\lcu.ps1                  la ultima partida, JSON de una linea (codigo 1 sin cliente)
    .\lcu.ps1 -Legible         lo mismo con sangria
    .\lcu.ps1 -Guardar         guarda la partida cruda en prueba-lol\ (muestra para pruebas)
    .\lcu.ps1 -Prueba          comprobaciones contra la muestra guardada
    . .\lcu.ps1                (con punto) solo las funciones; lo usa ojo.ps1

Sin bloque param(), como lol.ps1 y ddragon.ps1.
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lol.ps1"

# Puerto y contrasena del cliente. Cambian en cada arranque, asi que se leen
# siempre.
#
# NO por la ruta del proceso: el cliente de Riot corre con permisos que no
# dejan leer su `Path` desde aqui (sale vacio, comprobado). Si se lee la linea
# de comandos de LeagueClientUx, que lleva `--app-port` y
# `--remoting-auth-token`. Si no, el `lockfile` junto a la instalacion que Riot
# apunta en su product_settings.yaml ("nombre:pid:puerto:contrasena:protocolo").
function Get-LcuConexion {
    $ux = Get-CimInstance Win32_Process -Filter "Name='LeagueClientUx.exe'" -EA SilentlyContinue | Select-Object -First 1
    if ($ux.CommandLine -match '--app-port=(\d+)') {
        $puerto = $Matches[1]
        if ($ux.CommandLine -match '--remoting-auth-token=([^"\s]+)') {
            return @{ puerto = $puerto; auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("riot:$($Matches[1])")) }
        }
    }
    $y = 'C:\ProgramData\Riot Games\Metadata\league_of_legends.live\league_of_legends.live.product_settings.yaml'
    if (-not (Test-Path $y)) { return $null }
    $dir = ((Select-String -Path $y -Pattern 'product_install_full_path:\s*"?([^"]+)"?').Matches[0].Groups[1].Value) -replace '/', '\'
    $lf = Join-Path $dir 'lockfile'
    if (-not (Test-Path $lf)) { return $null }
    $c = (Get-Content $lf -Raw).Trim().Split(':')
    @{ puerto = $c[2]; auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("riot:$($c[3])")) }
}

# curl.exe -k, por lo mismo que en lol.ps1: certificado autofirmado, y un
# callback de certificados en 5.1 rompe todo el HTTPS del proceso. A archivo y
# leido como UTF-8, para no depender de la pagina de codigos de la consola.
function Invoke-Lcu($con, $ruta) {
    $tmp = Join-Path $env:TEMP 'ojo-lcu.json'
    & curl.exe -sk --max-time 5 -H "Authorization: Basic $($con.auth)" -o $tmp "https://127.0.0.1:$($con.puerto)$ruta" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmp)) { return $null }
    try { [IO.File]::ReadAllText($tmp, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json }
    catch { $null }
    finally { Remove-Item $tmp -EA SilentlyContinue }
}

# La partida entera (los diez jugadores) y quien soy. El historial "de mi
# invocador" trae solo mi fila; la partida completa esta en /games/{id}.
function Get-LcuUltimaPartida {
    $con = Get-LcuConexion
    if (-not $con) { return $null }
    $yo = Invoke-Lcu $con '/lol-summoner/v1/current-summoner'
    $h = Invoke-Lcu $con '/lol-match-history/v1/products/lol/current-summoner/matches?begIndex=0&endIndex=1'
    $id = @($h.games.games)[0].gameId
    if (-not $id -or -not $yo.puuid) { return $null }
    $juego = Invoke-Lcu $con "/lol-match-history/v1/games/$id"
    if (-not $juego) { return $null }
    @{ juego = $juego; puuid = $yo.puuid }
}

function Resumir-UltimaPartida($datos, $cat) {
    $g = $datos.juego
    $ids = @{}
    foreach ($i in @($g.participantIdentities)) { $ids[[string]$i.participantId] = $i.player }
    $mia = @($g.participants) | Where-Object { $ids[[string]$_.participantId].puuid -eq $datos.puuid } | Select-Object -First 1
    if (-not $mia) { return $null }

    $nombreCampeon = { param($n) $x = $cat.campeones_n.([string]$n); if ($x) { $x } else { "campeon $n" } }
    $nombreItem = { param($n) if ($n -and $n -ne 0) { $x = $cat.items.([string]$n).nombre; if ($x) { $x } else { "item $n" } } }
    $aumentos = { param($s) @(1..6 | ForEach-Object { $s."playerAugment$_" } | Where-Object { $_ -and $_ -ne 0 } |
                    ForEach-Object { $x = $cat.aumentos_n.([string]$_); if ($x) { $x } else { "aumento $_" } }) }
    $linea = { param($p) $s = $p.stats
        # Sin separador de miles: "51,425" la voz en espanol lo lee como decimal.
        "{0} {1}/{2}/{3}, {4} de dano a campeones" -f (& $nombreCampeon $p.championId), $s.kills, $s.deaths, $s.assists, [int]$s.totalDamageDealtToChampions }

    $s = $mia.stats
    $seg = [int]$g.gameDuration
    $mios = @($g.participants | Where-Object teamId -eq $mia.teamId)
    $suyos = @($g.participants | Where-Object teamId -ne $mia.teamId)
    # Lo que es aritmetica se calcula aqui, no se le pide al modelo (ver lol.ps1).
    $masDano = { param($eq) $eq | Sort-Object { [int]$_.stats.totalDamageDealtToChampions } -Descending | Select-Object -First 1 | ForEach-Object { & $linea $_ } }

    [ordered]@{
        cuando          = ([DateTimeOffset]::FromUnixTimeMilliseconds($g.gameCreation).LocalDateTime).ToString('dd/MM HH:mm')
        modo            = if ($LOL_MODOS["$($g.gameMode)"]) { $LOL_MODOS["$($g.gameMode)"] } else { "$($g.gameMode)" }
        duracion        = "{0}:{1:00}" -f [math]::Floor($seg / 60), ($seg % 60)
        resultado       = if ($s.win) { 'victoria' } else { 'derrota' }
        mi_campeon      = & $nombreCampeon $mia.championId
        mi_kda          = "$($s.kills)/$($s.deaths)/$($s.assists)"
        mi_dano_a_campeones = [int]$s.totalDamageDealtToChampions
        mi_oro          = [int]$s.goldEarned
        mis_items       = @(0..6 | ForEach-Object { & $nombreItem $s."item$_" } | Where-Object { $_ })
        mis_aumentos    = & $aumentos $s
        mi_equipo       = @($mios | ForEach-Object { & $linea $_ })
        equipo_rival    = @($suyos | ForEach-Object { & $linea $_ })
        mas_dano_mi_equipo = & $masDano $mios
        mas_dano_rival  = & $masDano $suyos
    }
}

# Cargado con punto: solo las funciones.
if ($MyInvocation.InvocationName -eq '.') { return }

$muestra = Join-Path $PSScriptRoot 'prueba-lol\muestra-postpartida.json'
if ($args -contains '-Prueba') {
    # Contra la partida real congelada (ARAM Mayhem, 2026-09-22). Lo esperado
    # esta escrito a mano mirando el cliente: Sylas, y estos cuatro aumentos.
    $cat = Get-DDragon
    $datos = [IO.File]::ReadAllText($muestra, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    $h = Resumir-UltimaPartida $datos $cat
    $fallos = @()
    if ($h.mi_campeon -ne 'Sylas') { $fallos += "mi_campeon = '$($h.mi_campeon)'" }
    if ($h.modo -ne 'ARAM Mayhem (con aumentos)') { $fallos += "modo = '$($h.modo)'" }
    foreach ($a in 'Ratón de los Dientes', 'De Principio a Fin', 'Científico Loco', 'Archimago') {
        if (@($h.mis_aumentos) -notcontains $a) { $fallos += "falta el aumento '$a' en: $($h.mis_aumentos -join ', ')" }
    }
    if (@($h.mi_equipo).Count -ne 5 -or @($h.equipo_rival).Count -ne 5) { $fallos += "equipos: $(@($h.mi_equipo).Count) y $(@($h.equipo_rival).Count)" }
    if (@($h.mis_items | Where-Object { $_ -like 'item *' }).Count) { $fallos += "items sin nombre: $($h.mis_items -join ', ')" }
    $h | ConvertTo-Json -Depth 5 | Write-Host
    if ($fallos) { Write-Host "`nFALLA:`n  $($fallos -join "`n  ")" -ForegroundColor Red; exit 2 }
    Write-Host "`n$(8 + 1) comprobaciones OK" -ForegroundColor Green
    exit 0
}

$datos = Get-LcuUltimaPartida
if (-not $datos) { exit 1 }
if ($args -contains '-Guardar') {
    [IO.File]::WriteAllText($muestra, ($datos | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    "muestra guardada: $muestra"
    exit 0
}
$h = Resumir-UltimaPartida $datos (Get-DDragon)
if ($args -contains '-Legible') { $h | ConvertTo-Json -Depth 5 } else { $h | ConvertTo-Json -Depth 5 -Compress }
