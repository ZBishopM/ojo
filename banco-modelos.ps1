# Banco de pruebas para decidir QUE MODELO sirve el rice.
#
# No mide sensaciones: cada prueba tiene una respuesta correcta que el propio
# script comprueba. Una regex se ejecuta contra cadenas reales, un JSON se
# parsea, un numero se compara, el codigo generado SE EJECUTA.
#
# El contenido de las pruebas sale de archivos REALES de este equipo
# (presets.ini, MEDICIONES.md, rice-llm.ps1), no de textos inventados, porque
# lo que se quiere saber es si el modelo sirve para lo que se usa aqui.
#
#   .\banco-modelos.ps1                 los dos modelos, informe al final
#   .\banco-modelos.ps1 -Modelos 8b     solo uno
#   .\banco-modelos.ps1 -Vueltas 3      repite cada prueba, para ver varianza
#
# Se corre SIN mmproj: la parte de vision ya esta medida en MEDICIONES.md y
# quitarlo deja 1,08 GB de VRAM para contexto, que es lo que aqui hace falta.
param(
    [string[]]$Modelos = @('35b', '8b'),
    [int]$Vueltas = 1,
    [int]$Puerto = 8099,
    [int]$Ctx = 16384,
    # Solo estas pruebas. Sirve para repetir las dudosas muchas veces sin pagar
    # las que ya estan claras: una sola vuelta no decide nada.
    #
    # Se llama -Solo y no -Pruebas porque PowerShell no distingue mayusculas en
    # los nombres de variable: $Pruebas habria pisado la tabla $PRUEBAS y la
    # dejaba vacia. Tercera vez que muerde en este proyecto -- antes fueron
    # $Controles y $Modelo en ojo.ps1.
    [string[]]$Solo = @(),
    [string]$Salida = 'D:\2026-projects\ojo\banco-resultados.json',
    # Vuelve a copiar los archivos del proyecto al corpus congelado. Invalida
    # la comparacion con medidas anteriores, por eso hay que pedirlo.
    [switch]$RefrescarCorpus,
    # Enciende el razonamiento. Se mide acierto Y tiempo: si acierta mas pero
    # tarda el doble, la decision cambia segun el trabajo.
    [switch]$Pensar
)
$ErrorActionPreference = 'Stop'

$LLAMA = 'F:\ai\llama.cpp\llama-server.exe'

# El 35B es un MoE que NO cabe en VRAM y paga --n-cpu-moe; el 8B es denso y cabe
# entero. Los argumentos de cada uno son los de su despliegue real: los del 35B
# salen de rice-llm.ps1 tal cual se usa hoy.
# `exe` es opcional: sin el se usa $LLAMA, nuestra compilacion b11056. Bonsai
# necesita OTRO binario -- el fork de PrismML -- porque sus pesos ternarios
# usan una transformada Walsh-Hadamard que no esta en upstream. Su propia ficha
# avisa de que llama.cpp normal "carga Q2_0 sin avisar y produce basura", asi
# que el fork NO sustituye al nuestro: convive al lado.
#
# Comprobado antes de descargar nada: el fork tiene --cache-ram, --load-mode,
# --n-cpu-moe, --flash-attn y --mmproj, o sea que la comparacion es limpia y no
# hay que medir a Bonsai con banderas distintas.
$CONFIG = @{
    '35b' = @{
        gguf  = 'F:\ai\models\Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf'
        extra = @('--n-cpu-moe', '28')
        # Qwen3.6 razona por defecto y la respuesta llega en reasoning_content.
        # Sin apagarlo, `content` vuelve vacio y la prueba mide el vacio.
        pensar = $false
    }
    '8b'  = @{
        gguf  = 'F:\ai\models\qwen3-vl-8b\Qwen3-VL-8B-Instruct-Q8_0.gguf'
        extra = @()
        pensar = $false
    }
    'bonsai' = @{
        gguf  = 'F:\ai\models\bonsai-2-27b\Ternary-Bonsai-2-27B-PQ2_0.gguf'
        exe   = 'F:\ai\llama.cpp-prism\llama-server.exe'
        extra = @()
        pensar = $false
    }
}

function Servidor-Vivo {
    try { (Invoke-RestMethod "http://127.0.0.1:$Puerto/health" -TimeoutSec 2).status -eq 'ok' } catch { $false }
}

# El proceso que escucha en NUESTRO puerto. Devuelve uno o nada, nunca un array.
function Mi-Servidor {
    $c = Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" -EA SilentlyContinue |
         Where-Object { $_.CommandLine -match "--port\s+$Puerto\b" } | Select-Object -First 1
    if ($c) { Get-Process -Id $c.ProcessId -EA SilentlyContinue }
}

function Parar-Servidor {
    Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -ErrorAction SilentlyContinue
    $t = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-Process llama-server -ErrorAction SilentlyContinue) -and $t.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 300 }
    Start-Sleep -Seconds 2
}

