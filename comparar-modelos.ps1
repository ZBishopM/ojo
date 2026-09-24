#Requires -Version 5.1
<#
¿Un modelo mas pequeno para todo, con vision, que quepa tambien con LoL?

Mide cada candidato con TODOS los bancos, varias vueltas, sin pelear con el
supervisor:
  - M0 (el 8B de hoy) se mide donde esta, en el 8099, sin tocar nada;
  - los demas en el 8097: una copia inerte de ping.exe llamada
    "League of Legends.exe" (SIN la API del 2999) hace que el supervisor cambie
    el 8B por el de partida y suelte la tarjeta; ojo.ps1 no entra en modo
    partida (necesita los datos del juego). Al acabar se quita y el supervisor
    vuelve al 8B.

"Con LoL": voz\reservar_vram.py retiene lo que LoL ocupa de verdad (medido en
partida real el 2026-09-24: 980 MiB la partida + 284 el cliente) y se repiten
tok/s, las pantallas reales y la partida.

Variantes de vision (solo pantallas reales): -Zoom guiado y -LadoImagen 1920.

    .\comparar-modelos.ps1 -Candidatos M0 -Vueltas 3
    .\comparar-modelos.ps1 -Candidatos M1 -Vueltas 3
#>
param([string[]]$Candidatos = @('M1', 'M2', 'M3', 'M4'), [int]$Vueltas = 2, [int]$Puerto = 8097, [int]$ReservaMiB = 1300,
      # Mide tambien la voz Pocket en GPU (con y sin la reserva) mientras el 8B esta fuera.
      [switch]$ConVoz,
      # Sin las variantes de vision (zoom, 1920).
      [switch]$SinVariantes)
