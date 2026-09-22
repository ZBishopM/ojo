# Ojo, el bucle funcional: captura -> modelo -> dibujo en pantalla.
#
# Todavia sin voz: la pregunta se escribe. STT y TTS son las fases C y D. Esto
# existe para probar lo arriesgado -- si el modelo acierta DONDE estan las cosas
# -- antes de montar nada encima.
#
#   .\ojo.ps1 "donde esta el boton de exportar?"
#   .\ojo.ps1 "que aplicacion es esta?" -Segundos 12
#   .\ojo.ps1 -Servidor            solo levanta llama-server y sale
#
# El overlay se lanza como proceso hijo en modo --servir y se le mandan escenas
# JSON por stdin, una por linea.
param(
    [Parameter(Position = 0)][string]$Pregunta = 'Que hay en esta pantalla?',
    [int]$Puerto = 8099,
    [int]$Segundos = 15,
    [switch]$Servidor,
    # Solo para PROBAR: mira los controles de esa ventana en vez de la activa.
    # Lanzado desde una consola, la ventana activa es la consola y no tiene nada.
    [string]$Ventana,
    # Apaga UIA entero -- ni lista ni enganche. Para medir el punto de partida.
    [switch]$SinUia,
    # Apaga las memorias temporales, para medir cuanto aportan.
    [switch]$SinMemoria,
    # Carga esa memoria a la fuerza, sin puntuar. Para cuando el selector duda
    # entre dos y no hay nadie delante para contestarle.
    [string]$Memoria,
    # Quita la lista del prompt. Con -Enganchar da la tercera via: cero tokens
    # de contexto, y el modelo solo tiene que acertar la zona.
    [switch]$SinLista,
    # Engancha la coordenada del modelo al control real mas cercano.
    #
    # APAGADO POR DEFECTO, y esto es un resultado medido, no una precaucion.
    # Sobre Discord convirtio "0,98 0,02" -- un fallo de medio pantalla -- en
    # "el boton Minimizar", que es una respuesta equivocada pero con pinta de
    # segura. El enganche no sabe distinguir "fallo por poco" de "fallo de
    # sitio", y sin esa senal empeora: un punto vago se ve vago, un rectangulo
    # verde sobre Minimizar parece correcto. En modo agente eso pulsaria.
    #
    # Se queda el codigo porque con un modelo que acierte la zona de forma
    # fiable, esto da precision exacta gratis. Hay que volver a medirlo.
    [switch]$Enganchar,
    [string]$Raiz = 'D:\2026-projects\ojo',
    # Cuantos controles se le ofrecen. Discord tiene 144: con 40 se quedaba
    # fuera el cuadro de busqueda. Medir antes de subirlo, cada uno son tokens.
    [int]$MaxControles = 40,
    # MiB de RAM para la cache de prompts del servidor. El defecto de
    # llama-server son 8.192 y es la mayor fuga de RAM que teniamos.
    [int]$CacheRam = 1024,
    # Que modelo servir. El 8B es el predeterminado desde que se midio: gana en
    # las cuatro columnas -- 4/4 aciertos contra 3/4, la mitad de latencia, 1,2
    # GB de RAM contra 10,5, y carga en 5 s en vez de 15. El 35B se queda para
    # poder repetir la comparacion.
    [ValidateSet('35b', '8b', 'bonsai', '4b-texto')][string]$Modelo = '8b'
)
$ErrorActionPreference = 'Stop'

# UTF-8 para lo que escriben los procesos hijos.
#
# `ojo-uia` emite JSON en UTF-8, pero PowerShell 5.1 decodifica la salida de un
# proceso con la pagina de codigos de la consola (aqui cp850/cp1252). El
# resultado: "Línea arriba" llegaba como "L├¡nea arriba", y ese nombre roto iba
# tanto al modelo como al dibujo. Se vio en la sesion del 2026-09-21.
#
# Aparte, un .ps1 en UTF-8 SIN BOM lo lee 5.1 como ANSI, y por eso
# "Déjame ver…" salia con simbolos raros en el overlay. Estos archivos llevan
# BOM desde entonces.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$captura = "$Raiz\captura\target\release\ojo-captura.exe"
$overlay = "$Raiz\overlay\target\release\ojo-overlay.exe"
$uia     = "$Raiz\uia\target\release\ojo-uia.exe"
$llama   = 'F:\ai\llama.cpp\llama-server.exe'