function Levantar($clave) {
    Parar-Servidor
    $c = $CONFIG[$clave]
    $a = @('--model', $c.gguf, '--ctx-size', "$Ctx", '--n-gpu-layers', '99') + $c.extra + @(
        '--flash-attn', 'on', '--threads', '6', '--parallel', '1',
        '--load-mode', 'none', '--cache-ram', '1024',
        '--port', "$Puerto", '--host', '127.0.0.1')
    $bin = if ($c.exe) { $c.exe } else { $LLAMA }
    if (-not (Test-Path $bin)) { throw "falta el binario $bin" }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Start-Process $bin -ArgumentList $a -WindowStyle Hidden `
        -RedirectStandardError "D:\2026-projects\ojo\banco-$clave.log" `
        -RedirectStandardOutput "D:\2026-projects\ojo\banco-$clave.out" | Out-Null
    while ($sw.Elapsed.TotalSeconds -lt 400) {
        Start-Sleep -Milliseconds 500
        if (Servidor-Vivo) { return [math]::Round($sw.Elapsed.TotalSeconds, 1) }
    }
    throw "$clave no arranco"
}

function Preguntar($clave, $texto, $maxTok = 700, $sistema = $null) {
    $msgs = @()
    if ($sistema) { $msgs += @{ role = 'system'; content = $sistema } }
    $msgs += @{ role = 'user'; content = $texto }

    # FUERA del literal @{...}. Una asignacion dentro de una tabla hash es un
    # error de sintaxis -- "no se permite una clave NULL" -- y el banco murio
    # asi una tanda entera antes de que lo viera.
    #
    # -Pensar enciende el razonamiento en toda la tanda. Es el unico boton que
    # la documentacion de Bonsai destaca ("reasons by default") y nunca lo
    # habiamos medido: se apago desde el principio porque con Qwen3.6 dejaba
    # `content` vacio, pero que sea malo ahi no prueba que lo sea aqui.
    $piensa = if ($Pensar) { $true } else { $CONFIG[$clave].pensar }

    $cuerpo = @{
        model = 'x'; stream = $false; max_tokens = $maxTok; temperature = 0.1
        chat_template_kwargs = @{ enable_thinking = $piensa }
        messages = $msgs
    } | ConvertTo-Json -Depth 8 -Compress
    # Bytes UTF-8: con la cadena, los cuerpos grandes se cortan a medio caracter
    # multibyte y el servidor devuelve parse_error.101.
    $bytes = [Text.Encoding]::UTF8.GetBytes($cuerpo)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod "http://127.0.0.1:$Puerto/v1/chat/completions" -Method Post `
        -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 600
    $sw.Stop()
    @{
        texto   = [string]$r.choices[0].message.content
        ms      = [math]::Round($sw.Elapsed.TotalMilliseconds)
        entrada = $r.usage.prompt_tokens
        salida  = $r.usage.completion_tokens
        tok_s   = if ($r.timings.predicted_per_second) { [math]::Round($r.timings.predicted_per_second, 1) } else { $null }
        ttft_ms = if ($r.timings.prompt_ms) { [math]::Round($r.timings.prompt_ms) } else { $null }
    }
}

# El primer numero de una respuesta, tolerando el separador de millar espanol.
# Hace falta porque los documentos del proyecto escriben "8.192 MiB" y un
# extractor ingenuo sacaria "8" y suspenderia una respuesta correcta.
function Numero($s) {
    if (-not $s) { return $null }
    $t = [regex]::Replace($s, '(?<=\d)[.,](?=\d{3}\b)', '')
    $m = [regex]::Match($t, '\d+')
    if ($m.Success) { $m.Value } else { $null }
}

# Sin tildes y en minusculas, para comparar respuestas. Local a proposito: es
# media docena de lineas y no merece acoplar este archivo con memoria.ps1, que
# ademas trae su propio bloque param() y pisaria variables al cargarlo.
function SinTildes([string]$s) {
    if (-not $s) { return '' }
    $d = $s.ToLower().Normalize([Text.NormalizationForm]::FormD)
    -join ($d.ToCharArray() | Where-Object {
        [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
}

function Limpiar($s) {
    if (-not $s) { return '' }
    # Los modelos envuelven en ```lo-que-sea pase lo que pase en el prompt.
    ($s -replace '(?s)```[a-zA-Z]*\r?\n?', '' -replace '```', '').Trim()
}

# ---------------------------------------------------------------------------
# LAS PRUEBAS. Cada una devuelve @{ ok = $true/$false; detalle = '...' } y el
# script la comprueba sola. Nada se juzga a ojo.
# ---------------------------------------------------------------------------

