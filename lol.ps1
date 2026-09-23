#Requires -Version 5.1
<#
Los hechos de la partida de League of Legends, en un JSON pequeno para el
prompt.

POR QUE NO SE MIRA LA PANTALLA: el juego sirve sus propios datos en local. Es
la Live Client Data API, documentada por Riot (developer.riotgames.com/docs/lol)
y SIN CLAVE:

    GET https://127.0.0.1:2999/liveclientdata/allgamedata

Campeones, items con itemID, oro, las dos composiciones, el marcador, quien esta
muerto y el minuto. Exacto y en milisegundos. Mirar una captura es mas lento,
gasta el mmproj y da respuestas que parecen seguras sin serlo. Tampoco se lee
memoria del juego ni se inyecta nada: es HTTP a un puerto que el propio cliente
abre, lo mismo que hacen Blitz y Porofessor.

    .\lol.ps1              los hechos, JSON de una linea (codigo 1 si no hay partida)
    .\lol.ps1 -Legible     lo mismo con sangria
    .\lol.ps1 -Crudo       la respuesta entera de la API, para guardar muestras
    .\lol.ps1 -Prueba      los casos inventados, con comprobaciones
    . .\lol.ps1            (con punto) solo define las funciones; lo usa ojo.ps1

SIN BLOQUE param(), por lo mismo que ddragon.ps1: un param() se ejecuta en el
ambito de quien carga el archivo con punto y le pisa las variables. Cuando este
archivo tenia uno, el -ComoModulo de ddragon.ps1 lo apagaba entero en silencio.
#>
$ErrorActionPreference = 'Stop'
$PuertoLol = 2999

. "$PSScriptRoot\ddragon.ps1"

# ---- Hay partida? -----------------------------------------------------------
#
# Un sondeo TCP con tope de 200 ms ANTES de pedir nada. Sin el, cuando el juego
# existe pero aun no ha abierto el puerto (pantalla de carga) Windows tarda ~2 s
# en rechazar la conexion a un puerto local cerrado: medido, 2.437 ms. Esos 2 s
# se pagaban en cada pregunta.
function Test-LolPuerto([int]$ms = 200) {
    $c = New-Object Net.Sockets.TcpClient
    try { $c.ConnectAsync('127.0.0.1', $PuertoLol).Wait($ms) -and $c.Connected }
    catch { $false }
    finally { $c.Dispose() }
}

# El certificado del juego es AUTOFIRMADO; Riot dice que se ignore o se use su
# raiz. Se pide con `curl.exe -k`, que viene con Windows.
#
# POR QUE curl Y NO Invoke-RestMethod, y esto costo dos intentos:
#
#  1. Una clase C# con Add-Type como politica de certificados. Funciona, pero
#     compilar son 202 ms (medido) y la politica es GLOBAL al proceso: la
#     primera version solo aceptaba loopback y tumbo la descarga de Data Dragon.
#  2. Un scriptblock como callback, para no compilar. NO FUNCIONA: .NET lo
#     invoca en otro hilo, sin runspace, y revienta CUALQUIER conexion HTTPS
#     nueva del proceso ("No hay ningun espacio de ejecucion disponible"). La
#     prueba que parecia decir que si reutilizaba una conexion ya abierta.
#
# curl.exe: 22 ms, y no toca el estado del proceso. Se escribe a un archivo y
# se lee como UTF-8, para no depender de la pagina de codigos de la consola.
function Get-LolDatos {
    if (-not (Test-LolPuerto)) { return $null }
    $tmp = Join-Path $env:TEMP 'ojo-lol.json'
    & curl.exe -sk --max-time 3 -o $tmp "https://127.0.0.1:$PuertoLol/liveclientdata/allgamedata" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmp)) { return $null }
    try { [IO.File]::ReadAllText($tmp, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json }
    catch { $null }
    finally { Remove-Item $tmp -EA SilentlyContinue }
}

# ---- Quien soy ----------------------------------------------------------------
#
# Por NOMBRE SIN #TAG, probando todos los campos que Riot ha usado.
#
# La primera version comparaba `summonerName` con `-eq`. Riot migro a Riot ID y
# hay un fallo abierto (RiotGames/developer-relations #857) donde un endpoint
# devuelve "Nombre#TAG" y otro solo "Nombre". Con `-eq`, nadie era "yo", y los
# diez jugadores caian en el equipo rival SIN NINGUN AVISO.
function Nombres-De($o) {
    @($o.riotId, $o.riotIdGameName, $o.summonerName) | Where-Object { $_ } |
        ForEach-Object { ("$_" -split '#')[0].Trim().ToLowerInvariant() } | Select-Object -Unique
}