# Los dos modelos, con la diferencia que importa: el 35B no cabe en VRAM (16,8
# GB contra 12,28) y necesita --n-cpu-moe, que deja 24 capas de expertos en RAM
# usandose en cada token. El 8B a Q8_0 son 8,11 + 1,08 de mmproj y entra entero:
# sin reparto, la RAM se queda en poco mas que la cache de prompts.
$MODELOS = @{
    '35b' = @{
        gguf   = 'F:\ai\models\Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf'
        mmproj = 'F:\ai\models\mmproj-F16.gguf'
        extra  = @('--n-cpu-moe', '24')
    }
    # MARGEN, no solo "que quepa". Medido el 2026-09-22: con ~300 MiB libres,
    # basta con que Firefox o Discord crezcan un poco para que Windows desaloje
    # parte del modelo a RAM, y el 8B pasa de 43 a 4,4 tok/s -- reproducido
    # robandole 1,4 GB con otro proceso. Se recupera solo, pero tarda.
    #
    #   -ctk/-ctv q8_0   KV de 1.152 a 612 MiB. Misma velocidad (50,8 tok/s)
    #                    y mismo banco de vision (4/5 leer, 2/6 senalar).
    #   --no-warmup      el calentamiento reserva la vision para una imagen de
    #                    1472x1472; nuestras capturas son de 1280x720. Sin el,
    #                    el bufer baja de 372 a 162 MiB. Mismo banco.
    #
    # `--image-max-tokens 1024` se probo y no cambia nada: el bufer lo fija el
    # calentamiento, no el tope.
    '8b'  = @{
        gguf   = 'F:\ai\models\qwen3-vl-8b\Qwen3-VL-8B-Instruct-Q8_0.gguf'
        mmproj = 'F:\ai\models\qwen3-vl-8b\mmproj-F16.gguf'
        extra  = @('-ctk', 'q8_0', '-ctv', 'q8_0', '--no-warmup')
    }
    # Bonsai necesita OTRO binario: sus pesos ternarios usan una transformada
    # Walsh-Hadamard que no esta en upstream. Su propia ficha avisa de que
    # llama.cpp normal "carga Q2_0 sin avisar y produce basura", asi que el
    # fork convive al lado y no sustituye al nuestro.
    'bonsai' = @{
        gguf   = 'F:\ai\models\bonsai-2-27b\Ternary-Bonsai-2-27B-PQ2_0.gguf'
        mmproj = 'F:\ai\models\bonsai-2-27b\Ternary-Bonsai-2-27B-mmproj-BF16.gguf'
        exe    = 'F:\ai\llama.cpp-prism\llama-server.exe'
        extra  = @()
    }
    # EL PERFIL DE PARTIDA. Sin vision, a proposito.
    #
    # Con un juego delante no caben los dos: el 8B con su mmproj son 11.418 de
    # los 12.282 MiB de la tarjeta, y LoL pide unos 4.600. Cuando se pasa, el
    # driver de Windows NO da error -- desde la 536.40 derrama a RAM del sistema
    # en silencio -- y todo se arrastra. Medido el 2026-09-22: de 47,8 a 6,1
    # tok/s.
    #
    # La salida no es encoger el 8B a Q3, que dejaria un modelo de vision
    # incapaz de senalar un boton. Es que DURANTE LA PARTIDA NO HACE FALTA VER:
    # el juego sirve sus datos en https://127.0.0.1:2999 (ver `lol.ps1`), con
    # los campeones, los items y el oro exactos. Sin vision no hace falta mmproj
    # (1,08 GB) ni un modelo de vision.
    #
    # Y el candidato ya estaba en el disco: es el 4B de voicebox.
    #
    # KV a q8_0 porque cada MiB cuenta aqui; flash-attn ya va puesto abajo, que
    # es lo que la V cuantizada exige.
    '4b-texto' = @{
        gguf   = 'F:\ai\models\Qwen3.5-4B-UD-Q5_K_XL.gguf'
        mmproj = $null
        extra  = @('-ctk', 'q8_0', '-ctv', 'q8_0')
    }
}
# $rutaModelo y no $modelo: PowerShell no distingue mayusculas en los nombres de
# variable, asi que $modelo pisaria el parametro $Modelo -- y como lleva
# [ValidateSet('35b','8b')], asignarle una ruta lanza ValidationMetadataException.
# Segunda vez que pasa en este script; la primera fue $Controles contra
# $controles, que ademas fallaba con un error de conversion de tipo sin relacion
# aparente. Si un parametro tiene tipo o validacion, su nombre queda reservado.
$rutaModelo = $MODELOS[$Modelo].gguf
# Binario por modelo: si la entrada no trae 'exe', se usa el nuestro (b11056).
$llama      = if ($MODELOS[$Modelo].exe) { $MODELOS[$Modelo].exe } else { $llama }
$mmproj     = $MODELOS[$Modelo].mmproj
$extra      = $MODELOS[$Modelo].extra

# $mmproj puede ser $null: el perfil de partida no lleva vision. Sin el filtro,
# Test-Path con cadena vacia revienta antes de llegar al modelo.
foreach ($f in @($captura, $overlay, $uia, $llama, $rutaModelo, $mmproj | Where-Object { $_ })) {
    if (-not (Test-Path $f)) { throw "falta $f" }
}

function Servidor-Vivo {
    try { (Invoke-RestMethod "http://127.0.0.1:$Puerto/health" -TimeoutSec 2).status -eq 'ok' }
    catch { $false }
}