$ErrorActionPreference = 'Stop'
# Con -File, "-Candidatos M1,M2" llega como UNA cadena.
$Candidatos = @($Candidatos -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$llama = 'F:\ai\llama.cpp\llama-server.exe'
$M = 'F:\ai\models'
$CAT = [ordered]@{
    M0 = @{ nombre = 'Qwen3-VL-8B Q6_K + vision (el de hoy)'; yaCargado = 8099; vista = 'imagen' }
    M1 = @{ nombre = 'Qwen3.5-4B + vision'; gguf = "$M\Qwen3.5-4B-UD-Q5_K_XL.gguf"; mmproj = "$M\qwen3.5-4b\mmproj-F16.gguf"; vista = 'imagen' }
    M2 = @{ nombre = 'Qwen3.5-4B solo texto (OCR + controles)'; gguf = "$M\Qwen3.5-4B-UD-Q5_K_XL.gguf"; mmproj = $null; vista = 'ocr' }
    M3 = @{ nombre = 'Qwen3-VL-4B Q8_0 + vision'; gguf = "$M\qwen3-vl-4b\Qwen3VL-4B-Instruct-Q8_0.gguf"; mmproj = "$M\qwen3-vl-4b\mmproj-Qwen3VL-4B-Instruct-F16.gguf"; vista = 'imagen' }
    M4 = @{ nombre = 'Gemma 4 E4B Q4_K_M + vision'; gguf = "$M\gemma-4-e4b\gemma-4-E4B-it-Q4_K_M.gguf"; mmproj = "$M\gemma-4-e4b\mmproj-gemma-4-E4B-it-Q8_0.gguf"; vista = 'imagen' }
}
$salida = "$raiz\comparar-modelos.json"
$todo = @(if (Test-Path $salida) { [IO.File]::ReadAllText($salida, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json | ForEach-Object { $_ } })

function Vivo([int]$p) { try { (Invoke-RestMethod "http://127.0.0.1:$p/health" -TimeoutSec 2).status -eq 'ok' } catch { $false } }
function Esperar([scriptblock]$cond, [int]$seg, [string]$que) {
    $t = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $cond)) { if ($t.Elapsed.TotalSeconds -gt $seg) { throw "no llego: $que" }; Start-Sleep -Milliseconds 500 }
}
function Tok([int]$p) {
    $b = @{ messages = @(@{ role = 'user'; content = 'Escribe exactamente cien palabras sobre el mar.' }); max_tokens = 120
            chat_template_kwargs = @{ enable_thinking = $false } } | ConvertTo-Json -Depth 5
    $r = Invoke-RestMethod "http://127.0.0.1:$p/v1/chat/completions" -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($b)) -TimeoutSec 600
    [math]::Round($r.timings.predicted_per_second, 1)
}
# Corre un script de prueba y devuelve si paso y sus lineas de FALLA.
function Prueba([string]$script, [hashtable]$args_) {
    $ErrorActionPreference = 'Continue'
    # A lista: con -File, un hashtable "splateado" manda "-SoloReal:True" y el
    # interruptor no se enlaza.
    Avance "$script $($args_.Nombre)"
    $lista = @(foreach ($k in $args_.Keys) { if ($args_[$k] -is [bool]) { if ($args_[$k]) { "-$k" } } else { "-$k"; "$($args_[$k])" } })
    $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File "$raiz\$script" @lista 2>&1 | ForEach-Object { "$_" })
    $codigo = $LASTEXITCODE
    $out = @(($out -join "`n") -split '\r?\n')
    [pscustomobject]@{ ok = ($codigo -eq 0); resumen = ($out | Where-Object { $_ -match 'OK\s*$|todo OK|aciertos|camino real|\d+/\d+' } | Select-Object -Last 3) -join ' · '
                       fallos = @($out | Where-Object { $_ -match '^\s*FALLA|^\s+\d+:|^MAL' } | Select-Object -First 20) }
}
# Aplanado a cualquier profundidad: los bancos anexaban con la trampa de
# ConvertFrom-Json (el array leido como UN objeto) y cada corrida anidaba la
# anterior un nivel mas. Ya esta arreglado al escribir; esto lee lo viejo.
function Aplanar($x) { foreach ($e in @($x)) { if ($e -is [array]) { Aplanar $e } elseif ($e.value -is [array]) { Aplanar $e.value } elseif ($e) { $e } } }
function Ultimo([string]$f, [string]$nombre) {
    @(Aplanar ([IO.File]::ReadAllText("$raiz\$f", [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json) | Where-Object nombre -eq $nombre)[-1]
}
# Progreso real para la barra (progreso.ps1): pasos hechos de los totales. Por
# candidato: 7 pruebas por vuelta, las 2 variantes y las 3 medidas "con LoL".
$script:pasoAhora = 0
$script:pasosTotal = [math]::Max(1, $Candidatos.Count * (7 * $Vueltas + $(if ($SinVariantes) { 0 } else { 1 }) + 3 + 1))
$script:inicio = (Get-Date).ToString('o')
function Avance([string]$que) {
    $script:pasoAhora++
    $p = [ordered]@{ tarea = "comparar-modelos $($Candidatos -join ',')"; inicio = $script:inicio; paso = $script:pasoAhora; total = $script:pasosTotal; ahora = $que
                     juego_inerte = [bool]$juego }
    try { [IO.File]::WriteAllText("$raiz\progreso.json", ($p | ConvertTo-Json), [Text.UTF8Encoding]::new($false)) } catch { }
}
function PorCategoria($bp) { (@($bp.filas | Group-Object cat | ForEach-Object { "$($_.Name) $(@($_.Group | Where-Object real).Count)/$($_.Count)" })) -join ' · ' }

# ---- Liberar la tarjeta (solo si hay candidatos que levantar) -------------------
$tmp = Join-Path $env:TEMP 'ojo-comparar'; New-Item -ItemType Directory -Force $tmp | Out-Null
$hayQueLevantar = @($Candidatos | Where-Object { -not $CAT[$_].yaCargado }).Count -gt 0
$juego = $null; $servidor = $null; $reserva = $null
try {
    if ($hayQueLevantar) {
        $exe = Join-Path $tmp 'League of Legends.exe'
        Copy-Item "$env:SystemRoot\System32\PING.EXE" $exe -Force
        $juego = Start-Process $exe -ArgumentList '-t', '127.0.0.1' -WindowStyle Hidden -PassThru
        Write-Host 'esperando a que el supervisor ponga el modelo de partida en el 8099...'
        Esperar { try { (Invoke-RestMethod http://127.0.0.1:8099/props -TimeoutSec 2).model_path -match 'Qwen3\.5-4B' } catch { $false } } 300 'el 4B en el 8099'
        Esperar { Vivo 8099 } 120 'el 8099 sano'
    }

    # ---- La voz Pocket en GPU, ahora que el 8B no ocupa la tarjeta ----------------
    if ($ConVoz -and $hayQueLevantar) {
        $py = 'F:\ai\tts\pocket-gpu\.venv\Scripts\python.exe'
        Push-Location "$raiz\voz"
        try {
            $ErrorActionPreference = 'Continue'
            & $py probar_ligera.py pocket lola --device cuda --vueltas 3 2>&1 | Where-Object { "$_" -match '^\{"candidata' } | ForEach-Object { Write-Host "voz GPU: $_" }
            $reserva = Start-Process $py -ArgumentList "$raiz\voz\reservar_vram.py", "$ReservaMiB" -WindowStyle Hidden -PassThru
            Start-Sleep -Seconds 8
            & $py probar_ligera.py pocket lola --device cuda --vueltas 3 --sufijo -reserva 2>&1 | Where-Object { "$_" -match '^\{"candidata' } | ForEach-Object { Write-Host "voz GPU con reserva: $_" }
            Stop-Process -Id $reserva.Id -Force -EA SilentlyContinue; $reserva = $null
            $ErrorActionPreference = 'Stop'
        } finally { Pop-Location }
    }

    foreach ($id in $Candidatos) {
        $c = $CAT[$id]
        Write-Host "`n==== $id  $($c.nombre)" -ForegroundColor Cyan
        $P = if ($c.yaCargado) { $c.yaCargado } else { $Puerto }
        if (-not $c.yaCargado) {
            $a = @('--model', $c.gguf, '--ctx-size', '8192', '--n-gpu-layers', '99', '--flash-attn', 'on', '--threads', '6', '--parallel', '1',
                   '--load-mode', 'none', '--cache-ram', '1024', '-ctk', 'q8_0', '-ctv', 'q8_0', '--no-warmup', '--jinja', '--port', "$P", '--host', '127.0.0.1')
            if ($c.mmproj) { $a += @('--mmproj', $c.mmproj) }
            $servidor = Start-Process $llama -ArgumentList $a -WindowStyle Hidden -PassThru -RedirectStandardError "$tmp\$id.log" -RedirectStandardOutput "$tmp\$id.out"
        }
        Esperar { Vivo $P } 300 "$id en el $P"
        & powershell -NoProfile -ExecutionPolicy Bypass -File "$raiz\vram.ps1" -Estado "modelo-$id" | Out-Null
        $v = [IO.File]::ReadAllText("$raiz\vram-modelo-$id.json", [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        $delModelo = if ($c.yaCargado) { { $_.nombre -like 'Ojo: modelo*' -and $_.nombre -notmatch ':\d+$' } } else { { $_.nombre -like "*:$P" } }
        $fila = [ordered]@{ id = $id; nombre = $c.nombre; fecha = Get-Date -Format 'yyyy-MM-dd HH:mm'; vram_usada = $v.usada_mib
                            vram_modelo = [int](@($v.procesos | Where-Object $delModelo) | Measure-Object mib -Sum).Sum
                            tok_s = Tok $P; vueltas = @(); variantes = [ordered]@{} }
        for ($n = 1; $n -le $Vueltas; $n++) {
            $tag = "$id-v$n"
            $vu = [ordered]@{ vuelta = $n }
            $pa = @{ Nombre = $tag; Puerto = $P; Vista = $c.vista }
            if ($n -gt 1 -or $c.vista -eq 'ocr') { $pa.SoloReal = $true }   # la imagen sola, una vez
            $null = Prueba 'banco-pantalla.ps1' $pa
            $bp = Ultimo 'banco-pantalla.json' $tag
            $vu.pantalla = [ordered]@{ real = $bp.real; sola = $bp.sola; categorias = PorCategoria $bp
                                       fallos = @($bp.filas | Where-Object { $_.real -eq $false } | ForEach-Object { "[$($_.res), $($_.cat)] $($_.q) -> $($_.dijo)" }) }
            $null = Prueba 'banco-verdad.ps1' @{ Nombre = $tag; Puerto = $P; Vista = $c.vista }
            $bv = Ultimo 'banco-verdad.json' $tag
            $vu.verdad = [ordered]@{ aciertos = $bv.aciertos; inventos = $bv.inventos; ms = $bv.ms_medio; fallos = @($bv.filas | Where-Object { -not $_.ok -or $_.invento } | ForEach-Object { "$($_.q) -> $($_.dijo)" }) }
            # $pr y no $p: PowerShell no distingue mayusculas y $p ES $P, el
            # puerto (el puerto paso a valer "prueba-conocer.ps1").
            foreach ($pr in 'prueba-chat.ps1', 'prueba-personas.ps1', 'prueba-conocer.ps1') {
                $vu[$pr -replace '\.ps1$', ''] = Prueba $pr @{ Puerto = $P; Vista = $c.vista }
            }
            foreach ($real in $false, $true) {
                $nb = "$tag$(if ($real) { '-real' })"
                $args_ = @{ Nombre = $nb; Puerto = $P; Vueltas = 1 }; if ($real) { $args_.Real = $true }
                $null = Prueba 'banco-partida.ps1' $args_
                $bpa = Ultimo 'banco-partida.json' $nb
                $vu["partida$(if ($real) { '_real' })"] = [ordered]@{ aciertos = $bpa.aciertos; ms = $bpa.ms_medio; fallos = @($bpa.filas | Where-Object { -not $_.ok } | ForEach-Object { "$($_.q) -> $($_.dijo)" }) }
            }
            $fila.vueltas += [pscustomobject]$vu
            # Guardar tras cada vuelta: si algo corta la corrida, lo medido queda.
            $todo = @($todo | Where-Object { $_.id -ne $id -or $_.fecha -ne $fila.fecha }) + [pscustomobject]$fila
            [IO.File]::WriteAllText($salida, (ConvertTo-Json @($todo) -Depth 8), [Text.UTF8Encoding]::new($false))
        }
        # ---- Variantes de vision, en las pantallas reales ----------------------------
        if (-not $SinVariantes -and $c.vista -eq 'imagen') {
            # (1920 fuera: con el OCR y los controles pasa del contexto de 8.192
            # tokens, "request (8241 tokens) exceeds the available context size")
            foreach ($var in @(@{ n = 'zoom'; a = @{ Zoom = 'guiado' } })) {
                $tagV = "$id-$($var.n)"
                $pa = @{ Nombre = $tagV; Puerto = $P; Vista = $c.vista; SoloReal = $true; SoloReales = $true } + $var.a
                $null = Prueba 'banco-pantalla.ps1' $pa
                $bp = Ultimo 'banco-pantalla.json' $tagV
                $fila.variantes[$var.n] = [ordered]@{ real = $bp.real; categorias = PorCategoria $bp; ms_medio = [math]::Round((@($bp.filas) | Measure-Object ms -Average).Average)
                                                     fallos = @($bp.filas | Where-Object { $_.real -eq $false } | ForEach-Object { "[$($_.res), $($_.cat)] $($_.q) -> $($_.dijo)" }) }
            }
        }
        # ---- "Con LoL": lo que ocupa LoL de verdad, retenido -------------------------
        $reserva = Start-Process 'F:\ai\tts\pocket-gpu\.venv\Scripts\python.exe' -ArgumentList "$raiz\voz\reservar_vram.py", "$ReservaMiB" -WindowStyle Hidden -PassThru
        Start-Sleep -Seconds 8   # que el driver asigne la reserva (tocada con fill_) antes de medir
        $conLol = [ordered]@{ reserva_mib = $ReservaMiB; tok_s = Tok $P }
        $tagL = "$id-lol"
        $null = Prueba 'banco-pantalla.ps1' @{ Nombre = $tagL; Puerto = $P; Vista = $c.vista; SoloReal = $true; SoloReales = $true }
        $conLol.pantallas_reales = (Ultimo 'banco-pantalla.json' $tagL).real
        $null = Prueba 'banco-partida.ps1' @{ Nombre = "$tagL-partida"; Puerto = $P; Vueltas = 1 }
        $conLol.partida = (Ultimo 'banco-partida.json' "$tagL-partida").aciertos
        $conLol.tok_s_despues = Tok $P
        Avance "$id con LoL: tok/s despues"
        Stop-Process -Id $reserva.Id -Force -EA SilentlyContinue; $reserva = $null
        # Lo que gasta este modelo contestando sin parar (medir-consumo.ps1).
        & powershell -NoProfile -ExecutionPolicy Bypass -File "$raiz\medir-consumo.ps1" -Escenario "ojo-$($id.ToLower())" -Carga ojo -Puerto $P -Segundos 60 | Out-Null
        Avance "$id consumo"
        $conLol.derrama = $conLol.tok_s -lt 0.7 * $fila.tok_s
        $fila.con_lol = [pscustomobject]$conLol
        if ($servidor) { Stop-Process -Id $servidor.Id -Force -EA SilentlyContinue; Wait-Process -Id $servidor.Id -Timeout 20 -EA SilentlyContinue; $servidor = $null }
        $todo = @($todo | Where-Object { $_.id -ne $id -or $_.fecha -ne $fila.fecha }) + [pscustomobject]$fila
        [IO.File]::WriteAllText($salida, (ConvertTo-Json @($todo) -Depth 8), [Text.UTF8Encoding]::new($false))
        Write-Host ("{0}: {1} tok/s, VRAM modelo {2} MiB; con LoL {3} tok/s{4}" -f $id, $fila.tok_s, $fila.vram_modelo, $conLol.tok_s, $(if ($conLol.derrama) { ' (DERRAMA)' }))
    }
} finally {
    if ($reserva) { Stop-Process -Id $reserva.Id -Force -EA SilentlyContinue }
    if ($servidor) { Stop-Process -Id $servidor.Id -Force -EA SilentlyContinue }
    if ($juego) { Stop-Process -Id $juego.Id -Force -EA SilentlyContinue; Write-Host 'juego inerte quitado; el supervisor vuelve al 8B' }
    $juego = $null; $script:pasoAhora = $script:pasosTotal - 1; Avance 'terminado'
}