function Buscar-Yo($d) {
    $mios = @(Nombres-De $d.activePlayer)
    $hits = @($d.allPlayers | Where-Object { @(Nombres-De $_ | Where-Object { $mios -contains $_ }).Count })
    # Exactamente uno, o nada. Adivinar entre dos seria repartir mal los
    # equipos con cara de dato exacto.
    if ($hits.Count -eq 1) { $hits[0] } else { $null }
}

# ---- Resumen para el prompt ----------------------------------------------------
#
# NOMBRES, no IDs, salvo donde el ID hace falta para cruzar con el catalogo.
function Resumir-Jugador($p, $yo) {
    [ordered]@{
        campeon = $p.championName
        puesto  = "$($p.position)"
        nivel   = $p.level
        kda     = "{0}/{1}/{2}" -f $p.scores.kills, $p.scores.deaths, $p.scores.assists
        cs      = $p.scores.creepScore
        items   = (@($p.items | ForEach-Object { $_.displayName }) -join ', ')
        muerto  = if ($p.isDead) { "revive en $([int][math]::Ceiling([double]$p.respawnTimer)) s" } else { '' }
        soy_yo  = [bool]($yo -and [object]::ReferenceEquals($p, $yo))
    }
}

# Nombre legible del modo. La API da el interno: en la primera partida real
# llego "KIWI", que es ARAM Mayhem (el de los aumentos).
$LOL_MODOS = @{
    CLASSIC = 'Grieta del Invocador'; ARAM = 'ARAM'; KIWI = 'ARAM Mayhem (con aumentos)'
    CHERRY = 'Arena'; URF = 'URF'; ARURF = 'URF aleatorio'; ONEFORALL = 'Uno para todos'
}