# 1. REGEX que se ejecuta contra cadenas reales. Se comprueba que acierte en las
#    que debe y que NO acierte en las que no -- una regex demasiado glotona
#    (.*) pasaria la mitad de la prueba y hay que cazarla.
function P-Regex($clave) {
    $r = Preguntar $clave @'
Devuelve SOLO una expresion regular de .NET, sin explicacion, sin comillas y sin
bloque de codigo. Debe capturar en el grupo 1 el numero de compilacion de lineas
como esta:

version: 0.4.1-dev (build 11056, commit e613ef2c8)

Debe funcionar tambien si el numero tiene otra cantidad de digitos. NO debe
coincidir con lineas que no contengan la palabra build.
'@ 300
    $pat = (Limpiar $r.texto) -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1
    $pat = $pat.Trim().Trim('"', "'", '/')
    $debe = @(
        @{ s = 'version: 0.4.1-dev (build 11056, commit e613ef2c8)'; esp = '11056' }
        @{ s = 'version: 1.2.3 (build 7, commit abc)';               esp = '7' }
    )
    $nodebe = @('version: 0.4.1-dev (commit e613ef2c8)', 'no hay nada aqui')
    try {
        $re = [regex]::new($pat)
        foreach ($d in $debe) {
            $m = $re.Match($d.s)
            if (-not $m.Success -or $m.Groups[1].Value -ne $d.esp) {
                return @{ ok = $false; detalle = "fallo en '$($d.s)' -> '$($m.Groups[1].Value)'"; r = $r }
            }
        }
        foreach ($n in $nodebe) {
            if ($re.IsMatch($n)) { return @{ ok = $false; detalle = "coincide con lo que no debe: '$n'"; r = $r } }
        }
        @{ ok = $true; detalle = $pat; r = $r }
    } catch { @{ ok = $false; detalle = "regex invalida: $pat"; r = $r } }
}

# 2. CODIGO QUE SE EJECUTA. Se filtra antes con una lista negra: esto corre en
#    la maquina del usuario y un modelo puede escribir cualquier cosa.
function P-Codigo($clave) {
    $r = Preguntar $clave @'
Devuelve SOLO codigo PowerShell, sin explicacion y sin bloque de codigo. El
codigo debe imprimir con Write-Output un unico numero: la suma de todos los
numeros primos menores que 100. Calculalo con un bucle, no lo escribas a mano.
'@ 500
    $cod = Limpiar $r.texto
    $prohibido = 'Remove-|Invoke-WebRequest|Invoke-RestMethod|Invoke-Expression|iex |Start-Process|Set-Content|Out-File|New-Item|Stop-|rm |del |Format-Volume|Registry|net user'
    if ($cod -match $prohibido) { return @{ ok = $false; detalle = 'codigo rechazado por la lista negra'; r = $r } }
    $tmp = Join-Path $env:TEMP "banco-$clave-$(Get-Random).ps1"
    [IO.File]::WriteAllText($tmp, $cod, [Text.UTF8Encoding]::new($false))
    try {
        $sal = & powershell -NoProfile -ExecutionPolicy Bypass -File $tmp 2>&1 | Out-String
        $num = ($sal -split '\s+' | Where-Object { $_ -match '^\d+$' } | Select-Object -Last 1)
        # 1060 es la suma real de los primos < 100. Comprobado aparte.
        @{ ok = ($num -eq '1060'); detalle = "imprimio '$num', esperado 1060"; r = $r }
    } catch { @{ ok = $false; detalle = "el codigo reventó: $_"; r = $r }
    } finally { if (Test-Path $tmp) { [IO.File]::Delete($tmp) } }
}

# 3. JSON CON ESQUEMA sobre un texto REAL del proyecto. Se parsea y se comprueban
#    los valores contra lo que de verdad dice el archivo.
function P-Json($clave) {
    $fuente = @'
| | 35B Q3_K_XL | 8B Q8_0 |
|---|---|---|
| RAM tras las consultas | 10.454 MB | 2.409 MB |
| carga desde NVMe | 14,7 s | 5,1 s |
| aciertos de control | 3/4 | 4/4 |
'@
    $r = Preguntar $clave @"
De esta tabla, devuelve SOLO un objeto JSON, sin texto alrededor y sin bloque de
codigo, con exactamente estas claves y valores numericos (sin unidades, el punto
de millar quitado, la coma decimal como punto):

{"ram_35b_mb": 0, "ram_8b_mb": 0, "carga_35b_s": 0, "carga_8b_s": 0}

Tabla:
$fuente
"@ 300
    $t = Limpiar $r.texto
    $i = $t.IndexOf('{'); $j = $t.LastIndexOf('}')
    if ($i -lt 0 -or $j -le $i) { return @{ ok = $false; detalle = 'no devolvio JSON'; r = $r } }
    try { $o = $t.Substring($i, $j - $i + 1) | ConvertFrom-Json } catch { return @{ ok = $false; detalle = 'JSON no parsea'; r = $r } }
    $esp = @{ ram_35b_mb = 10454; ram_8b_mb = 2409; carga_35b_s = 14.7; carga_8b_s = 5.1 }
    $mal = @()
    foreach ($k in $esp.Keys) {
        $v = $o.$k
        if ($null -eq $v -or [math]::Abs([double]$v - $esp[$k]) -gt 0.05) { $mal += "$k=$v (esperado $($esp[$k]))" }
    }
    $det = 'las cuatro claves correctas'
    if ($mal) { $det = $mal -join '; ' }
    @{ ok = ($mal.Count -eq 0); detalle = $det; r = $r }
}

