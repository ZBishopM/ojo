#Requires -Version 5.1
<#
Buscar en internet y traer lo que dicen las paginas, con su fuente.

POR QUE: la regla del usuario, literal: "no quiero que invente, ni que diga que
no sabe; cuando no lo sepa o este en duda, que lo BUSQUE y cite sus fuentes".
El modelo no sabe nada posterior a su entrenamiento ni nada que cambie (precios,
resultados, parches, noticias).

COMO: SearXNG local (buscador.py, 127.0.0.1:8888, solo DuckDuckGo) da los
resultados. Los fragmentos casi nunca traen el dato ("consulta el precio del
dolar hoy..."), asi que se leen las primeras paginas -- en paralelo, con un
solo curl -- y de cada una se quedan las lineas que mas se parecen a la
pregunta. Una busqueda por consulta y dia: se cachea en web-cache\.

    . .\buscar.ps1                  (con punto) Buscar-Web, Texto-Web
    .\buscar.ps1 "precio del dolar hoy en Peru"
#>
$ErrorActionPreference = 'Stop'
$BUSCAR_URL = 'http://127.0.0.1:8888/search'
$BUSCAR_CACHE = Join-Path $PSScriptRoot 'web-cache'
$BUSCAR_NAVEGADOR = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36'

# El texto legible de una pagina: sin scripts, estilos ni etiquetas, una linea
# por bloque.
function Texto-De-Html([string]$html) {
    $t = $html -replace '(?is)<(script|style|noscript|svg|head)[^>]*>.*?</\1>', ' '
    $t = $t -replace '(?i)<(br|/p|/div|/li|/h\d|/tr|/td|/th)[^>]*>', "`n"
    $t = $t -replace '<[^>]+>', ' '
    $t = [Net.WebUtility]::HtmlDecode($t)
    @($t -split "`n" | ForEach-Object { ($_ -replace '\s+', ' ').Trim() } | Where-Object { $_.Length -ge 20 -and $_.Length -le 400 })
}

# Las lineas que mas palabras de la pregunta llevan (y cifras, que suelen ser el
# dato), en el orden de la pagina. Tope de caracteres.
function Lo-Relevante($lineas, [string]$consulta, [int]$tope = 1200) {
    $terminos = @(($consulta.ToLowerInvariant() -split '[^\p{L}\p{N}]+') | Where-Object { $_.Length -ge 4 })
    $puntuadas = for ($i = 0; $i -lt $lineas.Count; $i++) {
        $l = $lineas[$i].ToLowerInvariant()
        $p = @($terminos | Where-Object { $l.Contains($_) }).Count
        if ($lineas[$i] -match '\d') { $p += 0.5 }
        [pscustomobject]@{ i = $i; p = $p; t = $lineas[$i] }
    }
    $elegidas = @($puntuadas | Where-Object p -ge 1 | Sort-Object p -Descending | Select-Object -First 12 | Sort-Object i)
    $out = ''
    foreach ($e in $elegidas) { if (($out.Length + $e.t.Length) -gt $tope) { break }; $out += $e.t + "`n" }
    $out.Trim()
}

# Varias consultas a la vez (la del modelo y la frase literal del usuario): el
# modelo a veces reformula de forma rebuscada ("tipo de cambio dolar
# estadounidense a soles peruanos") y le salen paginas que pintan el dato con
# JavaScript; la frase del usuario ("a cuanto esta el dolar hoy") da paginas
# que lo escriben. Los resultados se intercalan y sin repetir.
function Buscar-Web([string[]]$consultas, [int]$paginas = 3) {
    $consultas = @($consultas | Where-Object { "$_".Trim() } | Select-Object -Unique)
    $consulta = $consultas -join ' | '
    New-Item -ItemType Directory -Force $BUSCAR_CACHE | Out-Null
    $md5 = [Security.Cryptography.MD5]::Create()
    $clave = -join ($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("$(Get-Date -Format yyyyMMdd)|$consulta")) | ForEach-Object { $_.ToString('x2') })
    $f = Join-Path $BUSCAR_CACHE "$clave.json"
    if (Test-Path $f) { return [IO.File]::ReadAllText($f, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json }

    $dirJ = Join-Path $env:TEMP 'ojo-buscar'
    New-Item -ItemType Directory -Force $dirJ | Out-Null
    Get-ChildItem $dirJ -File | Remove-Item -EA SilentlyContinue
    $a = @('-s', '--parallel', '--max-time', '8')
    for ($i = 0; $i -lt $consultas.Count; $i++) {
        $a += @('-o', (Join-Path $dirJ "$i.json"), "$BUSCAR_URL`?q=$([uri]::EscapeDataString($consultas[$i]))&format=json&language=es")
    }
    # DuckDuckGo corta a ratos, y tras una rafaga pide CAPTCHA (visto el
    # 2026-09-23). Si no llega nada, se reintenta con motores de RESERVA
    # (deshabilitados por defecto en settings.yml, se piden explicitamente):
    # DuckDuckGo sigue siendo el unico en uso normal, decision del usuario.
    for ($intento = 1; $intento -le 2; $intento++) {
        # Tras las rafagas de los bancos (~40 busquedas en minutos) cayeron
        # tambien Brave (too many requests) y Qwant (CAPTCHA): reserva amplia.
        if ($intento -eq 2) { $a = @($a | ForEach-Object { if ($_ -like "$BUSCAR_URL*") { "$_&engines=brave,mojeek,qwant,startpage,bing,wikipedia" } else { $_ } }) }
        & curl.exe @a 2>$null
        # Lista explicita de listas: con la coma unaria y UNA sola consulta,
        # PowerShell deshacia el anidado y no salia ningun resultado.
        $listas = [Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $consultas.Count; $i++) {
            $p = Join-Path $dirJ "$i.json"
            $listas.Add(@(if (Test-Path $p) { try { ([IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json).results } catch { } }))
        }
        if (@($listas | ForEach-Object { $_ }).Count) { break }
    }
    $vistos = @{}
    $res = @(for ($k = 0; $k -lt 10; $k++) {
        foreach ($l in $listas) { if ($k -lt $l.Count -and -not $vistos[$l[$k].url]) { $vistos[$l[$k].url] = 1; $l[$k] } }
    }) | Select-Object -First 5
    $res = @($res)
    if (-not $res.Count) { return $null }

    # Las primeras paginas, en paralelo y con tope: una pagina lenta no puede
    # frenar la respuesta mas de 5 s.
    $leer = @($res | Select-Object -First $paginas)
    $dir = Join-Path $env:TEMP 'ojo-paginas'
    New-Item -ItemType Directory -Force $dir | Out-Null
    Get-ChildItem $dir -File | Remove-Item -EA SilentlyContinue
    # Tope de 3 s por pagina: con 5, una lenta alargaba la busqueda a ~6 s.
    $a = @('-s', '-L', '--parallel', '--max-time', '3', '--connect-timeout', '2', '-A', $BUSCAR_NAVEGADOR, '--compressed')
    for ($i = 0; $i -lt $leer.Count; $i++) { $a += @('-o', (Join-Path $dir "$i.html"), $leer[$i].url) }
    & curl.exe @a 2>$null

    $fuentes = for ($i = 0; $i -lt $res.Count; $i++) {
        $p = Join-Path $dir "$i.html"
        $texto = if (Test-Path $p) { Lo-Relevante (Texto-De-Html ([IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false)))) $consulta } else { '' }
        [ordered]@{ titulo = "$($res[$i].title)"; url = "$($res[$i].url)"; sitio = ([uri]$res[$i].url).Host -replace '^www\.', ''
                    fragmento = "$($res[$i].content)"; texto = $texto }
    }
    $b = [ordered]@{ consulta = $consulta; fecha = (Get-Date -Format 'yyyy-MM-dd HH:mm'); fuentes = @($fuentes) }
    [IO.File]::WriteAllText($f, ($b | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    [pscustomobject]$b
}

# Los resultados como bloque para el modelo.
function Texto-Web($b) {
    if (-not $b) { return '' }
    $partes = foreach ($s in $b.fuentes) {
        "[$($s.sitio)] $($s.titulo)`n$($s.fragmento)" + $(if ($s.texto) { "`n$($s.texto)" } else { '' })
    }
    "RESULTADOS WEB (buscado ahora, $($b.fecha), consulta: `"$($b.consulta)`"):`n" + ($partes -join "`n---`n")
}

if ($MyInvocation.InvocationName -eq '.') { return }
# Varias consultas separadas por " | ".
$q = @(($args -join ' ') -split '\s*\|\s*')
$sw = [Diagnostics.Stopwatch]::StartNew()
$b = Buscar-Web $q
Texto-Web $b
Write-Host "--- $([int]$sw.Elapsed.TotalMilliseconds) ms"