function Resumir-Partida($d, $cat, $pregunta = $null) {
    $yo = Buscar-Yo $d
    # [math]::Floor Y NO [int]: el cast de PowerShell REDONDEA. 754 s salian
    # como el minuto 13:34, y 1543,7 de oro como 1544 -- el modelo diria que te
    # llega para algo que cuesta 1544 y no te llega.
    $seg = [int][math]::Floor([double]$d.gameData.gameTime)
    $modo = "$($d.gameData.gameMode)"
    # El mapa decide que items existen: el 11 es la Grieta, el 12 el Abismo.
    $mapa = if ($d.gameData.mapNumber) { "$($d.gameData.mapNumber)" } else { '11' }
    $h = [ordered]@{
        modo   = if ($LOL_MODOS[$modo]) { $LOL_MODOS[$modo] } else { $modo }
        minuto = "{0}:{1:00}" -f [math]::Floor($seg / 60), ($seg % 60)
        mi_oro = [int][math]::Floor([double]$d.activePlayer.currentGold)
    }
    if (-not $yo) {
        # Sin identidad no hay "mi equipo": se dan los dos por su color y se
        # dice por que, en vez de inventar el reparto.
        $h['identidad'] = 'no pude saber cual de los diez eres; los equipos van por color'
        $h['equipo_azul'] = @($d.allPlayers | Where-Object team -eq 'ORDER' | ForEach-Object { Resumir-Jugador $_ $null })
        $h['equipo_rojo'] = @($d.allPlayers | Where-Object team -ne 'ORDER' | ForEach-Object { Resumir-Jugador $_ $null })
        return $h
    }
    $h['mi_campeon']   = $yo.championName
    $h['mi_nivel']     = $yo.level
    $h['mi_equipo']    = @($d.allPlayers | Where-Object team -eq $yo.team | ForEach-Object { Resumir-Jugador $_ $yo })
    $h['equipo_rival'] = @($d.allPlayers | Where-Object team -ne $yo.team | ForEach-Object { Resumir-Jugador $_ $null })
    # Quien va mas fuerte, CALCULADO aqui y no pedido al modelo. Medido: con los
    # cinco KDA delante, el 8B dijo Yasuo (7/1/2) teniendo a Leona (9/1/2).
    # Sacar el maximo de cinco numeros es justo lo que un modelo pequeno hace
    # mal y un ordenador hace perfecto. Criterio: (asesinatos + asistencias) /
    # muertes, el KDA de siempre, con las muertes a 1 como minimo.
    $fuerte = { param($eq) $eq | Sort-Object { ($_.scores.kills + $_.scores.assists) / [math]::Max(1, $_.scores.deaths) } -Descending |
                Select-Object -First 1 | ForEach-Object { "$($_.championName) ($($_.scores.kills)/$($_.scores.deaths)/$($_.scores.assists))" } }
    $h['mas_fuerte_mi_equipo'] = & $fuerte @($d.allPlayers | Where-Object team -eq $yo.team)
    $h['mas_fuerte_rival']     = & $fuerte @($d.allPlayers | Where-Object team -ne $yo.team)

    # El catalogo es un extra: sin el, los hechos de la partida siguen valiendo.
    if ($cat) {
        $perfil = Get-DDragonPerfil $cat $yo.rawChampionName $yo.championName
        $misIds = @($yo.items | ForEach-Object { [string]$_.itemID })
        $h['parche'] = $cat.parche
        $h['mi_perfil'] = if ($perfil) { "$($perfil.rol), dano $($perfil.dano)" } else { $null }
        $h['puedo_completar'] = @(Get-DDragonCompletables $cat $misIds $h.mi_oro $perfil $mapa |
            Select-Object -First 4 |
            ForEach-Object { if ($_.me_llega) { "$($_.nombre) (te faltan $($_.falta), te llega)" } else { "$($_.nombre) (te faltan $($_.falta))" } })
        $h['puedo_comprar'] = @(Get-DDragonAsequibles $cat $h.mi_oro $misIds $perfil 6 $mapa |
            ForEach-Object { "$($_.nombre) ($($_.precio))" })

        # QUE DANO HACE EL RIVAL, campeon por campeon, y la defensa que te llega.
        # Es la base de "que me hago contra X": dato, no opinion. El tipo de
        # dano sale de las valoraciones de Riot (magia contra ataque), igual que
        # el tuyo.
        # LO QUE DICE EL USUARIO manda sobre las valoraciones de Riot: "veo un
        # Jax AP" significa que ESE Jax pega magico, aunque Riot diga que Jax es
        # de ataque. Se busca por como suena ("Jacksa P" -> jaksap = Jax AP), solo
        # con los campeones de esta partida y nombres de 3 letras o mas.
        $dicho = @{}
        $mencionados = @()
        if ($pregunta) {
            $clave = Clave-Fonetica $pregunta
            foreach ($p in @($d.allPlayers)) {
                $k = Clave-Fonetica $p.championName
                if ($k.Length -lt 3) { continue }
                if ($clave -match "$([regex]::Escape($k))(ap|ad)") { $dicho[$p.championName] = $Matches[1].ToUpper() }
                if ($k.Length -ge 4 -and $clave.Contains($k)) { $mencionados += $p.championName }
            }
        }
        if ($dicho.Count) { $h['el_usuario_dice'] = @($dicho.Keys | ForEach-Object { "$_ va $($dicho[$_])" }) }
        if ($mencionados.Count) { $h['campeones_mencionados'] = @($mencionados | Select-Object -Unique) }

        $ap = @(); $ad = @()
        foreach ($r in @($d.allPlayers | Where-Object team -ne $yo.team)) {
            $pr = Get-DDragonPerfil $cat $r.rawChampionName $r.championName
            $tipo = if ($dicho[$r.championName]) { $dicho[$r.championName] } else { $pr.dano }
            if ($tipo -eq 'AP') { $ap += $r.championName } else { $ad += $r.championName }
        }
        $h['dano_rival'] = "magico: $($ap.Count) ($($ap -join ', ')); fisico: $($ad.Count) ($($ad -join ', '))"
        $rm = @(Get-DDragonDefensa $cat $h.mi_oro 'rm' $misIds $mapa | ForEach-Object { "$($_.nombre) ($($_.precio))" })
        $ar = @(Get-DDragonDefensa $cat $h.mi_oro 'armadura' $misIds $mapa | ForEach-Object { "$($_.nombre) ($($_.precio))" })
        # Si la pregunta es por UN campeon concreto con su tipo de dano, la
        # defensa que toca es la de ese tipo; si no, la de la mayoria rival.
        $contra = if ($dicho.Count -eq 1) { @($dicho.Values)[0] } elseif ($ap.Count -gt $ad.Count) { 'AP' } else { 'AD' }
        if ($contra -eq 'AP') { $h['defensa_que_conviene'] = 'resistencia magica'; $h['resistencia_magica_que_te_llega'] = $rm; $h['armadura_tambien'] = $ar }
        else { $h['defensa_que_conviene'] = 'armadura'; $h['armadura_que_te_llega'] = $ar; $h['resistencia_magica_tambien'] = $rm }

        # Los aumentos que menciona la pregunta, con lo que hacen. La API de la
        # partida NO trae los aumentos: sin esto, "Locomotora" era para el
        # modelo un item inventado.
        if ($pregunta) {
            $aum = @(Buscar-Aumentos $cat $pregunta)
            if ($aum.Count) { $h['aumentos_mencionados'] = $aum }
        }
    }
    $h
}