function Levantar-Servidor {
    if (Servidor-Vivo) { Write-Host 'servidor ya levantado'; return }

    # NO arrancar si el 35B del Win+Space esta cargado. No caben los dos:
    # 11,3 + 11,4 GB sobre 12,28. Cuando la VRAM se acaba, CUDA se desborda a
    # memoria compartida por PCIe y los DOS modelos se arrastran -- ya paso, y
    # esta contado en rice-llm.ps1 (generacion a 2 tok/s con 127 MiB libres).
    #
    # Se para y se dice, en vez de arrancar y que el usuario descubra que todo
    # va lento sin saber por que. Es ademas lo que evita que el supervisor lo
    # reintente en bucle cada 30 s con el otro modelo puesto.
    # Catch SIN tipo: `[Microsoft.PowerShell.Commands.HttpResponseException]` es
    # de PowerShell 7 y esto corre en 5.1, donde el tipo no existe y el script
    # muere con TypeNotFound antes de llegar a nada. Se comprueba el resultado
    # en una variable en vez de filtrar por excepcion.
    $hayOtro = $false
    try { $hayOtro = (Invoke-RestMethod 'http://127.0.0.1:8080/health' -TimeoutSec 2).status -eq 'ok' }
    catch { $hayOtro = $false }   # nadie en 8080, que es lo normal
    if ($hayOtro) {
        throw @'
el modelo del Win+Space (35B) esta cargado en el puerto 8080 y no caben los dos
en 12,28 GB de VRAM. Paralo con `rice-llm.ps1 -Stop` y vuelve a intentarlo.
'@
    }

    Write-Host 'levantando llama-server (la primera vez tarda)...'
    $a = @('--model', $rutaModelo) +
         @(if ($mmproj) { '--mmproj', $mmproj }) +
         @('--ctx-size', '8192', '--n-gpu-layers', '99'
    ) + $extra + @(
        # load-mode none = el viejo --no-mmap, que ya no existe en b11056.
        '--flash-attn', 'on', '--threads', '6', '--parallel', '1', '--load-mode', 'none',
        # La cache de prompts vive en RAM DEL SISTEMA y por defecto son 8.192
        # MiB que nunca pedimos. El log mostraba once desalojos seguidos de
        # entradas de ~220 MiB: reservaba para 37 y usabamos 2. Era la mayor
        # parte de los 13,3 GB que dejaron el equipo con 777 MB libres.
        #
        # NO se pone a 0: esta cache ES el pre-calentamiento, 158 ms con ella
        # caliente contra 1.886 ms sin ella. Con 1.024 MiB caben cuatro entradas,
        # mas de lo que hace falta para la pantalla actual.
        '--cache-ram', "$CacheRam",
        '--port', $Puerto, '--host', '127.0.0.1'
    )
    Start-Process $llama -ArgumentList $a -WindowStyle Hidden `
        -RedirectStandardError "$Raiz\llama.log" -RedirectStandardOutput "$Raiz\llama.out" | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 400) {
        Start-Sleep -Milliseconds 500
        if (Servidor-Vivo) { Write-Host ("listo en {0:N0} s" -f $sw.Elapsed.TotalSeconds); return }
    }
    throw 'el servidor no arranco'
}

# Se le pide JSON y nada mas. El esquema ES la separacion showman/funcionario:
# `decir` es lo que se habla, `senalar`/`dibujar` es el trabajo. Un solo modelo,
# una sola llamada, dos responsabilidades que no se mezclan.
$SISTEMA = @'
Eres un asistente que mira la pantalla del usuario y le ayuda. Respondes SIEMPRE
con un unico objeto JSON, sin texto alrededor y sin bloques de codigo.

{"decir": "<una frase corta en espanol, lo que dirias en voz alta>",
 "control": 0,
 "senalar": {"x": 0.0, "y": 0.0},
 "dibujar": [{"tipo":"caja","x":0.0,"y":0.0,"w":0.0,"h":0.0}]}

Reglas:
- Si el mensaje trae una LISTA DE CONTROLES, y el sitio al que quieres apuntar
  esta en ella, responde {"control": N} con su numero EN VEZ de "senalar". Esos
  rectangulos los da el sistema operativo y son exactos; tus coordenadas a ojo
  no lo son. Usa "senalar" solo para lo que NO este en la lista.
- Las coordenadas van NORMALIZADAS de 0 a 1, donde 0,0 es arriba a la izquierda
  y 1,1 abajo a la derecha. Nunca en pixeles.
- "senalar" es opcional: omitelo si la respuesta no apunta a ningun sitio.
- "dibujar" es opcional. Tipos validos: caja, flecha (x1,y1,x2,y2),
  subrayado (x,y,w), paso (x,y,n).
- "decir" es obligatorio, en espanol, y como maximo dos frases.
'@

# Los controles REALES de la ventana activa. Esto es lo que arregla la precision
# fina: el modelo elige de una lista en vez de adivinar un punto. Medido: Qwen
# acierta 52,7% en ScreenSpot-Pro; un rectangulo de UIA acierta el 100% porque no
# es una estimacion, es el dato con el que Windows dibuja el control.
#
# Falla en juegos, en Zed y en cualquier cosa dibujada a mano -- ahi la lista
# viene vacia y el modelo vuelve a "senalar" con sus coordenadas. Por eso las dos
# vias conviven.
function Leer-Controles([int]$Max = 0) {
    if ($SinUia) { return @() }
    if (-not $Max) { $Max = $MaxControles }
    try {
        $a = @('--max', "$Max")
        if ($Ventana) { $a += @('--ventana', $Ventana) }
        $j = & $uia @a 2>$null | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { return @() }
        @($j.controles)
    } catch { @() }
}

# El control que de verdad hay bajo el punto que dio el modelo, si lo hay.
#
# Primero el que lo CONTIENE -- el mas pequeno, porque un boton dentro de una
# barra debe ganar a la barra. Si ninguno lo contiene, el centro mas cercano
# dentro de RADIO. Mas alla de eso el modelo no fallo por poco, fallo de sitio,
# y enganchar seria inventarse una respuesta.
$RADIO = 0.06

function Buscar-Enganche($p) {
    $todos = Leer-Controles -Max 300
    if (-not $todos.Count) { return $null }
    $x = $p[0]; $y = $p[1]

    $dentro = $todos | Where-Object {
        $x -ge ($_.x - $_.w / 2) -and $x -le ($_.x + $_.w / 2) -and
        $y -ge ($_.y - $_.h / 2) -and $y -le ($_.y + $_.h / 2)
    } | Sort-Object { $_.w * $_.h }
    if ($dentro) { return $dentro[0] }

    $cerca = $todos | ForEach-Object {
        [pscustomobject]@{ c = $_; d = [Math]::Sqrt([Math]::Pow($_.x - $x, 2) + [Math]::Pow($_.y - $y, 2)) }
    } | Sort-Object d | Select-Object -First 1
    if ($cerca.d -le $RADIO) { $cerca.c } else { $null }
}

# Las memorias temporales. Solo entran los titulares y el cuerpo de lo que el
# selector decida cargar; nunca los archivos crudos.
#
# Esto NO es una optimizacion de contexto: es el arreglo de un fallo medido. El
# 8B se equivoca cuando en el contexto hay otro valor asignado a la misma clave
# por la que se pregunta (0/5 en tres casos). Con una nota corta de un solo
# tema, 5/5. El detalle esta en MEDICIONES.md.
# Se carga CON PUNTO, no como proceso hijo. Lanzarlo con `pwsh` costaba 649 ms
# y casi todo era arrancar el interprete: puntuar ocho titulares es aritmetica.
# `-ComoModulo` hace que memoria.ps1 defina sus funciones y no ejecute nada.
#
# CUIDADO AL CARGARLO CON PUNTO: se ejecuta su bloque `param()` en NUESTRO
# ambito, asi que cada parametro suyo pisa una variable nuestra que se llame
# igual. `memoria.ps1` tiene un `-Pregunta` y borro el nuestro: el modelo
# recibio la cadena vacia y contesto "¿En que puedo ayudarte?".
#
# Cuarta vez que este mismo bug muerde en el proyecto -- antes fueron
# $Controles, $Modelo y $Pruebas. PowerShell no distingue mayusculas y no avisa.
$HAY_MEMORIA = Test-Path "$Raiz\memoria.ps1"
if ($HAY_MEMORIA) {
    $preguntaDelUsuario = $Pregunta
    . "$Raiz\memoria.ps1" -ComoModulo
    $Pregunta = $preguntaDelUsuario
}

function Leer-Memoria($pregunta) {
    if ($SinMemoria -or -not $HAY_MEMORIA) { return @{ texto = ''; cargadas = @() } }
    try {
        $mem = Leer-Memorias "$Raiz\memorias"
        if (-not $mem.Count) { return @{ texto = ''; cargadas = @() } }

        if ($Memoria) {
            $f = $mem | Where-Object { $_.nombre -eq $Memoria } | Select-Object -First 1
            if (-not $f) { throw "no hay ninguna memoria llamada '$Memoria'" }
            $cargadas = @($f.nombre)
        } else {
            $d = Elegir $mem $pregunta
            # Si duda, entran las dos. No se pregunta: el overlay no puede
            # recibir la respuesta y con el atajo de la Fase C no habra terminal.
            $cargadas = switch ($d.accion) {
                'cargar'        { @($d.elegida.nombre) }
                'cargar-varias' { @($d.elegidas.nombre) }
                default         { @() }
            }
        }
        if (-not $cargadas.Count) { return @{ texto = ''; cargadas = @() } }
        $cargadas = Descargar ([pscustomobject]@{ cargadas = $cargadas }) $mem 1500
        @{ texto = "`n`n" + (Componer $mem $cargadas); cargadas = $cargadas }
    } catch {
        Write-Warning "memoria: $_"
        @{ texto = ''; cargadas = @() }
    }
}

# Si la pregunta pide un SITIO o no.
#
# Se probo pedirselo al modelo con una regla en el prompt y salio mal medido:
# las preguntas de conocimiento que se callaban pasaron de 0/5 a 3/5, pero UNA
# de pantalla dejo de apuntar. Decidir cuando callarse es un juicio, y juzgar
# entre opciones parecidas es justo lo que este modelo hace peor.
#
# Asi que lo decide el texto de la pregunta, que es determinista y no tiene un
# mal dia. El modelo sigue proponiendo lo que quiera; aqui solo se descarta.
# NUNCA fuerza a apuntar: solo suprime.
#
# ponytail: lista de marcadores, calibrada con las diez preguntas de
# probar-senalar.ps1. Si aparece una forma de preguntar por un sitio que no
# esta aqui, el sintoma es que deja de apuntar cuando deberia -- se anade el
# marcador y se vuelve a correr probar-senalar.
$MARCAS_SITIO = @(
    'donde', 'dónde', 'ubica', 'situa', 'sitúa', 'senala', 'señala', 'apunta',
    'muestra', 'muestrame', 'muéstrame', 'ensena', 'enseña', 'localiza',
    'resalta', 'marca', 'subraya', 'dibuja', 'en que parte', 'en qué parte',
    'que boton', 'qué botón', 'cual boton', 'cuál botón', 'haz clic', 'pulsa',
    'click', 'clic', 'llevame', 'llévame'
)

function Pregunta-De-Sitio([string]$q) {
    # Normalizar viene de memoria.ps1. Si no esta cargado, minusculas a secas:
    # los marcadores sin tilde siguen cazando la mayoria.
    $n = if (Get-Command Normalizar -ErrorAction SilentlyContinue) { Normalizar $q } else { $q.ToLower() }
    foreach ($m in $MARCAS_SITIO) { if ($n.Contains((Normalizar $m))) { return $true } }
    $false
}

# VRAM libre, en MiB. Devuelve -1 si no se puede leer, que es mejor que romper
# la medicion entera por una herramienta que falta.
#
# POR QUE ESTA COLUMNA EXISTE: la sesion del 2026-09-22 se degrado de 9 s a 222
# s por frase y `sesion.csv` no lo delato. La causa era que Hearthstone arranco
# a media sesion y el driver de Windows, desde la version 536.40, NO da error al
# quedarse sin VRAM: derrama a RAM del sistema por PCIe en silencio. La caida
# publicada es de 5-10x; la nuestra fue de 47,8 a 6,1 tok/s.
#
# Es invisible por diseno. La unica defensa es anotarlo: con esta columna, una
# tanda contaminada se distingue de una limpia con solo mirar el CSV.
function Vram-Libre {
    try {
        $s = (& nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits) 2>$null
        [int](@($s)[0].Trim())
    } catch { -1 }
}

function Preguntar-Modelo($imagen, $pregunta, $controles, $memoria) {
    $b64 = if ($imagen) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($imagen)) } else { $null }
    $lista = ''
    if ($controles.Count) {
        $lineas = $controles | ForEach-Object { "{0}. [{1}] {2}" -f $_.n, $_.tipo, $_.nombre }
        $lista = "`n`nLISTA DE CONTROLES de la ventana activa:`n" + ($lineas -join "`n")
    }
    # Sin imagen -- el perfil de partida -- el mensaje es solo texto. Mandar un
    # `image_url` vacio con un modelo sin mmproj devuelve 500.
    $contenido = @(
        if ($b64) { @{ type = 'image_url'; image_url = @{ url = "data:image/jpeg;base64,$b64" } } }
        @{ type = 'text'; text = ($pregunta + $lista + $memoria) }
    )
    $cuerpo = @{
        model = 'x'; stream = $false; max_tokens = 300; temperature = 0.1
        # Sin esto el modelo razona, `content` sale vacio y se agota el limite
        # de tokens pensando. Medido: 4.465 ms y nada, contra 361 ms y respuesta.
        chat_template_kwargs = @{ enable_thinking = $false }
        messages = @(
            @{ role = 'system'; content = $SISTEMA },
            # LA IMAGEN VA PRIMERO, y no es cosmetico. llama.cpp cachea el
            # PREFIJO del prompt: 1.886 ms con imagen nueva contra 158 ms con la
            # caliente. El pre-calentamiento consiste en mandar la captura en
            # cuanto se pulsa el atajo, mientras el usuario todavia habla. Si la
            # pregunta o la lista de controles fueran delante, cambiarian el
            # prefijo y la imagen se reevaluaria entera: adios a los 158 ms.
            @{ role = 'user'; content = $contenido }
        )
    } | ConvertTo-Json -Depth 8 -Compress
    # BYTES UTF-8, no una cadena. Pasarle la cadena a Invoke-RestMethod partia el
    # cuerpo a medio caracter multibyte y el servidor respondia 500:
    #
    #   parse error at line 1, column 203097: ill-formed UTF-8 byte
    #   last read: '...67. [enlace] L I L K U G A, Blaster\n68. [item] <cortado>'
    #
    # Los nombres de Discord llevan emoji y matematicas Unicode. Se creyo que era
    # desbordamiento de contexto y se documento como tal: falso, el servidor no
    # llego a parsear el JSON, asi que nunca vio un contexto.
    $bytes = [Text.Encoding]::UTF8.GetBytes($cuerpo)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod "http://127.0.0.1:$Puerto/v1/chat/completions" -Method Post `
        -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 300
    $sw.Stop()
    @{ ms = [math]::Round($sw.Elapsed.TotalMilliseconds); texto = $r.choices[0].message.content }
}