# 4. EXTRACCION de un archivo REAL del equipo. La respuesta esta en el texto y
#    es un numero unico: o lo saca o no.
function P-Extraccion($clave) {
    $ini = Get-Content 'F:\ai\presets.ini' -Raw
    $r = Preguntar $clave @"
Aqui tienes un archivo de configuracion real. Responde SOLO con un numero, sin
explicacion: cuantas capas de expertos van a la RAM en el preset [qwen-32k]?

$ini
"@ 200
    $num = Numero (Limpiar $r.texto)
    @{ ok = ($num -eq '32'); detalle = "dijo '$num', esperado 32"; r = $r }
}

# 5. SEGUIR UNA INSTRUCCION EN ESPANOL con forma comprobable. Tres lineas, sin
#    vinetas, y en espanol de verdad (se busca acentuacion o enes).
function P-Espanol($clave) {
    $r = Preguntar $clave @'
Explica que es la memoria VRAM. Responde en espanol, en EXACTAMENTE tres lineas.
Sin vinetas, sin numeracion, sin lineas en blanco, sin titulo.
'@ 400
    $ls = @((Limpiar $r.texto) -split "`r?`n" | Where-Object { $_.Trim() })
    $vinetas = @($ls | Where-Object { $_.Trim() -match '^([-*•]|\d+[\.\)])\s' }).Count
    $esp = ((Limpiar $r.texto) -match '[áéíóúñÁÉÍÓÚÑ]')
    $ok = ($ls.Count -eq 3 -and $vinetas -eq 0 -and $esp)
    @{ ok = $ok; detalle = "$($ls.Count) lineas, $vinetas con vineta, espanol=$esp"; r = $r }
}

# Los cuatro archivos del corpus, en el orden en que se leen. Se comparte entre
# todas las pruebas de diagnostico para que la UNICA diferencia entre ellas sea
# lo que se quiere medir.
# EL CORPUS ESTA CONGELADO, y no es un capricho.
#
# Antes apuntaba a los archivos VIVOS del proyecto, incluido MEDICIONES.md --
# que es justo donde escribo los resultados. Cada vez que documentaba una
# medicion, el corpus de la siguiente crecia. Se noto cuando d_conflicto_cur
# paso de 14.089 a 24.271 fichas y reviento el contexto: mismo archivo, mismo
# dia, un 72% mas grande.
#
# La consecuencia es peor que el error en si: dos modelos medidos a horas
# distintas NO son comparables, porque el texto no era el mismo. Un banco cuyo
# contenido cambia mientras lo usas no mide nada.
#
# banco-corpus\ es una copia tomada una vez. Se refresca a proposito con
# -RefrescarCorpus, y entonces las medidas viejas dejan de comparar con las
# nuevas -- por eso hay que pedirlo, no pasa solo.
$CORPUS_DIR = 'D:\2026-projects\ojo\banco-corpus'
$CORPUS_ORIGEN = @(
    'D:\2026-projects\ojo\MEDICIONES.md'
    'C:\Users\obisp\.config\rice-llm.ps1'
    'F:\ai\presets.ini'
    'D:\2026-projects\ojo\README.md'
)

# Tope de caracteres por archivo al congelar.
#
# MEDICIONES.md ya va por 50.322 caracteres y crece cada vez que documento
# algo; sin tope, el corpus pasaria de los 64.000 originales a 76.990 y las
# pruebas de contexto largo dejarian de caber donde cabian.
#
# Se recorta por el PRINCIPIO, que es donde estan las secciones viejas y
# estables: las respuestas que buscan las pruebas (8192, 18, 4) viven ahi.
# Recortar por el final se llevaria justo lo que hay que encontrar.
$CORPUS_TOPE = @{ 'MEDICIONES.md' = 37000 }   # el resto entra entero

function Congelar-Corpus {
    New-Item -ItemType Directory -Force $CORPUS_DIR | Out-Null
    foreach ($o in $CORPUS_ORIGEN) {
        if (-not (Test-Path $o)) { continue }
        $nom = Split-Path $o -Leaf
        $txt = Get-Content $o -Raw
        $tope = $CORPUS_TOPE[$nom]
        if ($tope -and $txt.Length -gt $tope) { $txt = $txt.Substring(0, $tope) }
        [IO.File]::WriteAllText((Join-Path $CORPUS_DIR $nom), $txt, [Text.UTF8Encoding]::new($false))
    }
    $n = (Get-ChildItem $CORPUS_DIR -File | Measure-Object Length -Sum).Sum
    Write-Host ("corpus congelado: {0:N0} chars (~{1:N0} fichas)" -f $n, ($n / 4))
}

if ($RefrescarCorpus -or -not (Test-Path $CORPUS_DIR)) { Congelar-Corpus }

# Orden fijo por nombre: importa para la cache de prefijo y para d_orden, y no
# se puede depender de como los devuelva el sistema de archivos.
$CORPUS = @('MEDICIONES.md', 'rice-llm.ps1', 'presets.ini', 'README.md') |
    ForEach-Object { Join-Path $CORPUS_DIR $_ } | Where-Object { Test-Path $_ }