# ---- Partidas inventadas, para probar sin jugar -------------------------------
function Partida-Inventada([string]$formato = 'tag-solo-en-activo', [int]$oro = 2400, [int]$yo = 2) {
    $camp = @('Annie','Garen','Lux','Jinx','Thresh','Ahri','Darius','Yasuo','Caitlyn','Leona')
    $eq = for ($i = 0; $i -lt 10; $i++) {
        $p = [pscustomobject]@{
            summonerName = "Jugador$i"; championName = $camp[$i]; rawChampionName = $camp[$i]
            level = 9 + $i % 3; team = if ($i -lt 5) { 'ORDER' } else { 'CHAOS' }
            position = @('TOP','JUNGLE','MIDDLE','BOTTOM','UTILITY')[$i % 5]
            isDead = ($i -eq 7); respawnTimer = if ($i -eq 7) { 12.3 } else { 0 }
            items = @()
            scores = [pscustomobject]@{ kills = $i; deaths = 1; assists = 2; creepScore = 100 + $i }
        }
        # Lux (yo) lleva una Vara innecesariamente grande: la receta del
        # Sombrero de Rabadon pide dos.
        if ($i -eq 2) { $p.items = @([pscustomobject]@{ itemID = 1058; displayName = 'Vara innecesariamente grande'; price = 1200 }) }
        if ($formato -eq 'riotid') {
            $p | Add-Member riotId "Jugador$i#EUW" ; $p | Add-Member riotIdGameName "Jugador$i"
        }
        $p
    }
    $activo = switch ($formato) {
        'tag-solo-en-activo' { [pscustomobject]@{ summonerName = "Jugador$yo#EUW"; level = 11; currentGold = $oro + 0.7 } }
        'riotid'             { [pscustomobject]@{ riotId = "jugador$yo#euw"; summonerName = "Jugador$yo"; level = 11; currentGold = $oro + 0.7 } }
        'desconocido'        { [pscustomobject]@{ summonerName = 'Otro#EUW'; level = 11; currentGold = $oro + 0.7 } }
    }
    [pscustomobject]@{ activePlayer = $activo; allPlayers = @($eq); gameData = [pscustomobject]@{ gameMode = 'CLASSIC'; gameTime = 754.0 } }
}