# Los modelos envuelven el JSON en ```json pase lo que pase en el prompt, y a
# veces meten una frase antes. Se extrae el primer objeto equilibrado.
function Extraer-Json($s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $s = $s -replace '(?s)^.*?```(?:json)?', '' -replace '(?s)```.*$', ''
    $i = $s.IndexOf('{'); if ($i -lt 0) { return $null }
    $prof = 0
    for ($j = $i; $j -lt $s.Length; $j++) {
        if ($s[$j] -eq '{') { $prof++ }
        elseif ($s[$j] -eq '}') { $prof--; if ($prof -eq 0) { return $s.Substring($i, $j - $i + 1) } }
    }
    $null
}

if ($Servidor) { Levantar-Servidor; return }
Levantar-Servidor

# El overlay se arranca ANTES de preguntar para poder enseñar "mirando..."
# mientras el modelo piensa. Sin eso habria dos segundos de pantalla muerta.
# Matar el overlay de la pregunta ANTERIOR antes de abrir el nuestro.
#
# Cada pregunta abre su propio overlay y lo cierra al acabar, pero con
# `-Segundos 15` el anterior sigue en pantalla si preguntas otra cosa antes.
# Resultado: dos overlays pintando a la vez y los subtitulos superpuestos --
# "genera ruido y se ve sucio", dicho en la sesion del 2026-09-21.
Get-Process 'ojo-overlay' -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue

$psi = [Diagnostics.ProcessStartInfo]::new($overlay, '--servir')
$psi.RedirectStandardInput = $true; $psi.UseShellExecute = $false
$ov = [Diagnostics.Process]::Start($psi)
Start-Sleep -Milliseconds 400

# UTF-8 SIN BOM, con escritor propio sobre el flujo crudo.
#
# Dos razones: el escritor por defecto antepone el BOM al primer WriteLine y
# serde lo ve como basura ("expected value at line 1 column 1"), perdiendo justo
# la escena de "mirando" mientras el modelo piensa. Y `StandardInputEncoding` de
# ProcessStartInfo no existe en PowerShell 5.1, asi que ponerlo ahi rompe el
# script segun con que consola se lance.
$tuberia = New-Object IO.StreamWriter($ov.StandardInput.BaseStream, (New-Object Text.UTF8Encoding $false))
$tuberia.AutoFlush = $true
# El overlay es PRESENTACION. Si la tuberia se rompe -- el proceso murio, la
# escena anterior lo tumbo, lo que sea -- la respuesta ya esta calculada y
# perderla seria absurdo. Con $ErrorActionPreference = 'Stop' un WriteLine
# fallido se llevaba la ejecucion entera por delante y la salida quedaba vacia.
#
# Se vio en un lote de ocho vueltas: cinco sin ninguna salida. No se ha podido
# reproducir en las quince siguientes, asi que la causa exacta sigue sin
# confirmar; esto evita la consecuencia, que es perder el trabajo hecho.
function Escena($o) {
    try { $tuberia.WriteLine(($o | ConvertTo-Json -Depth 8 -Compress)) }
    catch { Write-Warning "el overlay no recibio la escena: $($_.Exception.Message)" }
}