function Documento([string[]]$archivos) {
    $t = @()
    foreach ($f in $archivos) { if (Test-Path $f) { $t += "===== $f =====`n" + (Get-Content $f -Raw) } }
    $t -join "`n`n"
}

# 6. CONTEXTO LARGO con material REAL: se concatenan archivos del proyecto hasta
#    pasar de 8.000 tokens y se pregunta por un dato que solo aparece dentro.
function P-ContextoLargo($clave) {
    $doc = Documento $CORPUS
    $r = Preguntar $clave @"
Aqui van varios archivos de un proyecto. Responde SOLO con un numero, sin
explicacion ni unidades: segun estos documentos, cuantos MiB de RAM reserva
llama-server por defecto para la cache de prompts?

$doc
"@ 200
    $num = Numero (Limpiar $r.texto)
    @{ ok = ($num -eq '8192'); detalle = "dijo '$num', esperado 8192 (entrada: $($r.entrada) tokens)"; r = $r }
}

# 6b. CONTEXTO LARGO, segunda version. La primera pregunta por un numero y en
#     los documentos hay otro numero parecido y plausible (cache-ram = 1024),
#     asi que falla no distinguen "el valor por defecto" de "el valor que usamos
#     nosotros". Esta busca una CADENA unica, sin nada con que confundirla: si
#     un modelo pasa esta y suspende la otra, su problema es el distractor, no
#     leer documentos largos. Distinguirlo cambia la conclusion.
function P-ContextoLargo2($clave) {
    $doc = Documento $CORPUS
    $r = Preguntar $clave @"
Aqui van varios archivos de un proyecto. Responde SOLO con el nombre exacto de
la bandera, sin explicacion: segun estos documentos, que bandera de Windows
esconde una ventana de TODAS las tuberias de captura, incluida
Windows.Graphics.Capture?

$doc
"@ 200
    $t = (Limpiar $r.texto).ToUpper()
    @{ ok = ($t -match 'WDA_EXCLUDEFROMCAPTURE'); detalle = "dijo '$((Limpiar $r.texto).Trim())' (entrada: $($r.entrada) tokens)"; r = $r }
}

# ===========================================================================
# DIAGNOSTICO: por que falla `contexto_largo`.
#
# El 8B suspende esa prueba 0/3 y aprueba `contexto_largo2` 3/3 con el mismo
# documento. La diferencia es que la primera tiene un CANDIDATO RIVAL: pregunta
# por el valor POR DEFECTO de cache-ram (8192) y en el texto aparece 14 veces el
# valor que usamos nosotros (1024), contra 9 del correcto.
#
# Eso encaja con cuatro explicaciones distintas y cada una lleva a una solucion
# distinta, asi que hay que separarlas antes de construir nada:
#
#   d_corto      los dos valores en ~500 tokens. Si falla aqui, no es el ruido
#                ni la longitud: es que no distingue, y limpiar el contexto NO
#                lo arregla.
#   d_curado     el mismo documento SIN el archivo del distractor. Es la
#                hipotesis de la memoria temporal reducida a su minimo.
#   d_invertido  se le pide el valor que USAMOS (1024). Si tambien dice 1024,
#                no esta leyendo el matiz "por defecto"; si acierta, lo lee y
#                pierde contra la frecuencia.
#   d_orden      el mismo documento al reves, por si es posicion.
#   d_patron1-3  tres pares "por defecto contra el nuestro" distintos. Si los
#                acierta, mi pregunta era mala; si los falla, es un patron.
# ===========================================================================

$PREGUNTA_DEFECTO = @'
Responde SOLO con un numero, sin explicacion ni unidades: segun estos
documentos, cuantos MiB de RAM reserva llama-server POR DEFECTO para la cache
de prompts?
'@

# El distractor vive en presets.ini (cache-ram = 1024, trece veces) y la
# respuesta buena en MEDICIONES.md. Quitar presets.ini es "curar".
$SIN_DISTRACTOR = @('D:\2026-projects\ojo\MEDICIONES.md', 'D:\2026-projects\ojo\README.md')

# La respuesta esperada TIENE que estar en el corpus. Si no, la pregunta no
# tiene respuesta y apuntarle un fallo al modelo es mentir sobre el modelo.
#
# Esto existe porque me paso TRES VECES:
#   - `d_patron1` preguntaba el load-mode por defecto ("auto") y los documentos
#     solo listaban los modos, sin decir cual era el predeterminado. Fallaron
#     los dos modelos, que es la senal.
#   - Dos veces con `n-cpu-moe 18`, que vive solo en rice-llm.ps1, contra un
#     corpus que no lo incluia. Llegue a escribir en MEDICIONES.md que Bonsai
#     "depende del corpus". Era falso.
#
# Cuesta una linea y evita una conclusion equivocada.
function Comprueba-Numero($r, $esperado, $doc = $null) {
    if ($doc) {
        # El separador de millar cuenta: el corpus escribe "8.192" y esperamos
        # "8192". Se compara sobre el texto con los puntos entre digitos fuera.
        $plano = [regex]::Replace($doc, '(?<=\d)[.,](?=\d{3}\b)', '')
        if ($plano -notmatch [regex]::Escape($esperado)) {
            return @{ ok = $false; invalida = $true
                      detalle = "INVALIDA: '$esperado' no aparece en el corpus. La pregunta no tiene respuesta ahi."
                      r = $r }
        }
    }
    $num = Numero (Limpiar $r.texto)
    @{ ok = ($num -eq $esperado); detalle = "dijo '$num', esperado $esperado (entrada: $($r.entrada) tokens)"; r = $r }
}

