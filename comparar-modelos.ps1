#Requires -Version 5.1
<#
¿Un modelo mas pequeno para todo, con vision, que quepa tambien con LoL?

Mide cada candidato con TODOS los bancos, dos vueltas, en el puerto 8097, sin
pelear con el supervisor:
  - una copia inerte de ping.exe llamada "League of Legends.exe" (SIN la API
    del 2999) hace que el supervisor cambie el 8B por el 4B de texto y suelte
    la tarjeta; ojo.ps1 no entra en modo partida (necesita los datos del juego);
  - cada candidato se levanta en el 8097 con las opciones de Ojo;
  - al acabar se quita todo y el supervisor vuelve al 8B.

"Con LoL" simulado: voz\reservar_vram.py retiene 4.600 MiB de VRAM (lo que pide
LoL) y se repiten tok/s, las pantallas reales y la partida.

    .\comparar-modelos.ps1                    M1 M2 M3 M4
    .\comparar-modelos.ps1 -Candidatos M1,M2 -Vueltas 1
#>
param([string[]]$Candidatos = @('M1', 'M2', 'M3', 'M4'), [int]$Vueltas = 2, [int]$Puerto = 8097, [int]$ReservaMiB = 4600,
      # Mide tambien la voz Pocket en GPU (con y sin la reserva) mientras el 8B esta fuera.
      [switch]$ConVoz)