try {
    Escena @{ estado = 'mirando'; oido = $Pregunta; dice = 'Déjame ver…' }

    # ---- Hay partida de League? -------------------------------------------
    #
    # Si la hay, NO se mira la pantalla. El juego sirve sus propios datos en
    # https://127.0.0.1:2999 (ver `lol.ps1`): campeones, items, oro y las dos
    # composiciones, exactos y en milisegundos. Adivinarlos desde una captura
    # es mas lento, gasta el mmproj -- 1,08 GB que con un juego delante no
    # sobran -- y da respuestas que parecen seguras sin serlo.
    #
    # SE MIRA EL PROCESO PRIMERO, y no es una optimizacion prematura: es la
    # diferencia entre 6,9 ms y 2.437 ms EN CADA PREGUNTA.
    #
    # `lol.ps1` sale con codigo 1 cuando no hay partida, asi que llamarlo a
    # secas ya contesta "estas jugando?". Pero llamarlo cuesta arrancar un
    # PowerShell entero -- medido, 2.437 ms -- y se pagaria siempre, tambien
    # las 999 veces de cada 1.000 en que no hay ningun juego abierto. En un
    # sistema cuyo requisito es que no se note el retardo, eso es inaceptable.
    #
    # Get-Process cuesta 6,9 ms y descarta el caso comun. `lol.ps1` solo se
    # lanza cuando el juego esta de verdad ahi.
    $partida = $null
    $hayPartida = $false
    if (Get-Process -Name 'League of Legends', 'LeagueClient' -EA SilentlyContinue) {
        $partida = & powershell -NoProfile -ExecutionPolicy Bypass -File "$Raiz\lol.ps1" 2>$null
        $hayPartida = ($LASTEXITCODE -eq 0) -and $partida
    }

    $tmp = $null
    $tc = [Diagnostics.Stopwatch]::StartNew()
    if (-not $hayPartida) {
        $tmp = Join-Path $env:TEMP 'ojo.jpg'
        & $captura --salida $tmp | Out-Null
    }
    $tc.Stop()

    $tu = [Diagnostics.Stopwatch]::StartNew()
    $controles = if ($SinLista -or $hayPartida) { @() } else { Leer-Controles }
    $tu.Stop()

    $tm = [Diagnostics.Stopwatch]::StartNew()
    $mm = Leer-Memoria $Pregunta
    $tm.Stop()
    $memoria = $mm.texto

    # Los hechos de la partida entran como MEMORIA, que es el mismo canal que ya
    # usan las notas del proyecto: texto al final del mensaje. Asi no hay una
    # via nueva que mantener, y el prefijo del prompt -- que es lo que llama.cpp
    # cachea -- sigue siendo el mismo.
    if ($hayPartida) {
        $memoria += "`n`nDATOS EXACTOS DE LA PARTIDA EN CURSO (te los da el propio juego, no los inventes ni los contradigas):`n$partida"
    }

    # JUSTO ANTES de preguntar, que es cuando la falta de VRAM hace dano. Leerlo
    # despues no vale: para entonces el servidor ya pago el derrame.
    $vramLibre = Vram-Libre
    # 300 MiB: por debajo de eso el derrame ya se midio. No se aborta -- una
    # respuesta lenta sigue siendo una respuesta -- pero queda dicho en el log,
    # que es donde se mira cuando una tanda sale rara.
    if ($vramLibre -ge 0 -and $vramLibre -lt 300) {
        Write-Host "AVISO: solo $vramLibre MiB de VRAM libres. Algo mas esta usando la tarjeta; la respuesta va a ir lenta." -ForegroundColor Yellow
    }

    $r = Preguntar-Modelo $tmp $Pregunta $controles $memoria
    $json = Extraer-Json $r.texto
    if (-not $json) { throw "el modelo no devolvio JSON. Dijo:`n$($r.texto)" }
    $d = $json | ConvertFrom-Json

    # El numero de control gana sobre las coordenadas a ojo: son el mismo dato
    # que usa Windows para dibujar, no una estimacion.
    $punto = $null
    $via = 'nada'
    # Durante la partida NUNCA se senala: no se ha mirado la pantalla, asi que
    # cualquier coordenada que proponga el modelo es inventada -- y pintarla
    # encima del juego seria ademas lo peor que se puede hacer alli.
    $deSitio = (Pregunta-De-Sitio $Pregunta) -and -not $hayPartida
    if (-not $deSitio) {
        # La pregunta no pide un sitio, asi que lo que haya propuesto el modelo
        # se descarta entero. Medido: sin esto apuntaba en las CINCO preguntas
        # de conocimiento, a cosas como 'Send a gift' o 'Minimize'.
        # Add-Member -Force Y NO asignacion directa.
        #
        # `$d` sale de ConvertFrom-Json, asi que solo tiene las claves que el
        # modelo decidio escribir. Asignar a una que no existe lanza
        # "La propiedad 'senalar' no se encuentra en este objeto" y se lleva la
        # pregunta entera -- y pasa justo en las preguntas que NO piden un
        # sitio, que son las que el modelo contesta con `decir` a secas.
        #
        # LEERLAS despues no da problema (PowerShell devuelve $null), solo
        # escribirlas. Por eso el fallo se escondia: aparecia unicamente cuando
        # el modelo era escueto.
        'control', 'senalar', 'dibujar' | ForEach-Object {
            $d | Add-Member -NotePropertyName $_ -NotePropertyValue $null -Force
        }
        $via = 'nada (la pregunta no pide un sitio)'
    }
    if ($d.control -and $d.control -ge 1 -and $d.control -le $controles.Count) {
        $c = $controles[$d.control - 1]
        $punto = @($c.x, $c.y)
        $via = "control $($d.control) '$($c.nombre)'"
    } elseif ($d.senalar) {
        $punto = @($d.senalar.x, $d.senalar.y)
        $via = 'coordenadas del modelo'
        # Enganche. El modelo acierta la ZONA y falla el pixel -- eso es lo que
        # se midio y lo que dice ScreenSpot-Pro. Si su punto cae dentro de un
        # control real, o muy cerca, se usa el rectangulo del sistema en su
        # lugar: precision exacta sin gastar un solo token de contexto.
        #
        # Se engancha a TODOS los controles, no solo a los 40 que van en el
        # prompt: aqui no hay presupuesto de tokens que gastar.
        $cerca = if ($Enganchar) { Buscar-Enganche $punto } else { $null }
        if ($cerca) {
            $c = $cerca
            $punto = @($c.x, $c.y)
            $via = "enganchado a '$($c.nombre)'"
        }
    }

    # El overlay INFORMA de que memoria uso, no pregunta -- no puede recibir la
    # respuesta. Va en `oido`, que es el renglon de "lo que entendi".
    $oido = $Pregunta
    if ($mm.cargadas.Count) { $oido += "   ·   memoria: $($mm.cargadas -join ' + ')" }

    $e = @{ estado = 'hablando'; oido = $oido; dice = $d.decir }
    if ($punto) {
        $e.cursor = $punto
        $e.objetivo = $punto
        # La caja exacta del control, para que se vea QUE se senala y no solo donde.
        if ($c) { $e.trazos = @(@{ tipo = 'caja'; x = $c.x - $c.w / 2; y = $c.y - $c.h / 2; w = $c.w; h = $c.h }) }
    }
    if ($d.dibujar) { $e.trazos = @($e.trazos) + @($d.dibujar) | Where-Object { $_ } }
    Escena $e
    # El instante en que el dibujo SALE hacia el overlay. Es lo ultimo que pasa
    # antes de que el usuario vea algo, asi que marca el final de la cadena.
    $tDibujo = Get-Date

    # Linea legible por maquina, para que `hablar.ps1` pueda juntar estos
    # tiempos con los suyos (oido y STT) en una sola fila por frase. Sin esto
    # las etapas viven en dos archivos distintos y no se puede saber cual es la
    # que mas demora, que es justo lo que hay que medir en la sesion.
    #
    # Va con un prefijo fijo para poder pescarla del resto de la salida.
    $medida = [ordered]@{
        pregunta    = $Pregunta
        modelo      = $Modelo
        captura_ms  = [math]::Round($tc.Elapsed.TotalMilliseconds)
        uia_ms      = [math]::Round($tu.Elapsed.TotalMilliseconds)
        memoria_ms  = [math]::Round($tm.Elapsed.TotalMilliseconds)
        modelo_ms   = $r.ms
        vram_libre_mib = $vramLibre
        controles   = $controles.Count
        memorias    = if ($mm.cargadas) { $mm.cargadas -join '+' } else { '' }
        via         = $via
        senalo      = if ($punto) { "$($punto[0]),$($punto[1])" } else { '' }
        trazos      = @($e.trazos | Where-Object { $_ }).Count
        dijo        = $d.decir
        fin_epoch_ms = [int64]([DateTimeOffset]$tDibujo).ToUnixTimeMilliseconds()
    }
    # A UN ARCHIVO, no por la salida estandar.
    #
    # Antes esta linea iba por stdout y `hablar.ps1` la pescaba del texto. Eso
    # cruza DOS fronteras de codificacion -- como escribe el hijo y como
    # decodifica el padre -- y las dos dependen de la pagina de codigos de la
    # consola. El resultado en la sesion del 2026-09-22: "¿Dónde" llegaba como
    # "┬┐D├│nde" al CSV, y con el nombre del control roto.
    #
    # Un archivo con codificacion explicita en los dos lados no tiene ese
    # problema. Se sigue imprimiendo la linea para poder verla en la consola,
    # pero quien manda es el archivo.
    $medidaJson = $medida | ConvertTo-Json -Depth 4 -Compress
    [IO.File]::WriteAllText("$Raiz\ultima-medida.json", $medidaJson, [Text.UTF8Encoding]::new($false))
    "MEDIDA $medidaJson"

    [pscustomobject]@{
        captura_ms   = [math]::Round($tc.Elapsed.TotalMilliseconds)
        uia_ms       = [math]::Round($tu.Elapsed.TotalMilliseconds)
        controles    = $controles.Count
        memoria_ms   = [math]::Round($tm.Elapsed.TotalMilliseconds)
        memoria_tok  = [int]($memoria.Length / 4)
        memorias     = if ($mm.cargadas) { $mm.cargadas -join ' + ' } else { '(ninguna)' }
        modelo_ms    = $r.ms
        dijo         = $d.decir
        senalo       = if ($punto) { "$($punto[0]), $($punto[1])" } else { '(nada)' }
        via          = $via
        # Con Where-Object: sin el, @($null).Count devuelve 1 y parecia que
        # siempre habia un trazo aunque no se dibujara nada.
        trazos       = @($e.trazos | Where-Object { $_ }).Count
    } | Format-List

    Write-Host "`nel overlay se queda $Segundos s. Ctrl+C para cortar antes."
    Start-Sleep -Seconds $Segundos
} finally {
    try { $tuberia.WriteLine('salir'); $ov.WaitForExit(3000) } catch { }
    if (-not $ov.HasExited) { $ov.Kill() }
}