# Los dos valores en ~500 tokens. Los parrafos son reales, recortados de
# MEDICIONES.md y presets.ini: si el texto fuera inventado no mediria lo mismo.
function P-DCorto($clave) {
    $doc = @'
===== nota sobre la cache de prompts =====
llama-server reserva por defecto 8.192 MiB de RAM del sistema para la cache de
prompts (-cram, --cache-ram N). Nunca la pusimos. El log la muestra llena y
desalojando sin parar, con entradas de unos 220 MiB. Esa cache es lo que hace
funcionar el pre-calentamiento, asi que no se apaga: se dimensiona.

===== extracto de presets.ini =====
[qwen-8k]
ctx-size = 8192
n-cpu-moe = 24
parallel = 1
load-mode = none
cache-ram = 1024

[qwen-16k]
ctx-size = 16384
n-cpu-moe = 28
parallel = 1
load-mode = none
cache-ram = 1024
'@
    Comprueba-Numero (Preguntar $clave "$PREGUNTA_DEFECTO`n`n$doc" 200) '8192'
}

function P-DLargo($clave)  { $d = Documento $CORPUS; Comprueba-Numero (Preguntar $clave "$PREGUNTA_DEFECTO`n`n$d" 200) '8192' $d }
function P-DCurado($clave) { $d = Documento $SIN_DISTRACTOR; Comprueba-Numero (Preguntar $clave "$PREGUNTA_DEFECTO`n`n$d" 200) '8192' $d }
function P-DOrden($clave)  { $d = Documento ($CORPUS[($CORPUS.Count-1)..0]); Comprueba-Numero (Preguntar $clave "$PREGUNTA_DEFECTO`n`n$d" 200) '8192' $d }