$ErrorActionPreference = 'Stop'
# Con -File, "-Candidatos M1,M2" llega como UNA cadena.
$Candidatos = @($Candidatos -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$llama ='F:\ai\llama.cpp\llama-server.exe'
$M = 'F:\ai\models'
$CAT = [ordered]@{
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
    $lista = @(foreach ($k in $args_.Keys) { if ($args_[$k] -is [bool]) { if ($args_[$k]) { "-$k" } } else { "-$k"; "$($args_[$k])" } })
    $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File "$raiz\$script" @lista 2>&1 | ForEach-Object { "$_" })
    $codigo = $LASTEXITCODE
    $out = @(($out -join "`n") -split '\r?\n')
    [pscustomobject]@{ ok = ($codigo -eq 0); resumen = ($out | Where-Object { $_ -match 'OK\s*$|todo OK|aciertos|camino real|\d+/\d+' } | Select-Object -Last 3) -join ' · '
                       fallos = @($out | Where-Object { $_ -match '^\s*FALLA|^\s+\d+:|^MAL' } | Select-Object -First 20) }
}
function Ultimo([string]$f, [string]$nombre) {
    @([IO.File]::ReadAllText("$raiz\$f", [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json | ForEach-Object { $_ } | ForEach-Object { if ($_.value) { $_.value } else { $_ } } | ForEach-Object { $_ } | Where-Object nombre -eq $nombre)[-1]
}

# ---- Liberar la tarjeta: el "juego" inerte, sin API ------------------------------
$tmp = Join-Path $env:TEMP 'ojo-comparar'; New-Item -ItemType Directory -Force $tmp | Out-Null
$exe = Join-Path $tmp 'League of Legends.exe'
Copy-Item "$env:SystemRoot\System32\PING.EXE" $exe -Force
$juego = Start-Process $exe -ArgumentList '-t', '127.0.0.1' -WindowStyle Hidden -PassThru
$servidor = $null; $reserva = $null
try {
    Write-Host 'esperando a que el supervisor ponga el 4B de texto en el 8099...'
    Esperar { try { (Invoke-RestMethod http://127.0.0.1:8099/props -TimeoutSec 2).model_path -match 'Qwen3\.5-4B' } catch { $false } } 300 'el 4B en el 8099'
    Esperar { Vivo 8099 } 120 'el 8099 sano'

    # ---- La voz Pocket en GPU, ahora que el 8B no ocupa la tarjeta ----------------
    if ($ConVoz) {
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
        $a = @('--model', $c.gguf, '--ctx-size', '8192', '--n-gpu-layers', '99', '--flash-attn', 'on', '--threads', '6', '--parallel', '1',
               '--load-mode', 'none', '--cache-ram', '1024', '-ctk', 'q8_0', '-ctv', 'q8_0', '--no-warmup', '--jinja', '--port', "$Puerto", '--host', '127.0.0.1')
        if ($c.mmproj) { $a += @('--mmproj', $c.mmproj) }
        $servidor = Start-Process $llama -ArgumentList $a -WindowStyle Hidden -PassThru -RedirectStandardError "$tmp\$id.log" -RedirectStandardOutput "$tmp\$id.out"
        Esperar { Vivo $Puerto } 300 "$id en el $Puerto"
        & powershell -NoProfile -ExecutionPolicy Bypass -File "$raiz\vram.ps1" -Estado "modelo-$id" | Out-Null
        $v = [IO.File]::ReadAllText("$raiz\vram-modelo-$id.json", [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        $fila = [ordered]@{ id = $id; nombre = $c.nombre; fecha = Get-Date -Format 'yyyy-MM-dd HH:mm'; vram_usada = $v.usada_mib
                            vram_modelo = [int](@($v.procesos | Where-Object { $_.nombre -like "*:$Puerto" }) | Measure-Object mib -Sum).Sum
                            tok_s = Tok $Puerto; vueltas = @() }
        for ($n = 1; $n -le $Vueltas; $n++) {
            $tag = "$id-v$n"
            $vu = [ordered]@{ vuelta = $n }
            $pa = @{ Nombre = $tag; Puerto = $Puerto; Vista = $c.vista }
            if ($n -gt 1 -or $c.vista -eq 'ocr') { $pa.SoloReal = $true }   # la imagen sola, una vez
            $null = Prueba 'banco-pantalla.ps1' $pa
            $bp = Ultimo 'banco-pantalla.json' $tag
            $vu.pantalla = [ordered]@{ real = $bp.real; sola = $bp.sola; fallos = @($bp.filas | Where-Object { $_.real -eq $false } | ForEach-Object { "[$($_.res), $($_.cat)] $($_.q) -> $($_.dijo)" }) }
            $null = Prueba 'banco-verdad.ps1' @{ Nombre = $tag; Puerto = $Puerto; Vista = $c.vista }
            $bv = Ultimo 'banco-verdad.json' $tag
            $vu.verdad = [ordered]@{ aciertos = $bv.aciertos; inventos = $bv.inventos; ms = $bv.ms_medio; fallos = @($bv.filas | Where-Object { -not $_.ok -or $_.invento } | ForEach-Object { "$($_.q) -> $($_.dijo)" }) }
            foreach ($p in 'prueba-chat.ps1', 'prueba-personas.ps1', 'prueba-conocer.ps1') {
                $vu[$p -replace '\.ps1$', ''] = Prueba $p @{ Puerto = $Puerto; Vista = $c.vista }
            }
            foreach ($real in $false, $true) {
                $nb = "$tag$(if ($real) { '-real' })"
                $args_ = @{ Nombre = $nb; Puerto = $Puerto; Vueltas = 1 }; if ($real) { $args_.Real = $true }
                $null = Prueba 'banco-partida.ps1' $args_
                $bpa = Ultimo 'banco-partida.json' $nb
                $vu["partida$(if ($real) { '_real' })"] = [ordered]@{ aciertos = $bpa.aciertos; ms = $bpa.ms_medio; fallos = @($bpa.filas | Where-Object { -not $_.ok } | ForEach-Object { "$($_.q) -> $($_.dijo)" }) }
            }
            $fila.vueltas += [pscustomobject]$vu
        }
        # ---- "Con LoL" simulado: 4.600 MiB retenidos --------------------------------
        $reserva = Start-Process 'F:\ai\tts\pocket-gpu\.venv\Scripts\python.exe' -ArgumentList "$raiz\voz\reservar_vram.py", "$ReservaMiB" -WindowStyle Hidden -PassThru
        Start-Sleep -Seconds 8   # que el driver asigne la reserva (tocada con fill_) antes de medir
        $conLol = [ordered]@{ reserva_mib = $ReservaMiB; tok_s = Tok $Puerto }
        $tagL = "$id-lol"
        $null = Prueba 'banco-pantalla.ps1' @{ Nombre = $tagL; Puerto = $Puerto; Vista = $c.vista; SoloReal = $true; SoloReales = $true }
        $conLol.pantallas_reales = (Ultimo 'banco-pantalla.json' $tagL).real
        $null = Prueba 'banco-partida.ps1' @{ Nombre = "$tagL-partida"; Puerto = $Puerto; Vueltas = 1 }
        $conLol.partida = (Ultimo 'banco-partida.json' "$tagL-partida").aciertos
        $conLol.tok_s_despues = Tok $Puerto
        $conLol.derrama = $conLol.tok_s -lt 0.7 * $fila.tok_s
        Stop-Process -Id $reserva.Id -Force -EA SilentlyContinue; $reserva = $null
        $fila.con_lol = [pscustomobject]$conLol
        Stop-Process -Id $servidor.Id -Force -EA SilentlyContinue; Wait-Process -Id $servidor.Id -Timeout 20 -EA SilentlyContinue; $servidor = $null
        $todo = @($todo | Where-Object { $_.id -ne $id -or $_.fecha -ne $fila.fecha }) + [pscustomobject]$fila
        [IO.File]::WriteAllText($salida, (ConvertTo-Json @($todo) -Depth 8), [Text.UTF8Encoding]::new($false))
        Write-Host ("{0}: {1} tok/s, VRAM modelo {2} MiB; con LoL {3} tok/s{4}" -f $id, $fila.tok_s, $fila.vram_modelo, $conLol.tok_s, $(if ($conLol.derrama) { ' (DERRAMA)' }))
    }
} finally {
    if ($reserva) { Stop-Process -Id $reserva.Id -Force -EA SilentlyContinue }
    if ($servidor) { Stop-Process -Id $servidor.Id -Force -EA SilentlyContinue }
    Stop-Process -Id $juego.Id -Force -EA SilentlyContinue
    Write-Host 'juego inerte quitado; el supervisor vuelve al 8B'
}