function Probar {
    $cat = Get-DDragon
    # En el ambito del SCRIPT, y leidos de ahi al final. La primera version
    # apuntaba en $script:fallos y comprobaba un $fallos local, que estaba
    # siempre vacio: la prueba devolvia 0 pasara lo que pasara.
    $script:fallos = @()
    $script:ok = 0
    function Comprobar($cond, $msg) { if ($cond) { $script:ok++ } else { $script:fallos += $msg } }

    foreach ($f in 'tag-solo-en-activo', 'riotid') {
        $h = Resumir-Partida (Partida-Inventada $f) $cat
        Comprobar ($h.mi_campeon -eq 'Lux')                 "[$f] mi_campeon = '$($h.mi_campeon)'"
        Comprobar (@($h.mi_equipo).Count -eq 5)             "[$f] mi_equipo tiene $(@($h.mi_equipo).Count)"
        Comprobar (@($h.mi_equipo | Where-Object { $_.soy_yo }).Count -eq 1) "[$f] soy_yo no marca a uno"
    }
    $h = Resumir-Partida (Partida-Inventada 'tag-solo-en-activo') $cat
    Comprobar ($h.minuto -eq '12:34') "minuto = '$($h.minuto)'"
    Comprobar ($h.mi_oro -eq 2400)    "mi_oro = $($h.mi_oro)"
    Comprobar ($h.mi_perfil -eq 'Mage, dano AP') "mi_perfil = '$($h.mi_perfil)'"
    Comprobar (@($h.equipo_rival | Where-Object { $_.muerto -eq 'revive en 13 s' }).Count -eq 1) 'el muerto no aparece'

    # Rabadon: dos Varas; con una puesta falta el precio del Sombrero menos una Vara.
    $rab = $cat.items.'3089'; $vara = $cat.items.'1058'
    $falta = $rab.total - $vara.total
    Comprobar (@($h.puedo_completar | Where-Object { $_ -like "$($rab.nombre) (te faltan $falta, te llega)" }).Count -eq 1) "completar Rabadon: $($h.puedo_completar -join ' | ')"
    $h2 = Resumir-Partida (Partida-Inventada 'tag-solo-en-activo' ($falta - 1)) $cat
    Comprobar (@($h2.puedo_completar | Where-Object { $_ -like "$($rab.nombre) (te faltan $falta)" }).Count -eq 1) "con un oro menos, Rabadon no deberia llegar: $($h2.puedo_completar -join ' | ')"

    # Que propone para comprar, contra LISTAS ESCRITAS A MANO con conocimiento
    # del juego -- no contra el propio filtro.
    #
    # La version anterior de esta prueba comprobaba las etiquetas con las mismas
    # etiquetas que usaba el filtro: salio 59/59 mientras a Jinx se le proponian
    # un incensario de soporte, dos items de inicio y un elixir. Una prueba que
    # repite la logica que prueba no prueba nada.
    #
    #   nunca   items que ese campeon no se compra. Si aparece uno, falla.
    #   si      un item que DEBE salir con 3.500 de oro (los dos cuestan eso).
    $NUNCA_AP = @('3031', '3047', '2524', '3177', '2140', '3172')   # Filo infinito, Botas blindadas, Bandlemusa, Espada del guardian, Elixir, Grebas de metal
    $NUNCA_AD = @('3089', '3504', '2524', '3177', '3184', '2140')   # Rabadon, Incensario, Bandlemusa, Espada y Martillo del guardian, Elixir
    # Hidra titanica y Baile de la muerte: de luchador, no de tirador.
    $NUNCA_TIRADOR = $NUNCA_AD + @('3748', '6333')
    foreach ($caso in @(@{ yo = 2; n = 'Lux';   nunca = $NUNCA_AP; si = '3089' },
                        @{ yo = 3; n = 'Jinx';  nunca = $NUNCA_TIRADOR; si = '3031' },
                        @{ yo = 1; n = 'Garen'; nunca = $NUNCA_AD; si = $null })) {
        $hc = Resumir-Partida (Partida-Inventada 'tag-solo-en-activo' 3500 $caso.yo) $cat
        Comprobar ($hc.mi_campeon -eq $caso.n) "[$($caso.n)] no se identifico"
        Comprobar (@($hc.puedo_comprar).Count -ge 3) "[$($caso.n)] solo $(@($hc.puedo_comprar).Count) propuestas"
        $nombres = @($hc.puedo_comprar | ForEach-Object { $_ -replace '\s*\(\d+\)$', '' })
        Comprobar (@($nombres | Select-Object -Unique).Count -eq $nombres.Count) "[$($caso.n)] repetidos: $($nombres -join ' | ')"
        foreach ($id in $caso.nunca) {
            Comprobar ($nombres -notcontains $cat.items.$id.nombre) "[$($caso.n)] propone '$($cat.items.$id.nombre)', que no se compra"
        }
        if ($caso.si) { Comprobar ($nombres -contains $cat.items.($caso.si).nombre) "[$($caso.n)] falta '$($cat.items.($caso.si).nombre)': $($nombres -join ' | ')" }
        foreach ($s in $hc.puedo_comprar) {
            Comprobar ([int]($s -replace '.*\((\d+)\)$', '$1') -le $hc.mi_oro) "[$($caso.n)] propone '$s' por encima del oro"
        }
        Write-Host ("  {0,-6} {1}" -f $caso.n, ($nombres -join ' | '))
    }

    # ---- La partida REAL (ARAM Mayhem, 2026-09-22), congelada ----------------
    # Expectativas escritas a mano mirando el JSON, no sacadas del codigo: el
    # usuario es Sylas (CHAOS), su summonerName llega CON el tag, y los rivales
    # son Elise, Sivir, Yone, Jax y Nautilus.
    $muestra = Join-Path $PSScriptRoot 'prueba-lol\muestra-aram-mayhem.json'
    if (Test-Path $muestra) {
        $real = [IO.File]::ReadAllText($muestra, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        $hr = Resumir-Partida $real $cat 'Veo un Jacksa P con locomotora. ¿Qué podría sacar?'
        Comprobar ($hr.mi_campeon -eq 'Sylas') "[real] mi_campeon = '$($hr.mi_campeon)'"
        Comprobar ($hr.modo -eq 'ARAM Mayhem (con aumentos)') "[real] modo = '$($hr.modo)'"
        Comprobar ($hr.mi_perfil -match 'dano AP') "[real] perfil de Sylas = '$($hr.mi_perfil)' (rawChampionName trae prefijo)"
        Comprobar (@($hr.equipo_rival).Count -eq 5) "[real] equipo_rival tiene $(@($hr.equipo_rival).Count)"
        Comprobar ($hr.dano_rival -match 'magico: .*Elise' -and $hr.dano_rival -match 'fisico: .*Sivir') "[real] dano_rival = '$($hr.dano_rival)'"
        Comprobar (@($hr.aumentos_mencionados | Where-Object { $_ -like 'Locomotora:*' }).Count -eq 1) "[real] no reconoce Locomotora: $($hr.aumentos_mencionados -join ' | ')"
        Comprobar (@($hr.resistencia_magica_que_te_llega).Count -ge 1) '[real] ninguna resistencia magica que te llegue'
        Comprobar ((Clave-Fonetica 'Jax AP') -eq (Clave-Fonetica 'Jacksa P')) "[real] clave fonetica: '$(Clave-Fonetica 'Jax AP')' contra '$(Clave-Fonetica 'Jacksa P')'"
        Comprobar (@($hr.el_usuario_dice) -contains 'Jax va AP') "[real] el_usuario_dice = '$($hr.el_usuario_dice -join ' | ')'"
        Comprobar ($hr.dano_rival -match 'magico: 3 \(.*Jax') "[real] con Jax AP, dano_rival = '$($hr.dano_rival)'"
        Comprobar ($hr.defensa_que_conviene -eq 'resistencia magica') "[real] defensa_que_conviene = '$($hr.defensa_que_conviene)'"
        $hn = Resumir-Partida $real $cat 'como va la partida'
        Comprobar (-not $hn.aumentos_mencionados) "[real] ve aumentos donde no hay: $($hn.aumentos_mencionados -join ' | ')"
        Comprobar (-not $hn.el_usuario_dice) "[real] ve un 'X va AP' donde no hay: $($hn.el_usuario_dice -join ' | ')"
        Write-Host ("  real   {0} | {1} | defensa RM: {2}" -f $hr.mi_perfil, $hr.dano_rival, ($hr.resistencia_magica_que_te_llega -join ', '))
    }

    # Sin identidad: no se inventa el reparto.
    $h3 = Resumir-Partida (Partida-Inventada 'desconocido') $cat
    Comprobar ($h3.identidad -and -not $h3.mi_equipo) 'con un nombre que no esta, deberia decir que no sabe quien eres'
    Comprobar (@($h3.equipo_azul).Count -eq 5 -and @($h3.equipo_rojo).Count -eq 5) 'sin identidad, los equipos por color'

    $h | ConvertTo-Json -Depth 6 | Write-Host
    if ($script:fallos.Count) {
        Write-Host "`nFALLA ($($script:fallos.Count) de $($script:fallos.Count + $script:ok)):`n  $($script:fallos -join "`n  ")" -ForegroundColor Red
        return 2
    }
    Write-Host "`n$($script:ok) comprobaciones OK" -ForegroundColor Green
    0
}

# Cargado con punto (desde ojo.ps1): solo las funciones.
if ($MyInvocation.InvocationName -eq '.') { return }
if ($args -contains '-Prueba') { exit (Probar) }

# Nombres propios y no $d/$h: ojo.ps1 carga este archivo con punto y ya usa $d
# para la respuesta del modelo. Esta parte no corre al cargarlo (el return de
# arriba), pero no hace falta dejar la trampa puesta.
$lolCrudo = Get-LolDatos
if (-not $lolCrudo) { exit 1 }
# -Crudo GUARDA la muestra el mismo, en UTF-8, en prueba-lol\. Redirigirla
# desde la terminal (`> real.json`) la escribiria en la pagina de codigos de la
# consola y romperia los acentos de los nombres.
if ($args -contains '-Crudo') {
    $destino = Join-Path $PSScriptRoot ("prueba-lol\real-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date))
    [IO.File]::WriteAllText($destino, ($lolCrudo | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    "muestra guardada: $destino"
    exit 0
}
$cat = try { Get-DDragon } catch { $null }
$h = Resumir-Partida $lolCrudo $cat
if ($args -contains '-Legible') { $h | ConvertTo-Json -Depth 6 } else { $h | ConvertTo-Json -Depth 6 -Compress }