# La misma pregunta del reves: ahora la respuesta correcta ES el valor frecuente.
# Si acierta esta y falla la otra, lee el matiz y pierde contra la frecuencia.
# Si dice 1024 en las dos, el matiz "por defecto" le pasa por encima.
function P-DInvertido($clave) {
    Comprueba-Numero (Preguntar $clave @"
Responde SOLO con un numero, sin explicacion ni unidades: segun estos
documentos, que valor de cache-ram usamos NOSOTROS en nuestros presets?

$(Documento $CORPUS)
"@ 200) '1024'
}

# Tres pares mas del mismo tipo: un valor por defecto que el texto menciona una
# o dos veces, contra el valor nuestro que aparece muchas.
# PRUEBA INVALIDA, se conserva como aviso. Preguntaba cual es el load-mode por
# defecto esperando "auto", y FALLAN LOS DOS MODELOS 0/5. Al revisarlo, los
# documentos solo listan los modos; NUNCA dicen cual es el predeterminado. La
# pregunta no tiene respuesta en el corpus.
#
# Que fallen los dos es la senal de que el problema es la pregunta y no el
# modelo. Sin esa comprobacion habria contado un fallo del 8B que no existe.
# Queda fuera de $PRUEBAS.
function P-DPatron1Invalida($clave) {
    $r = Preguntar $clave @"
Responde SOLO con una palabra, sin explicacion: segun estos documentos, cual es
el modo de carga (load-mode) que llama-server usa POR DEFECTO?

$(Documento $CORPUS)
"@ 200
    $t = (Limpiar $r.texto).ToLower()
    @{ ok = ($t -match '\bauto\b'); detalle = "dijo '$($t.Trim())', esperado auto -- PREGUNTA INVALIDA"; r = $r }
}

# El reemplazo, y prueba la hipotesis de frente: MISMA FORMA que la pregunta que
# falla. Un dato dicho UNA vez en prosa (llama-bench dijo que el optimo era
# --n-cpu-moe 18) contra el mismo nombre de clave repetido en configuracion
# (n-cpu-moe = 24/28/32/34/38/40, seis veces en presets.ini).
#
# Si el 8B tambien falla esta, el patron no es "un distractor cualquiera": es
# que una clave=valor estructurada y repetida le gana a una frase suelta.
function P-DConflicto($clave) {
    $d = Documento $CORPUS
    Comprueba-Numero (Preguntar $clave @"
Responde SOLO con un numero, sin explicacion: segun estos documentos, que valor
de n-cpu-moe dijo llama-bench que era el optimo?

$d
"@ 200) '18' $d
}

# El mismo conflicto, pero quitando presets.ini -- que es donde viven las lineas
# `n-cpu-moe = N`. La respuesta (18) sigue estando, en rice-llm.ps1. Si esto
# acierta, curar el contexto arregla el patron entero y no solo un caso.
function P-DConflictoCurado($clave) {
    $sin = @($CORPUS | Where-Object { $_ -notlike '*presets.ini' })
    $d = Documento $sin
    Comprueba-Numero (Preguntar $clave @"
Responde SOLO con un numero, sin explicacion: segun estos documentos, que valor
de n-cpu-moe dijo llama-bench que era el optimo?

$d
"@ 200) '18' $d
}

function P-DPatron2($clave) {
    # Por defecto CUATRO ranuras; nosotros usamos parallel = 1.
    $r = Preguntar $clave @"
Responde SOLO con un numero, sin explicacion: segun estos documentos, cuantas
ranuras (slots) abre llama-server POR DEFECTO?

$(Documento $CORPUS)
"@ 200
    $t = (Limpiar $r.texto).ToLower()
    $num = Numero $t
    @{ ok = ($num -eq '4' -or $t -match '\bcuatro\b'); detalle = "dijo '$($t.Trim())', esperado 4"; r = $r }
}

function P-DPatron3($clave) {
    # llama.cpp recomienda 1024 tokens de imagen; nuestras capturas dan 939.
    Comprueba-Numero (Preguntar $clave @"
Responde SOLO con un numero, sin explicacion: segun estos documentos, cuantos
tokens de imagen RECOMIENDA llama.cpp como minimo para los modelos Qwen-VL?

$(Documento $CORPUS)
"@ 200) '1024'
}

# HECHOS: conocimiento que el modelo trae de fabrica, SIN documentos delante.
#
# Nace de un fallo concreto: Bonsai contesto "La capital de Peru es Lima, que no
# es cruzada por ningun rio importante". Coherente y falsa -- el Rimac la cruza.
#
# La pregunta que esto responde es CUAL DE DOS CAUSAS es, porque llevan a
# soluciones opuestas:
#
#   fallan los tres   -> no es la cuantizacion; solo buscar en internet arregla
#   falla solo uno    -> su cuantizacion borro conocimiento
#   aciertan todos    -> fue una respuesta suelta y no hay nada que arreglar
#
# Las respuestas se comprueban por palabra clave y no por igualdad: la frase
# puede venir de mil formas y lo que importa es si el dato esta. Se piden
# respuestas de una linea para que no haya sitio donde esconderse.
$HECHOS = @(
    @{ q = 'Que rio cruza la ciudad de Lima, en Peru?';                  esp = 'rimac' }
    @{ q = 'Cual es la capital de Australia?';                           esp = 'canberra' }
    @{ q = 'Cuantos huesos tiene el cuerpo humano adulto?';              esp = '206' }
    @{ q = 'En que anio llego el primer hombre a la Luna?';              esp = '1969' }
    @{ q = 'Que elemento quimico tiene el simbolo W?';                   esp = 'wolframio|tungsteno' }
    @{ q = 'Cual es el lago mas profundo del mundo?';                    esp = 'baikal' }
    @{ q = 'Quien escribio Cien anios de soledad?';                      esp = 'marquez' }
    @{ q = 'Cual es la montania mas alta de America del Sur?';           esp = 'aconcagua' }
    @{ q = 'Cuantos lados tiene un icosagono?';                          esp = '20|veinte' }
    @{ q = 'En que oceano esta la fosa de las Marianas?';                esp = 'pacifico' }
)

function P-Hechos($clave) {
    $bien = 0; $mal = @()
    foreach ($h in $HECHOS) {
        $r = Preguntar $clave "$($h.q) Responde en UNA sola linea, sin explicacion." 120
        $t = SinTildes (Limpiar $r.texto)
        if ($t -match $h.esp) { $bien++ } else { $mal += "$($h.esp): '$($r.texto.Trim())'" }
    }
    $det = "$bien/$($HECHOS.Count)"
    if ($mal) { $det += '  fallo -> ' + ($mal[0..([Math]::Min(1, $mal.Count - 1))] -join ' | ') }
    @{ ok = ($bien -eq $HECHOS.Count); detalle = $det; r = $r }
}

# 7. VELOCIDAD con una generacion larga y fija. Es la unica prueba sin acierto:
#    solo tok/s y tiempo hasta el primer token.
function P-Velocidad($clave) {
    $r = Preguntar $clave 'Escribe un parrafo largo, de unas 300 palabras, sobre la historia del ferrocarril en Peru.' 600
    @{ ok = ($r.salida -gt 100); detalle = "$($r.salida) tokens a $($r.tok_s) tok/s"; r = $r }
}

$PRUEBAS = [ordered]@{
    'regex'          = ${function:P-Regex}
    'codigo'         = ${function:P-Codigo}
    'json'           = ${function:P-Json}
    'extraccion'     = ${function:P-Extraccion}
    'espanol'        = ${function:P-Espanol}
    'contexto_largo' = ${function:P-ContextoLargo}
    'contexto_largo2' = ${function:P-ContextoLargo2}
    'd_corto'         = ${function:P-DCorto}
    'd_largo'         = ${function:P-DLargo}
    'd_curado'        = ${function:P-DCurado}
    'd_invertido'     = ${function:P-DInvertido}
    'd_orden'         = ${function:P-DOrden}
    'd_conflicto'     = ${function:P-DConflicto}
    'd_conflicto_cur' = ${function:P-DConflictoCurado}
    'd_patron2'       = ${function:P-DPatron2}
    'd_patron3'       = ${function:P-DPatron3}
    'hechos'         = ${function:P-Hechos}
    'velocidad'      = ${function:P-Velocidad}
}

# ---------------------------------------------------------------------------

# Con `pwsh -File`, los argumentos llegan como TEXTO PLANO sin interpretar: una
# lista escrita `-Solo regex,contexto_largo` entra como UNA sola cadena con una
# coma dentro, no como dos elementos. Se parte aqui para que funcione igual
# llamando con -File que con -Command.
$Solo = @($Solo | ForEach-Object { $_ -split ',' } | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
$Modelos = @($Modelos | ForEach-Object { $_ -split ',' } | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })

if ($Solo.Count) {
    $sel = [ordered]@{}
    foreach ($k in @($PRUEBAS.Keys)) {
        if ($Solo -contains [string]$k) { $sel[[string]$k] = $PRUEBAS[$k] }
    }
    if (-not $sel.Count) { throw "ninguna prueba se llama asi. Hay: $($PRUEBAS.Keys -join ', ')" }
    $PRUEBAS = $sel
}

$todo = [ordered]@{}
foreach ($m in $Modelos) {
    Write-Host "`n=== $m ===" -ForegroundColor Cyan
    $carga = Levantar $m
    Start-Sleep -Seconds 2
    # EL MIO, por puerto, no "cualquier llama-server".
    #
    # Con dos servidores vivos -- el de ojo en el 8099 y uno huerfano de una
    # tanda anterior -- `Get-Process llama-server` devuelve un ARRAY, y dividir
    # un array revienta con "Object[] no contiene op_Division". Se llevo una
    # tanda entera. Es el mismo fallo que ya tenia `rice-llm.ps1` en su `Alive`.
    $proc = Mi-Servidor
    $vram = [int](((& nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits) -split "`n")[0])

    $res = [ordered]@{
        carga_s  = $carga
        ram_mb   = if ($proc) { [int]($proc.WorkingSet64 / 1mb) } else { -1 }
        vram_mib = $vram
        pruebas  = [ordered]@{}
    }
    foreach ($nombre in $PRUEBAS.Keys) {
        $aciertos = 0; $ms = @(); $toks = @(); $ult = $null
        foreach ($v in 1..$Vueltas) {
            $x = & $PRUEBAS[$nombre] $m
            if ($x.ok) { $aciertos++ }
            $ms += $x.r.ms; if ($x.r.tok_s) { $toks += $x.r.tok_s }
            $ult = $x
        }
        $res.pruebas[$nombre] = [ordered]@{
            aciertos = "$aciertos/$Vueltas"
            ms       = [int](($ms | Measure-Object -Average).Average)
            tok_s    = if ($toks) { [math]::Round(($toks | Measure-Object -Average).Average, 1) } else { $null }
            detalle  = $ult.detalle
        }
        # INVALIDA se distingue de FALLA a proposito: una pregunta sin respuesta
        # en el corpus no dice nada del modelo, y confundirlas ya me llevo a
        # escribir una conclusion falsa en MEDICIONES.md.
        $marca = if ($ult.invalida) { 'INVAL' }
                 elseif ($aciertos -eq $Vueltas) { 'ok  ' }
                 elseif ($aciertos -eq 0) { 'FALLA' }
                 else { 'medio' }
        Write-Host ("  {0,-6} {1,-15} {2,6} ms  {3}" -f $marca, $nombre, $res.pruebas[$nombre].ms, $ult.detalle)
    }
    # RAM despues de trabajar, que es la que importa: la cache de prompts se
    # llena con el uso, no al arrancar.
    $pf = Mi-Servidor
    $res.ram_mb_final = if ($pf) { [int]($pf.WorkingSet64 / 1mb) } else { -1 }
    $todo[$m] = $res
}
Parar-Servidor

$todo | ConvertTo-Json -Depth 8 | Set-Content $Salida -Encoding utf8

Write-Host "`n=== RESUMEN ===" -ForegroundColor Cyan
$fila = "{0,-16}" -f 'prueba'
foreach ($m in $Modelos) { $fila += "{0,-22}" -f $m }
Write-Host $fila
foreach ($n in $PRUEBAS.Keys) {
    $fila = "{0,-16}" -f $n
    foreach ($m in $Modelos) {
        $p = $todo[$m].pruebas[$n]
        $fila += "{0,-22}" -f ("$($p.aciertos)  $($p.ms) ms")
    }
    Write-Host $fila
}
foreach ($k in 'carga_s', 'ram_mb', 'ram_mb_final', 'vram_mib') {
    $fila = "{0,-16}" -f $k
    foreach ($m in $Modelos) { $fila += "{0,-22}" -f $todo[$m].$k }
    Write-Host $fila
}
Write-Host "`nresultados en $Salida"

