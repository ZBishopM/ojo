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
    # PRUEBAS: usa esta imagen en vez de capturar la pantalla (tambien para el
    # OCR), y sin controles de UIA (son de la ventana real, no de la imagen).
    # Para probar chats y demas sin tocar los del usuario.
    [string]$Imagen,
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
    # La voz con la que habla. Cadena vacia = no habla.
    #
    # OJO: en PowerShell 5.1 -- donde corre esto -- solo existen las voces
    # "Desktop": Sabina Desktop (es-MX) y Helena Desktop (es-ES). Laura, Pablo,
    # Raul y las Sabina/Helena "OneCore" solo las ve PowerShell 7. Pedir una
    # que no existe cae a la de por defecto y cuesta ~400 ms (medido).
    [string]$Voz = 'Microsoft Sabina Desktop',
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

# Marcas de tiempo de la fontaneria, que van en ultima-medida.json.
#
# POR QUE: en la tanda limpia del 2026-09-21 se iban entre 830 y 1.122 ms por
# frase FUERA de todas las etapas medidas, y ninguna columna decia donde. Es el
# segundo mayor coste despues del modelo. `arranque_ps` es lo que tardo
# PowerShell desde que el proceso existe hasta esta linea.
$RELOJ = [Diagnostics.Stopwatch]::StartNew()
$MARCAS = [ordered]@{ arranque_ps = [int]((Get-Date) - (Get-Process -Id $PID).StartTime).TotalMilliseconds }
function Marca($n) { $MARCAS[$n] = [int]$RELOJ.ElapsedMilliseconds }

# La voz se PREPARA en paralelo desde el principio.
#
# Iniciar el motor de voz cuesta ~410 ms en un PowerShell 5.1 nuevo (110 de
# cargar System.Speech y ~300 de arrancar el motor la primera vez que se usa;
# medido paso a paso). Hecho despues de dibujar, la voz empezaba 400 ms tarde.
# En otro runspace se hace mientras se captura y piensa el modelo, y lanzarlo
# cuesta 25 ms. El sintetizador creado alli se usa desde aqui sin problema
# (comprobado: SpeakAsync en 3-6 ms, voz correcta).
#
# Eso es la RESERVA. La voz normal es el servidor de voz (voz\servidor_voz.py,
# Supertonic en la GPU, residente): si su mutex existe, SAPI ni se prepara.
# Se mira el mutex y no el puerto: conectar a un puerto local cerrado tarda ~2 s
# en fallar en Windows.
$vozResidente = $false
if ($Voz -and -not $Servidor) {
    $m = $null
    $vozResidente = [Threading.Mutex]::TryOpenExisting('Global\ojo-voz', [ref]$m)
    if ($m) { $m.Dispose() }
}
$vozPreparando = $null
if ($Voz -and -not $Servidor -and -not $vozResidente) {
    $vozPreparando = [powershell]::Create()
    $null = $vozPreparando.AddScript({
        param($v)
        Add-Type -AssemblyName System.Speech
        $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
        if ($s.Voice.Name -ne $v) { try { $s.SelectVoice($v) } catch { } }
        $s.Rate = 1
        $s.SetOutputToDefaultAudioDevice()
        $s
    }).AddArgument($Voz)
    $vozEnMarcha = $vozPreparando.BeginInvoke()
}

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
    #
    # PESOS Q6_K Y NO Q8_0 (2026-09-22), comparados con las dos cosas iguales
    # (KV q8_0, sin calentamiento):
    #
    #                        Q8_0      Q6_K
    #   VRAM total          10.061    8.279 MiB
    #   genera               50,3      62,5 tok/s   (menos bytes que mover)
    #   banco de texto       12/18     12/18        mismas pruebas, mismos fallos
    #   banco de vision      4/5 2/6   4/5 3/6      leer / senalar
    #   prefill de 22k       6,8 s     7,5 s        el unico que pierde; Ojo usa 1-3k
    #
    # Con esto quedan ~2.700 MiB libres con el escritorio normal, y el desalojo
    # que hundia el modelo a 4 tok/s necesita que otro proceso tome todo eso.
    # El mmproj se queda en F16: el Q8_0 ahorraria 367 MiB mas, pero es la
    # parte mas sensible de la vision y el margen ya sobra.
    '8b'  = @{
        gguf   = 'F:\ai\models\qwen3-vl-8b\Qwen3-VL-8B-Instruct-Q6_K.gguf'
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

# Vivo = contesta /props, y de paso se guarda LO QUE ES: que modelo hay puesto
# y si ve imagenes.
#
# POR QUE NO BASTA CON /health: el modelo que corre no tiene por que ser el que
# pide `-Modelo`. El supervisor pone el de TEXTO cuando hay un juego abierto, y
# ojo.ps1 seguia creyendo que hablaba con el 8B: mandaba la captura a un
# servidor sin mmproj (error) y anotaba `8b` en el CSV aunque contestara el 4B.
# El servidor sabe lo que es; se le pregunta.
#
# `$InfoServidor` y NO `$Servidor`: ese nombre ya es el parametro [switch]
# -Servidor, y PowerShell no distingue mayusculas. La primera version lo llamo
# `$SERVIDOR`: guardar las propiedades en un interruptor falla la conversion,
# el catch devolvia falso, y ojo.ps1 esperaba 400 s a un servidor que ya
# estaba arriba. QUINTA vez que esta trampa muerde aqui (ver $rutaModelo).
$InfoServidor = $null
function Servidor-Vivo {
    try {
        $script:InfoServidor = Invoke-RestMethod "http://127.0.0.1:$Puerto/props" -TimeoutSec 2
        [bool]$script:InfoServidor.model_path
    } catch { $script:InfoServidor = $null; $false }
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

    # ¿Ya hay uno ARRANCANDO en nuestro puerto? Entonces se le espera, no se
    # lanza otro.
    #
    # Paso el 2026-09-22: tres llama-server a la vez en el 8099, 8,5 GB
    # comprometidos cada uno y 285 MiB libres. Windows deja escuchar a varios en
    # el mismo puerto (cpp-httplib activa SO_REUSEADDR), asi que ninguno da
    # error. Bastan dos preguntas seguidas mientras el modelo carga -- el
    # supervisor, el atajo -- o cualquier falso "no esta vivo".
    $cargando = @(Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" -EA SilentlyContinue |
                  Where-Object { $_.CommandLine -match "--port\s+$Puerto\b" })
    if (-not $cargando.Count) {
        Write-Host 'levantando llama-server (la primera vez tarda)...'
        Arrancar-Llama
    } else {
        Write-Host "ya hay un llama-server en el $Puerto (pid $($cargando[0].ProcessId)); se le espera"
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 400) {
        Start-Sleep -Milliseconds 500
        if (Servidor-Vivo) { Write-Host ("listo en {0:N0} s" -f $sw.Elapsed.TotalSeconds); return }
    }
    throw 'el servidor no arranco'
}

function Arrancar-Llama {
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
        '--port', $Puerto, '--host', '127.0.0.1',
        '--log-file', "$Raiz\llama.log"
    )
    # SIN -RedirectStandard*, y eso es el arreglo de un cuelgue reproducido.
    #
    # Con las redirecciones, Start-Process usa CreateProcess con herencia de
    # handles, y llama-server se queda con una copia de NUESTRA salida
    # estandar. Quien lea la salida de ojo.ps1 por una tuberia -- hablar.ps1,
    # con `| Out-String` -- espera a que se cierre, y no se cierra nunca porque
    # el servidor vive horas. Medido el 2026-09-22: colgado a los 60 s con el
    # servidor ya listo. En uso real: el atajo muerto sin ningun error, la unica
    # vez que a ojo.ps1 le tocara levantar el servidor.
    #
    # Sin redirecciones usa ShellExecute, que no hereda nada. El registro lo
    # escribe el propio servidor con --log-file.
    Start-Process $llama -ArgumentList $a -WindowStyle Hidden | Out-Null
}

# Se le pide JSON y nada mas. El esquema ES la separacion showman/funcionario:
# `decir` es lo que se habla, `senalar`/`dibujar` es el trabajo. Un solo modelo,
# una sola llamada, dos responsabilidades que no se mezclan.
$SISTEMA = @'
Eres un asistente que mira la pantalla del usuario y le ayuda. Respondes SIEMPRE
con un unico objeto JSON, sin texto alrededor y sin bloques de codigo.

{"decir": "<la respuesta en espanol, solo hechos, lo que dirias en voz alta>",
 "pulla": "<opcional: el comentario sarcastico, sin datos>",
 "buscar": "<opcional: consulta para internet si te falta un dato>",
 "recordar": [{"persona": "<id>", "hecho": "<opcional: algo nuevo que conto>"}],
 "curiosidad": {"persona": "<id>", "pregunta": "<opcional: para conocerle>"},
 "control": 0,
 "texto": 0,
 "senalar": {"x": 0.0, "y": 0.0},
 "dibujar": [{"tipo":"caja","x":0.0,"y":0.0,"w":0.0,"h":0.0}]}

De donde sale lo que dices, de mas fiable a menos:
1. HECHOS VERIFICADOS (hora, fecha, ventana activa) y PERFIL (su equipo, donde
   vive, que juega y usa): exactos. Usalos SOLO si la pregunta los pide: no
   digas la hora si no te la preguntan. Nunca supongas otro equipo (no tiene
   bateria: es un PC de escritorio).
2. TEXTO EN PANTALLA (OCR a tamano real) y LISTA DE CONTROLES: exactos.
3. RESULTADOS WEB: actuales; si los usas, di la fuente ("segun ...").
4. Lo que ves en la imagen (reducida: las cifras pequenas pueden enganarte;
   si esta en TEXTO EN PANTALLA, usa ese).
5. Lo que sabes de tu entrenamiento: SOLO para cosas generales que no cambian.
   Nunca contra un dato de arriba, y nunca para algo actual.
Si te falta un dato que cambia con el tiempo (noticias, precios, resultados,
clima, versiones, parches, "lo ultimo"), NO lo inventes ni digas que no sabes:
pon en "buscar" una consulta corta y en "decir" "Dejame buscarlo."
En "buscar" NO pongas anos que el usuario no haya dicho: lo que tu crees que es
"el ultimo" esta desfasado. Si los RESULTADOS WEB hablan de fechas distintas,
lo "ultimo" es lo mas reciente respecto a la fecha de HECHOS VERIFICADOS.

Reglas:
- Si el mensaje trae una LISTA DE CONTROLES, y el sitio al que quieres apuntar
  esta en ella, responde {"control": N} con su numero EN VEZ de "senalar". Esos
  rectangulos los da el sistema operativo y son exactos; tus coordenadas a ojo
  no lo son. Si no esta ahi pero SI en TEXTO EN PANTALLA, responde
  {"texto": N} con el numero de esa linea. Usa "senalar" solo para lo que no
  este en ninguna de las dos.
- Si lo que piden NO esta en la LISTA DE CONTROLES, ni en TEXTO EN PANTALLA, ni
  lo ves claro en la imagen, dilo ("No veo ningun boton de enviar") y, si lo
  sabes, como se hace sin el (en muchas apps se envia con Enter). NUNCA
  describas donde estaria.
- PERSONAS DE SU VIDA (si llegan sus fichas): de ellas di SOLO lo que dice su
  ficha; nunca inventes nada. El PERFIL es del USUARIO, no de sus amistades ni
  de su hermana: no se lo atribuyas. Tu no eres el usuario: su nombre es suyo.
  Si el usuario cuenta algo nuevo de alguien, o de
  si mismo ("me llamo X" es de [yo]), ponlo en "recordar" con su id y con sus
  palabras. "curiosidad": solo si esa persona sale en la pregunta (o te piden
  tema): UNA pregunta corta y natural para conocerla mejor, que no este entre
  las que ya le hiciste; si sabes su nombre, usalo. La curiosidad va en lugar
  de la pulla. Si sabes el nombre del usuario, usalo de vez en cuando.
- CHATS (WhatsApp, Discord, Telegram...): en TEXTO EN PANTALLA, las lineas
  [der] las escribio el USUARIO; las [izq], la otra persona. "Lo ultimo que me
  envio Irene" es la linea [izq] de mensaje mas abajo (la y mas grande), NUNCA
  una [der]. Citala tal cual, entre comillas.
- Las coordenadas van NORMALIZADAS de 0 a 1, donde 0,0 es arriba a la izquierda
  y 1,1 abajo a la derecha. Nunca en pixeles.
- "senalar" es opcional: omitelo si la respuesta no apunta a ningun sitio.
- "dibujar" es opcional. Tipos validos: caja, flecha (x1,y1,x2,y2),
  subrayado (x,y,w), paso (x,y,n).
- "decir" es obligatorio, en espanol, y como maximo dos frases. Horas, fechas y
  cantidades en CIFRAS ("12:09", "23 de septiembre", "3.362"), no en letra.
- En "decir" NUNCA pongas el numero de un control ni de una linea de texto: di
  su nombre. Los numeros son solo para "control" y "texto".

Caracter: una IA de laboratorio sarcastica, al estilo de GLaDOS. Seca e
ironica, pero util. Espanol latino: "tu" y "ustedes", nunca "vosotros".
"decir" lleva la respuesta completa y solo hechos (si piden una lista, TODOS
los nombres). El humor va aparte, en "pulla": una frase de ocho palabras o
menos, que no afirma ningun dato (ni horas, ni cifras, ni nombres nuevos).
Si no se te ocurre nada bueno, sin pulla. Nunca insulta. Nunca una pregunta
retorica que empiece por "¿Y..." ("¿Y por que...?", "¿Y que esperabas...?"):
cansa.
Ejemplo: {"decir": "El boton Guardar esta arriba a la derecha, junto a
Compartir.", "pulla": "Donde estuvo siempre, por cierto."}
'@

# El de PARTIDA: sin pantalla, sin senalar, y diciendo que significa cada campo.
#
# Con el de arriba, a "como es nuestra composicion?" el 8B contesto "Tu equipo
# lidera en KDA y CS" sin nombrar un solo campeon, teniendo los cinco delante:
# el prompt le habla de mirar la pantalla y apuntar, y durante la partida no hay
# ni una cosa ni la otra. Elegido por medida (banco-partida.ps1), no a ojo.
$SISTEMA_PARTIDA = @'
Eres el copiloto del usuario en su partida de League of Legends. Cada mensaje
trae los DATOS DE LA PARTIDA, sacados del propio juego: son exactos. Contestas
solo con ellos.

Respondes SIEMPRE con un unico objeto JSON, sin texto alrededor:
{"decir": "<la respuesta, en espanol, como maximo dos frases, solo hechos>",
 "pulla": "<opcional: el comentario sarcastico, sin datos>",
 "buscar": "<opcional: consulta para internet si el dato no esta>"}

Reglas:
- Lo que no este en los datos ni en RESULTADOS WEB y cambie con el tiempo (el
  meta, el parche, noticias), NO lo inventes ni digas que no sabes: pon en
  "buscar" una consulta corta (sin anos que el usuario no dijo) y en "decir"
  "Dejame buscarlo." Si hay RESULTADOS WEB, usalos y di la fuente ("segun
  ..."); si hablan de fechas distintas, gana lo mas reciente.
- Nombra campeones e items por su nombre, tal como vienen en los datos.
- "mi_equipo" es el equipo del usuario y "equipo_rival" el contrario; "soy_yo"
  marca al usuario. "puesto" es la linea: TOP, JUNGLE (jungla), MIDDLE (mid),
  BOTTOM (tirador) y UTILITY (soporte).
- "puedo_completar" dice que item termina el usuario con las piezas que ya
  lleva y cuanto oro le falta; "puedo_comprar", que items completos le llegan
  con el oro que tiene.
- "mas_fuerte_rival" y "mas_fuerte_mi_equipo" ya estan calculados: usalos tal
  cual, no los deduzcas de los KDA.
- Si preguntan por la COMPOSICION de un equipo, nombra primero sus cinco
  campeones con su linea; despues, si cabe, una valoracion corta.
- La PREGUNTA viene de reconocimiento de voz: los nombres de campeones y
  aumentos pueden llegar mal escritos ("Jacksa P" es "Jax AP"). Interpretalos
  por parecido con los campeones de la partida y los aumentos de los datos.
- Nombra SOLO items y aumentos que aparezcan en los datos. No inventes nombres,
  ni digas nada del meta o del parche que no venga en los datos.
- "aumentos_mencionados" son aumentos (no items) y lo que hacen.
- "mis_aumentos" son los aumentos que el usuario ya eligio en esta partida.
- "aumentos_en_pantalla" son los aumentos que le ofrecen AHORA, leidos de su
  pantalla. Recomienda UNO de ellos, mejor si esta en los recomendados de
  "build_popular", y di por que en una frase con lo que hace.
- "build_popular" es la build que mas se juega ahora con su campeon, sacada de
  la web. Si la usas, di la fuente ("segun op.gg"). Es lo unico de meta que
  puedes afirmar. Nunca des porcentajes de victoria de aumentos.
- Si los datos dicen "PARTIDA YA TERMINADA", son de la ultima partida: habla
  en pasado y usa resultado, KDA, dano, items y aumentos de ahi.
- "campeones_mencionados" son los campeones de la partida que nombro el
  usuario, ya reconocidos; usa ESE nombre ("Jax"). NUNCA repitas el nombre
  como lo escribio la voz ("Jacksa P", "Jaxa").
- "dano_rival": di QUIENES hacen dano magico y quienes fisico, por su nombre.
- Para "que me hago / que saco contra X": di la "defensa_que_conviene" y
  nombra items de la lista "..._que_te_llega" de ese tipo, con su precio.
  "el_usuario_dice" (por ejemplo "Jax va AP") ya esta tenido en cuenta ahi.
- "hora" y "fecha" de HECHOS VERIFICADOS son las del sistema: exactas. Usalas
  solo si la pregunta las pide.
- Horas, fechas y cantidades en CIFRAS ("12:09", "3500"), no en letra.

Caracter: una IA de laboratorio sarcastica, al estilo de GLaDOS. Seca e
ironica, pero util. Espanol latino: "tu" y "ustedes", nunca "vosotros".
"decir" lleva la respuesta completa y solo hechos (si piden una lista, TODOS
los nombres). El humor va aparte, en "pulla": una frase de ocho palabras o
menos, que no afirma ningun dato (ni cifras, ni nombres nuevos). Si no se te
ocurre nada bueno, sin pulla. Nunca insulta. Nunca una pregunta retorica que
empiece por "¿Y..." ("¿Y por que...?", "¿Y que esperabas...?"): cansa.
Ejemplo: {"decir": "Tu equipo: Garen top, Lee Sin jungla, Lux mid, Jinx
tirador y Thresh soporte.", "pulla": "Equilibrado, para variar."}
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
#
# SIN 'marca' ni 'muestra' sueltos (banco-pantalla, 2026-09-23): "¿cuantos
# vatios MARCA la barra?" y "¿que MUESTRA?" son de LEER, y se trataban como
# de senalar. Solo cuentan si abren la frase ("Marca el boton...", ver
# Pregunta-De-Sitio).
$MARCAS_SITIO = @(
    'donde', 'dónde', 'ubica', 'situa', 'sitúa', 'senala', 'señala', 'apunta',
    'muestrame', 'muéstrame', 'ensena', 'enseña', 'localiza',
    'resalta', 'marcame', 'márcame', 'subraya', 'dibuja', 'en que parte', 'en qué parte',
    'que boton', 'qué botón', 'cual boton', 'cuál botón', 'haz clic', 'pulsa',
    'click', 'clic', 'llevame', 'llévame'
)

function Pregunta-De-Sitio([string]$q) {
    # Normalizar viene de memoria.ps1. Si no esta cargado, minusculas a secas:
    # los marcadores sin tilde siguen cazando la mayoria.
    $n = if (Get-Command Normalizar -ErrorAction SilentlyContinue) { Normalizar $q } else { $q.ToLower() }
    foreach ($m in $MARCAS_SITIO) { if ($n.Contains((Normalizar $m))) { return $true } }
    # "Marca el boton de enviar" / "Muestra donde...": imperativo al principio.
    $q -match '(?i)^\W*(marca|muestra)\b'
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

# Lo que hay abierto en cada workspace de GlazeWM, en texto para el modelo. La
# captura solo ve el monitor activo; esto ve tambien lo escondido. ~80 ms.
function Ventanas-De($n) {
    if ($n.type -eq 'window') { $n } else { foreach ($h in @($n.children)) { Ventanas-De $h } }
}
function Leer-Workspaces {
    $j = (& glazewm query workspaces 2>$null) -join "`n" | ConvertFrom-Json
    $lineas = foreach ($w in @($j.data.workspaces)) {
        $vs = @(Ventanas-De $w | ForEach-Object {
            $t = "$($_.title)"; if ($t.Length -gt 60) { $t = $t.Substring(0, 60) + '…' }
            "$($_.processName) «$t»" })
        $marca = if ($w.hasFocus) { ' (activo, el que ves)' } elseif ($w.isDisplayed) { ' (en el otro monitor)' } else { '' }
        "workspace $($w.name)$($marca): $(if ($vs.Count) { $vs -join '; ' } else { 'vacio' })"
    }
    if ($lineas) { "`n`nWORKSPACES DE GLAZEWM (lo que hay abierto, aunque no se vea):`n" + ($lineas -join "`n") }
}

# ---- Lo que Ojo SABE sin adivinar -------------------------------------------
#
# Medido el 2026-09-23: a "que hora es" leyo el reloj de la barra en la captura
# (acerto por suerte) y se invento "a la hora de la comida"; a "que dia es hoy"
# dijo "un dia de trabajo, como siempre". El sistema lo sabe exacto.
function Hechos-Sistema([switch]$SinVentana, [switch]$Metricas) {
    $a = Get-Date
    $es = [Globalization.CultureInfo]::GetCultureInfo('es-MX')
    $l = @("hora: $($a.ToString('HH:mm'))", "fecha: $($a.ToString("dddd d 'de' MMMM 'de' yyyy", $es))")
    # Lo que pinta la barra de arriba, pero del sistema: el OCR de la barra lee
    # mal (su letra es diminuta: "16 .5/126" por "10.5/12G"). ~80 ms.
    if ($Metricas) {
        try {
            $g = (& nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu,temperature.gpu,power.draw --format=csv,noheader,nounits) -split ',\s*'
            $l += "VRAM: {0:N1} de {1:N0} GB usados; GPU al {2} %, {3} °C, {4:N0} W" -f ([double]$g[0] / 1024), ([double]$g[1] / 1024), $g[2], $g[3], [double]$g[4]
        } catch { }
        try {
            $os = Get-CimInstance Win32_OperatingSystem
            $l += "RAM: {0:N1} de {1:N1} GB usados ({2:N0} %)" -f (($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB), ($os.TotalVisibleMemorySize / 1MB),
                (100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize))
            $l += "CPU: {0} %" -f (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime
        } catch { }
    }
    if (-not $SinVentana) {
        try {
            $f = ((& glazewm query focused 2>$null) -join "`n" | ConvertFrom-Json).data.focused
            if ($f.processName) { $l += "ventana activa: $($f.processName) «$($f.title)»" }
        } catch { }
    }
    "`n`nHECHOS VERIFICADOS (del sistema, exactos):`n" + ($l -join "`n")
}

# Preguntas que piden LEER algo de la pantalla: para esas se pasa el OCR a
# tamano real. La imagen del modelo va reducida a 1280 y en 1440p una letra de
# 11 px queda en 5 (leyo 219 W por 218).
#
# Con palabras DE PANTALLA, no con "cuanto" a secas: "a cuanto esta el dolar"
# disparaba el OCR (~1 s) para una pregunta que es de internet.
function Pregunta-De-Lectura([string]$q) {
    # (y de CHATS: "cual fue el ultimo mensaje que me envio Irene" no leia la
    # pantalla y el modelo confundia quien habia escrito que)
    $q -match '(?i)\bmarca\b|\bdice\b|\bpone\b|muestra|aparece|se ve\b|\blee\b|l[eé]eme|leer|pantalla|barra|ventana|bot[oó]n|t[ií]tulo|pesta[nñ]a|c[oó]mo se llama|mensaje|\bchat\b|escribi[oó]|envi[oó]|me dijo|contest[oó]'
}

# TODAS las decisiones de ruta que se toman antes de preguntar, en un solo
# sitio: que se lee de la pantalla, si pide un sitio, si huele a actualidad
# (busqueda adelantada), si es de SUS cosas (no se busca en internet), si pide
# aumento, workspaces o metricas. Juntas para poder compararlas con otra forma
# de decidir (banco-decidir.ps1: las "decisiones tipadas" a lo Jev).
#
# Comparadas con decisiones tipadas del modelo local ("a lo Jev",
# decidir.ps1) sobre 49 preguntas etiquetadas a mano (banco-decidir.ps1): 91,5%
# contra 92,4%, y el modelo cuesta ~940 ms por pregunta. Se quedan las reglas;
# el banco sirvio para cazar sus fallos (los marcados abajo).
function Decidir-Con-Reglas([string]$q) {
    $personal = $q -match '(?i)\b(mis?|me|tengo|correo|mensajes?|archivos?|carpeta|pantalla|ventana)\b'
    [ordered]@{
        lectura    = [bool](Pregunta-De-Lectura $q)
        sitio      = [bool](Pregunta-De-Sitio $q)
        # Ni de SUS cosas ("que version de Python TENGO") ni la hora o el dia
        # ("que dia es HOY"): esas las sabe el sistema, no internet.
        web        = ($q -match '(?i)\bhoy\b|[uú]ltim|actual|ahora mismo|precio|cu[aá]nto (cuesta|est[aá]|vale)|qui[eé]n gan|resultado|noticia|clima|tiempo hace|parche|versi[oó]n|reciente|esta semana|este a[nñ]o') -and
                     -not $personal -and $q -notmatch '(?i)qu[eé] (d[ií]a|fecha|hora)|\bhora es\b'
        personal   = $personal
        aumento    = $q -match '(?i)aument.*(cu[aá]l|elij|elig|escoj|escog|ofrec|estos|me (dan|salen)|recomi|conviene|tomo|cojo|agarro|\bo el otro)' -or
                     $q -match '(?i)(cu[aá]l|elij|escoj|recomi).*aument' -or
                     $q -match '(?i)cu[aá]l (de (estos|estas|los|las) (tres|3)|elijo|escojo|cojo|tomo|agarro)'
        workspaces = $q -match '(?i)workspace|escritorio|abiert|ventanas|otro monitor'
        metricas   = $q -match '(?i)\bram\b|vram|cpu|gpu|temperatura|vatios|consum|memoria|procesador|gr[aá]fica'
    }
}

# El OCR como bloque para el modelo, con cada linea numerada (para {"texto": N})
# y su posicion. En cultura invariante: con la de es, "0,49,0,01" no se lee.
function Texto-Pantalla($lineas) {
    if (-not @($lineas).Count) { return '' }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $i = 0
    # El LADO va escrito: en los chats, a la derecha escribe el usuario y a la
    # izquierda la otra persona, y comparar numeros de x se le daba mal al 8B.
    #
    # Con una imagen PEQUENA (menos de 1600 px de ancho) el OCR se equivoca: en
    # la captura de referencia de 1280 leyo "22:27" donde pone 12:17, y el
    # modelo se fiaba de el. Entonces se le avisa en vez de llamarlo exacto.
    $fiable = -not $script:anchoNativa -or $script:anchoNativa -ge 1600
    $cabecera = if ($fiable) { 'OCR de la imagen a tamano real, exacto' } else { 'OCR de una imagen PEQUENA: puede equivocarse en cifras; si no cuadra con lo que ves, di que no lo lees claro' }
    "`n`nTEXTO EN PANTALLA ($cabecera; N. [lado] texto @ x,y de 0 a 1):`n" +
        ((@($lineas) | Select-Object -First 120 | ForEach-Object {
            $i++
            $lado = if ($_.x -lt 0.45) { 'izq' } elseif ($_.x -gt 0.55) { 'der' } else { 'centro' }
            [string]::Format($inv, '{0}. [{1}] {2} @ {3:0.00},{4:0.00}', $i, $lado, $_.texto, $_.x, $_.y) }) -join "`n")
}

# Una frase con caracter para un momento (mirando, buscando, sin_resultado):
# una linea al azar de frases\<momento>.txt, sin repetir la ultima vez. Las
# claves de $datos rellenan {consulta} y compania. Sin archivo, $porDefecto.
function Frase([string]$momento, [string]$porDefecto, [hashtable]$datos = @{}) {
    $l = @(try { [IO.File]::ReadAllLines("$Raiz\frases\$momento.txt", [Text.Encoding]::UTF8) |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } } catch { })
    if (-not $l.Count) { $x = $porDefecto }
    else {
        $u = "$Raiz\frases\.ultima-$momento"
        $prev = try { [IO.File]::ReadAllText($u, [Text.Encoding]::UTF8).Trim() } catch { '' }
        $opc = @($l | Where-Object { $_ -ne $prev })
        $x = @($(if ($opc.Count) { $opc } else { $l }) | Get-Random)[0]
        try { [IO.File]::WriteAllText($u, $x, [Text.UTF8Encoding]::new($false)) } catch { }
    }
    foreach ($k in $datos.Keys) { $x = $x.Replace("{$k}", "$($datos[$k])") }
    $x
}

# Una frase por la voz YA, sin esperar a la respuesta ("Dejame buscarlo"). La
# respuesta de verdad, al llegar, la corta: el servidor de voz abre un turno
# nuevo con cada /decir. Sin servidor de voz, nada (la reserva SAPI no se usa
# para esto).
function Decir-Ya([string]$t) {
    if (-not $vozResidente) { return }
    try {
        $b = [Text.Encoding]::UTF8.GetBytes((@{ texto = $t; pid = $PID } | ConvertTo-Json -Compress))
        $null = Invoke-RestMethod 'http://127.0.0.1:8098/decir' -Method Post -Body $b -ContentType 'application/json; charset=utf-8' -TimeoutSec 5
    } catch { }
}

# Si la respuesta salio de la web y no dice de donde, se le anade la fuente: el
# sitio cuyas paginas contienen mas de lo que afirma (cifras y nombres). Dicho
# como se dice en voz alta: "Wikipedia", no "es.wikipedia.org".
function Citar([string]$decir, $web) {
    # Vale solo si nombra un sitio de los resultados: "segun la ultima
    # cotizacion disponible" no es una fuente.
    # Y con "segun": "es.windows.day" se queda en "windows", palabra que sale
    # sola en cualquier respuesta sobre Windows, y lo daba por citado.
    $p = Plano $decir
    if ($p -match 'segun') {
        foreach ($s in @($web.fuentes)) { $n = ("$($s.sitio)" -split '\.')[-2]; if ($n -and $p.Contains((Plano $n))) { return $decir } }
    }
    $claves = @([regex]::Matches($decir, '\d+(?:[.,:]\d+)*|\b\p{Lu}[\p{L}\p{N}''-]{2,}') | ForEach-Object { Plano $_.Value })
    $mejor = @($web.fuentes) | Sort-Object {
        $t = Plano "$($_.titulo) $($_.fragmento) $($_.texto)"
        - @($claves | Where-Object { $t.Contains($_) }).Count
    } | Select-Object -First 1
    if (-not $mejor) { return $decir }
    $partes = "$($mejor.sitio)" -split '\.'
    $nombre = if ($partes.Count -ge 2) { $partes[-2] } else { $mejor.sitio }
    "$($decir.TrimEnd()) Según $nombre."
}

# Por que no hubo resultados, dicho como se dice: que buscadores cayeron y
# como. Sin motores caidos, es que ninguno encontro nada.
function Motivo-Sin-Web($web, [string]$consulta) {
    $c = $web.caidos
    $lista = @(if ($c) {
        $pares = if ($c -is [hashtable]) { $c.GetEnumerator() | ForEach-Object { @($_.Key, $_.Value) } }
                 else { $c.PSObject.Properties | ForEach-Object { @($_.Name, $_.Value) } }
        for ($i = 0; $i -lt $pares.Count; $i += 2) {
            $motor = (Get-Culture).TextInfo.ToTitleCase("$($pares[$i])"); $por = "$($pares[$i + 1])"
            if ($por -match '(?i)captcha') { "$motor me pide un CAPTCHA" }
            elseif ($por -match '(?i)too many|suspended') { "$motor dice que son demasiadas búsquedas" }
            elseif ($por -match '(?i)timeout') { "$motor no respondió a tiempo" }
            else { "$motor falló ($por)" }
        }
    })
    if ($lista.Count) { "Ningún buscador me dio nada sobre «$consulta»: $($lista -join ', '). Prueba en un rato." }
    else { "Busqué «$consulta» y ningún buscador encontró nada." }
}

# La linea del OCR que la PREGUNTA nombra, para senalarla sin depender del
# modelo. banco-pantalla (2026-09-23): a "senala el boton Guardar del panel
# derecho" se enganchaba al titulo "Panel derecho" (lo que dijo el modelo) y
# no al boton; y habia dos "Guardar". Palabras de 3+ letras de la pregunta
# que no sean de relleno; las lineas que solo casan por el lado ("derecho")
# se descartan, y el lado pedido desempata.
function Linea-Por-Pregunta([string]$q, $ocr) {
    $relleno = 'senala senalame donde pone esta boton barra indica panel ventana pantalla muestrame marca marcame ' +
               'del las los una que por favor ahi aqui cual texto dice sale donde como para esa ese esto consumo'
    $lados = 'derecha derecho izquierda izquierdo arriba abajo superior inferior'
    $rel = $relleno -split ' '; $lad = $lados -split ' '
    $pq = (Plano $q) -replace '[^a-z0-9 ]', ' '
    $tokens = @($pq -split '\s+' | Where-Object { $_.Length -ge 3 -and $rel -notcontains $_ -and $lad -notcontains $_ } | Select-Object -Unique)
    # Unidades: la pantalla no dice "vatios", dice "218W".
    $unidad = if ($pq -match '\bvatios?\b|\bwatts?\b') { '^\d+([.,]\d+)?w$' }
              elseif ($pq -match '\bporcentaje\b') { '%$' }
              elseif ($pq -match '\btemperatura\b') { '°' }
    # Pide el VALOR de una etiqueta ("el porcentaje de RAM"): se apunta al
    # numero que la sigue, no a la etiqueta.
    $pideValor = $pq -match '\b(porcentaje|valor|cifra|numero|cuanto|cuanta)\b'
    # Casa exacta o a una letra (el OCR lee "Deiame" por "Dejame").
    $casaTok = { param($w) @($tokens | Where-Object { $_ -eq $w -or ($_.Length -ge 5 -and [math]::Abs($_.Length - $w.Length) -le 1 -and (Distancia-Corta $_ $w) -le 1) }).Count }
    $cand = @(foreach ($l in $ocr) {
        $pal = @($l.palabras); if (-not $pal.Count) { $pal = @($l) }
        for ($i = 0; $i -lt $pal.Count; $i++) {
            $w = ((Plano $pal[$i].texto) -replace '[^a-z0-9%° ]', '').Trim()
            if (-not $w -or $lad -contains $w) { continue }
            $casa = & $casaTok $w
            # La unidad puntua, pero en una linea que TAMBIEN nombra lo pedido
            # pesa mas: "porcentaje de RAM" se iba a un "25%" de la terminal.
            $lineaNombra = @(((Plano $l.texto) -split '[^a-z0-9]+') | Where-Object { $_ -and (& $casaTok $_) }).Count
            if ($unidad -and $w -match $unidad) { $casa += 1 + [int][bool]$lineaNombra * 2 }
            if (-not $casa) { continue }
            $obj = $pal[$i]
            if ($pideValor -and -not $unidad -and $i + 1 -lt $pal.Count -and $pal[$i + 1].texto -match '\d') { $obj = $pal[$i + 1] }
            # Una linea que solo casa por el lado ("Panel derecho") no vale.
            $linPl = (Plano $l.texto) -split '[^a-z0-9]+'
            if (@($linPl | Where-Object { $lad -contains $_ }).Count -and $casa -lt 2) { continue }
            [pscustomobject]@{ l = [pscustomobject]@{ texto = $pal[$i].texto; x = $obj.x; y = $obj.y; w = $obj.w; h = $obj.h }; casa = $casa }
        }
    })
    if (-not $cand.Count) { return $null }
    $max = ($cand | Measure-Object casa -Maximum).Maximum
    $cand = @($cand | Where-Object casa -eq $max | ForEach-Object l)
    if ($pq -match '\bderech') { $cand = @($cand | Sort-Object x -Descending) }
    elseif ($pq -match '\bizquierd') { $cand = @($cand | Sort-Object x) }
    elseif ($pq -match '\b(abajo|inferior)\b') { $cand = @($cand | Sort-Object y -Descending) }
    elseif ($pq -match '\b(arriba|superior)\b') { $cand = @($cand | Sort-Object y) }
    $cand[0]
}

# El chat de la pantalla, ya masticado: el ultimo mensaje de cada lado.
#
# Con el OCR bien leido y la regla en el prompt, el 8B seguia contestando "lo
# ultimo que me envio Irene" con el ultimo mensaje del USUARIO (el mas abajo,
# pero a la derecha). En codigo: se quitan la cabecera, la caja de escribir y
# las horas sueltas ("13:05", "1 3:06"), y se toma el ultimo de cada lado.
function Resumen-Chat($ocr) {
    $msgs = @($ocr | Where-Object {
        $_.y -gt 0.08 -and $_.y -lt 0.93 -and $_.texto.Length -ge 3 -and
        $_.texto -notmatch '^\s*\d{1,2}\s?:\s?\d{2}\s*(a\.?\s?m\.?|p\.?\s?m\.?)?\s*$' } | Sort-Object y)
    $suyo = @($msgs | Where-Object { $_.x -gt 0.55 }) | Select-Object -Last 1
    $otro = @($msgs | Where-Object { $_.x -lt 0.45 }) | Select-Object -Last 1
    if (-not $suyo -and -not $otro) { return [pscustomobject]@{ texto = ''; otro = $null } }
    [pscustomobject]@{
        otro  = $otro.texto
        texto = "`n`nCHAT EN PANTALLA (del OCR, por lados; exacto):" +
            $(if ($otro) { "`nultimo mensaje de la OTRA persona (izquierda): «$($otro.texto)»" }) +
            $(if ($suyo) { "`nultimo mensaje del USUARIO (derecha): «$($suyo.texto)»" })
    }
}

# Minusculas y sin tildes, para cotejar.
function Plano([string]$s) {
    ($s.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '')
}

# Levenshtein con tope: devuelve 2 en cuanto hay mas de una diferencia. Solo
# para comparar dos palabras cortas; lo largo va en OjoTexto (ddragon.ps1).
function Distancia-Corta([string]$a, [string]$b) {
    if ($a -eq $b) { return 0 }
    $prev = 0..$b.Length
    for ($i = 1; $i -le $a.Length; $i++) {
        $cur = @($i) + @(0) * $b.Length
        $min = $i
        for ($j = 1; $j -le $b.Length; $j++) {
            $c = if ($a[$i - 1] -eq $b[$j - 1]) { 0 } else { 1 }
            $cur[$j] = [math]::Min([math]::Min($prev[$j] + 1, $cur[$j - 1] + 1), $prev[$j - 1] + $c)
            if ($cur[$j] -lt $min) { $min = $cur[$j] }
        }
        if ($min -gt 1) { return 2 }
        $prev = $cur
    }
    [math]::Min($prev[$b.Length], 2)
}

# Lo que "decir" afirma sin respaldo en NINGUNA de las fuentes de esta pregunta.
#
# En codigo y no en el modelo: pedirle que se revise a si mismo es pedirle que
# vuelva a creerse. Se cotejan las CIFRAS y los NOMBRES PROPIOS (palabra con
# mayuscula que no abre frase): es lo que se inventa y lo que se puede buscar
# tal cual en el texto de las fuentes. El humor va en "pulla" y no se coteja.
#
# ponytail: las cifras escritas en letra ("las doce y diecisiete") no se
# cotejan; si el modelo empieza a esquivar asi el control, pasarlas a numero.
function Verificar-Decir([string]$decir, [string]$evidencia) {
    $ev = Plano $evidencia
    $sinSep = $ev -replace '(?<=\d)[.,](?=\d)', ''
    $faltan = @()
    # Con sus letras pegadas: "23H2" entero, no solo "23" (que coincidia con la
    # fecha de hoy y dejaba pasar una version inventada).
    foreach ($m in [regex]::Matches($decir, '[\p{L}\d]*\d[\p{L}\d]*(?:[.,:]\d+)*')) {
        # En minusculas, como la evidencia: "T1" no casaba nunca con "t1" y el
        # ultimo mundial acababa en "nada confirmado".
        $n = Plano $m.Value
        if (-not ($ev.Contains($n) -or $sinSep.Contains(($n -replace '[.,]', '')))) { $faltan += $n }
    }
    # Tras comillas tambien abre frase ('Llegue' citado no es un nombre propio).
    # Las comillas de apertura tipograficas van como \p{Pi} y no literales:
    # dentro de una cadena de PowerShell entre comillas simples, la comilla
    # simple curva de apertura CIERRA la cadena.
    $palabrasEv = $null
    foreach ($m in [regex]::Matches($decir, '(?<!(?:^|[.!?¡¿:"''\p{Pi}(]\s*))\b\p{Lu}[\p{L}\p{N}''-]{2,}')) {
        $w = $m.Value.TrimEnd("'", '-')
        $pw = Plano $w
        if ($ev.Contains($pw)) { continue }
        # Variante de una letra en nombres largos: el modelo dice "Canberra" y
        # la Wikipedia en espanol "Camberra". Solo contra palabras de la
        # evidencia con la misma inicial y largo parecido (rapido).
        if ($pw.Length -ge 6) {
            if (-not $palabrasEv) { $palabrasEv = @($ev -split '[^\p{L}\p{N}]+' | Where-Object { $_.Length -ge 5 } | Select-Object -Unique) }
            $casi = $palabrasEv | Where-Object { $_[0] -eq $pw[0] -and [math]::Abs($_.Length - $pw.Length) -le 1 -and (Distancia-Corta $_ $pw) -le 1 } | Select-Object -First 1
            if ($casi) { continue }
        }
        $faltan += $w
    }
    @($faltan | Select-Object -Unique)
}

function Preguntar-Modelo($imagen, $pregunta, $controles, $memoria, $partida = $null) {
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
    $sistema = $SISTEMA
    # En PARTIDA: su propio prompt, y los datos delante de la pregunta. Medido
    # con banco-partida.ps1 (8 preguntas, respuesta conocida, dos vueltas):
    # el prompt de pantalla 14/16 en 1.142 ms; este, 16/16 en 535 ms.
    if ($partida) {
        $sistema = $SISTEMA_PARTIDA
        # $memoria en partida: los hechos del sistema y, si se busco, la web.
        $contenido = "DATOS DE LA PARTIDA:`n$partida$memoria`n`nPREGUNTA: $pregunta"
    }
    $cuerpo = @{
        model = 'x'; stream = $false; max_tokens = 300; temperature = 0.1
        # Sin esto el modelo razona, `content` sale vacio y se agota el limite
        # de tokens pensando. Medido: 4.465 ms y nada, contra 361 ms y respuesta.
        chat_template_kwargs = @{ enable_thinking = $false }
        messages = @(
            @{ role = 'system'; content = $sistema },
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
    # `timings` viene gratis en cada respuesta de llama-server. tok/s es el
    # SINTOMA directo de que el modelo ha sido desalojado de la VRAM (de ~50 a
    # ~5), y prompt_n dice cuanto contexto se gasto de verdad.
    @{ ms = [math]::Round($sw.Elapsed.TotalMilliseconds); texto = $r.choices[0].message.content
       tok_s = [math]::Round([double]$r.timings.predicted_per_second, 1)
       prompt_n = [int]$r.timings.prompt_n }
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
Marca 'cargado'
Levantar-Servidor
Marca 'servidor'

# ---- El humor del dia: la PRIMERA pregunta de cada dia lo aprende -----------
#
# Un evento (la primera pregunta del dia), no un temporizador. En segundo plano
# y sin redirecciones; un intento al dia aunque falle (humor\intento.txt), para
# no lanzar uno en cada pregunta si el buscador esta caido. Fuera de partida:
# sus cuatro llamadas al modelo harian esperar a las preguntas del juego.
$hoyHumor = Get-Date -Format 'yyyy-MM-dd'
$intentoHumor = "$Raiz\humor\intento.txt"
if (-not (Get-Process -Name 'League of Legends' -EA SilentlyContinue) -and
    -not ((Test-Path $intentoHumor) -and ((Get-Content $intentoHumor -Raw).Trim() -eq $hoyHumor))) {
    New-Item -ItemType Directory -Force "$Raiz\humor" | Out-Null
    Set-Content $intentoHumor $hoyHumor
    Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$Raiz\humor.ps1", '-Aprender' -WindowStyle Hidden
}

# El overlay se arranca ANTES de preguntar para poder enseñar "mirando..."
# mientras el modelo piensa. Sin eso habria dos segundos de pantalla muerta.
# Matar el overlay de la pregunta ANTERIOR antes de abrir el nuestro.
#
# Cada pregunta abre su propio overlay y lo cierra al acabar, pero con
# `-Segundos 15` el anterior sigue en pantalla si preguntas otra cosa antes.
# Resultado: dos overlays pintando a la vez y los subtitulos superpuestos --
# "genera ruido y se ve sucio", dicho en la sesion del 2026-09-21.
#
# Se ESPERA a que muera: la captura va justo despues y no debe salir en ella.
$viejos = @(Get-Process 'ojo-overlay' -EA SilentlyContinue)
$viejos | Stop-Process -Force -EA SilentlyContinue
$viejos | ForEach-Object { $null = $_.WaitForExit(500) }

# ---- Hay partida de League? -----------------------------------------------
#
# Si la hay, NO se mira la pantalla. El juego sirve sus propios datos en
# https://127.0.0.1:2999 (ver `lol.ps1`): campeones, items, oro y las dos
# composiciones, exactos y en milisegundos. Adivinarlos desde una captura es
# mas lento, gasta el mmproj y da respuestas que parecen seguras sin serlo.
#
# Tres puertas, de la mas barata a la mas cara:
#
#   1. Get-Process 'League of Legends' (9 ms). SOLO el juego: el cliente
#      (LeagueClient) NO abre el 2999, y dejarlo pasar costaba ~2 s por
#      pregunta durante la seleccion de campeon -- lo que tarda Windows en
#      rechazar una conexion a un puerto local cerrado.
#   2. lol.ps1 cargado CON PUNTO, en este proceso. Antes era un PowerShell
#      aparte: ~240 ms de arranque en cada pregunta de la partida.
#   3. Dentro, un sondeo TCP con tope de 200 ms antes de pedir nada, por si el
#      juego existe pero aun no ha abierto el puerto (pantalla de carga).
# Las decisiones de ruta, todas a la vez (Decidir-Con-Reglas).
$dec = Decidir-Con-Reglas $Pregunta

$partida = $null
$hayPartida = $false
$respuestaFija = $null
if (Get-Process -Name 'League of Legends' -EA SilentlyContinue) {
    try {
        . "$Raiz\lol.ps1"
        $datosLol = Get-LolDatos
        if ($datosLol) {
            # La muestra REAL se guarda sola: sin comandos a mano en mitad de
            # una partida. La ultima siempre, y la primera de cada dia aparte,
            # para el banco de partida (hoy prueba con una partida inventada).
            try {
                $crudoJson = $datosLol | ConvertTo-Json -Depth 12
                $dirMuestras = "$Raiz\prueba-lol"
                [IO.File]::WriteAllText("$dirMuestras\real-ultima.json", $crudoJson, [Text.UTF8Encoding]::new($false))
                $delDia = "$dirMuestras\real-{0:yyyyMMdd}.json" -f (Get-Date)
                if (-not (Test-Path $delDia)) { [IO.File]::WriteAllText($delDia, $crudoJson, [Text.UTF8Encoding]::new($false)) }
            } catch { }
            $catLol = try { Get-DDragon } catch { $null }
            # Con la pregunta: asi se detectan los aumentos que menciona.
            $hp = Resumir-Partida $datosLol $catLol $Pregunta

            # ---- Los aumentos que VAS ELIGIENDO, apuntados por voz ------------
            #
            # La API de la partida NO dice que aumentos llevas, y el cliente
            # solo los da al terminar (historial). Si quieres que Ojo los tenga
            # en cuenta DURANTE la partida, basta decir "elegi Archimago": se
            # reconoce contra los 135 aumentos de Mayhem y se apunta.
            #
            # Se apunta en un archivo con la "firma" de la partida (los diez
            # campeones): no hay id de partida en la API, y la firma cambia en
            # la siguiente. La partida anterior no se borra: se archiva.
            $dirPartidas = "$Raiz\partidas"
            New-Item -ItemType Directory -Force $dirPartidas | Out-Null
            $firma = (@($datosLol.allPlayers | ForEach-Object { $_.championName }) | Sort-Object) -join ','
            $notasArchivo = "$dirPartidas\actual.json"
            $notas = if (Test-Path $notasArchivo) { [IO.File]::ReadAllText($notasArchivo, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json } else { $null }
            if (-not $notas -or $notas.firma -ne $firma) {
                if ($notas) { Move-Item $notasArchivo ("$dirPartidas\partida-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date)) -Force }
                $notas = [pscustomobject]@{ firma = $firma; aumentos = @() }
            }
            $esNota = (Normalizar-Texto $Pregunta) -match '^\s*(yo\s+)?(eleg|escog|cog|tom|agarr|anota|apunta|me\s+qued|saqu|pill)'
            $nuevos = @(if ($esNota) { Buscar-Aumentos $catLol $Pregunta | ForEach-Object { ($_ -split ':')[0] } })
            if ($nuevos.Count) {
                $notas.aumentos = @(@($notas.aumentos) + $nuevos | Where-Object { $_ } | Select-Object -Unique)
                [IO.File]::WriteAllText($notasArchivo, ($notas | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
                # Respuesta FIJA, sin modelo: es una confirmacion, y asi sale ya.
                # Con el mismo caracter que el modelo (ver $SISTEMA): el dato, y
                # una pulla corta al final, distinta cada vez.
                $respuestaFija = "Anotado: $($nuevos -join ' y '). Llevas $(@($notas.aumentos).Count): $(@($notas.aumentos) -join ', '). " +
                    ('Alguien tiene que llevar la cuenta.', 'Queda registrado, para la posteridad.', 'Tomo nota, como siempre.' | Get-Random)
            }
            if (@($notas.aumentos).Count) { $hp['mis_aumentos'] = @($notas.aumentos) }

            # ---- La build que se esta jugando, de la web (builds.ps1) ---------
            #
            # La primera lectura tarda ~8 s: en mitad de una partida no se
            # espera. Normalmente ya esta: el supervisor la precarga al arrancar
            # el juego (builds.ps1 -Precargar). Si no, se baja EN SEGUNDO PLANO
            # y estara para la siguiente pregunta. Sin redirecciones: no hereda
            # nada de este proceso.
            $bp = $null
            try {
                . "$Raiz\builds.ps1"
                $miRaw = (@($datosLol.allPlayers) | Where-Object { $_.championName -eq $hp.mi_campeon } | Select-Object -First 1).rawChampionName
                $modoLol = "$($datosLol.gameData.gameMode)"
                $bp = if ($miRaw) { Get-BuildCacheada $miRaw $modoLol $catLol }
                if ($bp) {
                    $hp['build_popular'] = [ordered]@{ fuente = $bp.fuente; nucleo = $bp.nucleo; botas = $bp.botas }
                    if (@($bp.aumentos).Count) { $hp['build_popular']['aumentos_recomendados'] = $bp.aumentos }
                } elseif ($miRaw) {
                    Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$Raiz\builds.ps1", $miRaw, $modoLol -WindowStyle Hidden
                }
            } catch { }

            # ---- Cual de los tres aumentos que te OFRECEN ---------------------
            #
            # En Mayhem la eleccion sale al inicio y en los niveles 7, 11 y 15, y
            # ni la API de la partida ni el cliente la cuentan: se LEE de la
            # pantalla con el OCR de Windows (es-MX, sin VRAM), a resolucion
            # completa, del monitor donde esta el juego. En BMP: sin comprimir,
            # guardarlo y abrirlo es casi gratis.
            #
            # Y se contesta SIN MODELO: de los que se ven, el mejor clasificado
            # por op.gg para tu campeon (el orden, nunca porcentajes: politica
            # de Riot). Es un dato, no una opinion, y asi sale en ~medio segundo.
            # Si no esta la clasificacion, el modelo recibe los aumentos leidos.
            #
            # Se guarda la ultima captura (eleccion-ultima.bmp), y cada vez que
            # NO lee tres aumentos, una copia fechada: con esas se afina.
            $pideAumento = $dec.aumento
            if ($pideAumento) {
                try {
                    Add-Type -AssemblyName System.Drawing, System.Windows.Forms
                    $hwnd = (Get-Process 'League of Legends' -EA SilentlyContinue | Select-Object -First 1).MainWindowHandle
                    $pant = $(if ($hwnd -and $hwnd -ne [IntPtr]::Zero) { [Windows.Forms.Screen]::FromHandle($hwnd) } else { [Windows.Forms.Screen]::PrimaryScreen }).Bounds
                    $img = New-Object Drawing.Bitmap $pant.Width, $pant.Height
                    $g = [Drawing.Graphics]::FromImage($img)
                    $g.CopyFromScreen($pant.Location, [Drawing.Point]::Empty, $pant.Size)
                    $g.Dispose()
                    $muestraEleccion = "$Raiz\prueba-lol\eleccion-ultima.bmp"
                    $img.Save($muestraEleccion, [Drawing.Imaging.ImageFormat]::Bmp)
                    Marca 'captura_aumentos'
                    . "$Raiz\ocr.ps1"
                    $lineasOcr = @(Leer-Texto $muestraEleccion)
                    Marca 'ocr'
                    $ofrecidos = @(Aumentos-En-Lineas $catLol $lineasOcr | Select-Object -First 3)
                    Marca 'aumentos_leidos'
                    if ($ofrecidos.Count -lt 3) {
                        $img.Save(("$Raiz\prueba-lol\eleccion-{0:yyyyMMdd-HHmmss}.png" -f (Get-Date)), [Drawing.Imaging.ImageFormat]::Png)
                    }
                    $img.Dispose()
                    if ($ofrecidos.Count) {
                        $hp['aumentos_en_pantalla'] = $ofrecidos
                        $mejor = if ($bp) { Elegir-Aumento $ofrecidos $bp.ranking_aumentos }
                        if ($mejor) {
                            $nom, $que = $mejor.texto -split ':\s*', 2
                            $otros = @($ofrecidos | ForEach-Object { ($_ -split ':')[0] } | Where-Object { $_ -ne $nom })
                            $respuestaFija = "Elige $nom" + $(if ($que) { ": $($que.Trim().TrimEnd('.'))." } else { '.' }) +
                                $(if ($otros.Count) { " Frente a $($otros -join ' y '), es el que mejor clasifica op.gg para $($hp.mi_campeon)." } else { " Es el que mejor clasifica op.gg para $($hp.mi_campeon)." }) +
                                ' ' + ('De nada.', 'Tu intuición puede descansar.', 'Decisión tomada, por ti.' | Get-Random)
                        }
                    } else {
                        $respuestaFija = 'No veo la elección de aumentos en pantalla. Pregúntame con las tres cartas a la vista; adivinar no es lo mío.'
                    }
                } catch { Write-Warning "no pude leer la pantalla: $_" }
            }

            $partida = $hp | ConvertTo-Json -Depth 6 -Compress
            $hayPartida = $true
        }
    } catch {
        Write-Warning "no pude leer la partida: $_"
    }
} elseif ((Get-Process -Name 'LeagueClient' -EA SilentlyContinue) -and
          ($Pregunta -match '(?i)partida|jugu|gan[eéa]|perd[ií]|aumento|kda|da[nñ]o|mvp|c[oó]mo me fue|c[oó]mo nos fue|[uú]ltima')) {
    # ---- DESPUES de la partida: el historial del cliente ----------------------
    #
    # La API de la partida se cierra al acabar, pero el cliente de League sigue
    # abierto y guarda la ultima partida entera, AUMENTOS incluidos (ver
    # lcu.ps1). Solo si la pregunta va de eso: con el cliente abierto se
    # pregunta de todo, y no toda pregunta es sobre la partida.
    try {
        . "$Raiz\lcu.ps1"
        $ult = Get-LcuUltimaPartida
        if ($ult) {
            $hu = Resumir-UltimaPartida $ult (Get-DDragon)
            if ($hu) {
                $partida = "(PARTIDA YA TERMINADA -- habla en pasado)`n" + ($hu | ConvertTo-Json -Depth 5 -Compress)
                $hayPartida = $true
            }
        }
    } catch {
        Write-Warning "no pude leer la ultima partida: $_"
    }
}

# ---- Captura, ANTES de abrir el overlay ------------------------------------
#
# Antes iba despues, con un `Start-Sleep 400` en medio para que el overlay
# estuviera listo. Resultado, visto en la captura que recibio el modelo el
# 2026-09-22: la pildora "mirando" y el bocadillo "Dejame ver..." salian EN LA
# IMAGEN, tapando el centro inferior de la pantalla -- donde Discord tiene la
# caja de mensaje. El modelo se veia a si mismo en cada pregunta, y se pagaban
# 400 ms por ello.
#
# `WDA_EXCLUDEFROMCAPTURE` no es la salida: esconde el overlay tambien de
# shadowplay, y durante una partida es la firma de un tramposo para el
# anti-cheat. Capturar primero no necesita ninguna de las dos cosas.
$tmp = $null
$tc = [Diagnostics.Stopwatch]::StartNew()
# Sin vision no hay captura: mandarle una imagen a un servidor sin mmproj es un
# error seguro, y adivinar la pantalla sin verla seria inventar.
$conVision = [bool]$InfoServidor.modalities.vision
$nativa = $null
if (-not $hayPartida -and $conVision) {
    $tmp = Join-Path $env:TEMP 'ojo.jpg'
    # Y a tamano real, para el OCR (Fase de verificacion): ~75 ms mas. Se lee
    # solo si la pregunta lo pide o si hay que comprobar lo que dijo.
    # Un nombre por ejecucion: el OCR de Windows deja el archivo mapeado
    # mientras vive el proceso, y reescribirlo fallaba (os error 1224). Las
    # viejas se borran; la que siga abierta, se queda para la proxima.
    Get-ChildItem $env:TEMP -Filter 'ojo-nativa-*.bmp' -EA SilentlyContinue | Remove-Item -EA SilentlyContinue
    $nativa = Join-Path $env:TEMP "ojo-nativa-$PID-$([Environment]::TickCount).bmp"
    if ($Imagen) {
        # Como la captura: el OCR lee la imagen a tamano real y el modelo la
        # recibe reducida a 1280 de lado mayor (si no, el banco probaria otra
        # cosa que lo que ve Ojo de verdad).
        $nativa = (Resolve-Path $Imagen).Path
        Add-Type -AssemblyName System.Drawing
        $src = [Drawing.Image]::FromFile($nativa)
        $script:anchoNativa = $src.Width
        $k = [math]::Min(1.0, 1280.0 / [math]::Max($src.Width, $src.Height))
        $red = New-Object Drawing.Bitmap ([int]($src.Width * $k)), ([int]($src.Height * $k))
        $gr = [Drawing.Graphics]::FromImage($red); $gr.InterpolationMode = 'HighQualityBicubic'
        $gr.DrawImage($src, 0, 0, $red.Width, $red.Height); $gr.Dispose(); $src.Dispose()
        $red.Save($tmp, [Drawing.Imaging.ImageFormat]::Jpeg); $red.Dispose()
    }
    else { & $captura --salida $tmp --nativa $nativa | Out-Null }
}
$tc.Stop()
Marca 'captura'

# Sin esperar a que el overlay este listo: la tuberia de stdin guarda la
# primera escena hasta que el lector la recoja.
$psi = [Diagnostics.ProcessStartInfo]::new($overlay, '--servir')
$psi.RedirectStandardInput = $true; $psi.UseShellExecute = $false
$ov = [Diagnostics.Process]::Start($psi)
Marca 'overlay'

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
    Escena @{ estado = 'mirando'; oido = $Pregunta; dice = (Frase 'mirando' 'Déjame ver…') }

    $tu = [Diagnostics.Stopwatch]::StartNew()
    $controles = if ($SinLista -or $hayPartida -or $Imagen) { @() } else { Leer-Controles }
    $tu.Stop()

    # En partida no se buscan notas del proyecto: nadie pregunta por el
    # llama-server a mitad de una teamfight, y son ~110 ms.
    $tm = [Diagnostics.Stopwatch]::StartNew()
    $mm = if ($hayPartida) { @{ texto = ''; cargadas = @() } } else { Leer-Memoria $Pregunta }
    $tm.Stop()
    $memoria = $mm.texto

    if (-not $hayPartida -and -not $conVision) {
        # Perfil de texto sin partida (Hearthstone, o el cliente de LoL antes de
        # la partida). Sin esto, el prompt de sistema le dice que "mira la
        # pantalla" y el modelo la describe inventandosela.
        $memoria += "`n`nAHORA NO VES LA PANTALLA: no hay imagen. No describas lo que no ves; si la pregunta necesita verla, dilo en una frase."
    }
    # Detras de la imagen y de la pregunta: no toca el prefijo cacheado.
    if (-not $hayPartida -and $dec.workspaces) {
        try { $memoria += Leer-Workspaces } catch { Write-Warning "no pude leer los workspaces: $_" }
    }
    # Con -Imagen (pruebas) sin hechos del sistema: la imagen es de otro momento,
    # y el modelo contestaba la RAM y la hora de AHORA en vez de las de la imagen.
    if (-not $Imagen) { $memoria += Hechos-Sistema -SinVentana:$hayPartida -Metricas:$dec.metricas }
    # Su perfil y el de su PC, siempre (perfil.ps1): que no adivine lo que se
    # sabe. En los retos dijo "23% de la bateria de tu portatil" en un PC de
    # escritorio sin bateria.
    try { . "$Raiz\perfil.ps1"; $memoria += Perfil-Texto } catch { Write-Warning "sin perfil: $_" }
    # Las personas de su vida y la conversacion reciente (personas.ps1). Fuera
    # de partida: ahi se pregunta del juego y el prompt de partida es otro.
    # Con -Imagen (bancos y pruebas) tampoco: no deben leer ni escribir la
    # memoria real.
    $personas = $null; $pt = $null; $nombresDichos = @(); $plan = $null
    if (-not $hayPartida -and -not $Imagen) {
        try {
            . "$Raiz\personas.ps1"
            $personas = Leer-Personas
            $nombresDichos = @(Nombres-Directos $Pregunta $personas)
            $pt = Personas-Texto $Pregunta $personas
            # (con -Imagen, sin historial: en el banco, "las 22:27" de una
            # respuesta anterior se colaba como la hora de la imagen)
            $memoria += $pt.texto + $(if (-not $Imagen) { Historial-Texto })
            # Respuestas FIJAS, sin modelo, donde el modelo se liaba (prueba del
            # 2026-09-23): a "Me llamo Bishop" contesto "Me llamo Bishop, segun
            # tu ficha" como si fuera el; a "¿que sabes de Melly?" le atribuyo
            # el perfil del usuario ("vive en Peru y juega League").
            $yoDicho = @($nombresDichos | Where-Object { $_ -like 'yo:*' })
            if (-not $respuestaFija -and $yoDicho.Count -and @($Pregunta -split '\s+').Count -le 6) {
                $respuestaFija = "Anotado, $(($yoDicho[0] -split 'se llama ')[1]). Ya sé cómo llamarte."
            }
            $unaNombrada = if ($pt.ids.Count -eq 1) { $personas | Where-Object id -eq $pt.ids[0] | Select-Object -First 1 }
            if (-not $respuestaFija -and $unaNombrada -and -not @($unaNombrada.hechos).Count -and $Pregunta -match '(?i)qu[eé] sabes de|qui[eé]n es|h[aá]blame de|c[oó]mo es') {
                $nom = if ($unaNombrada.nombre) { $unaNombrada.nombre } else { "tu $($unaNombrada.id)" }
                $respuestaFija = "De $nom todavía no sé nada. ¿Me cuentas algo?"
            }
            # Como responder para conocerle (conocer.ps1): decidido en codigo.
            if (-not $respuestaFija) {
                $plan = Conocer-Turno $Pregunta $personas $pt.ids $pt.tema
                $memoria += $plan.instruccion
                if ($plan.conto) { $null = Guardar-Pendiente $Pregunta $pt.ids }
            }
        } catch { Write-Warning "sin memoria de personas: $_ $($_.ScriptStackTrace -split "`n" | Select-Object -First 1)" }
    }
    # Aumentos de ARAM Mayhem nombrados FUERA de partida: su descripcion exacta
    # del catalogo local (ddragon). Sin esto, "que hace Locomotora" dijo que "no
    # existe" y la web le trajo trenes.
    if (-not $hayPartida -and $Pregunta -match '(?i)aument') {
        try {
            . "$Raiz\ddragon.ps1"
            $aum = @(Buscar-Aumentos (Get-DDragon) $Pregunta)
            if ($aum.Count) { $memoria += "`n`nAUMENTOS DE ARAM MAYHEM (League of Legends, del cliente, exacto):`n" + ($aum -join "`n") }
        } catch { Write-Warning "sin catalogo de aumentos: $_" }
    }

    # El texto de la pantalla a tamano real, si la pregunta es de leer o de
    # ubicar algo. ~450 ms (OCR de Windows sobre la captura ampliada x2: a x1
    # leia "B.94kWh" y "S.8/12G"; a x2, "6.94kWh" y "5.8/12G").
    $ocr = @()
    $to = [Diagnostics.Stopwatch]::new()
    $leerPantalla = {
        $to.Start()
        # TODAS las lineas (antes se cortaba en 80 y en una pantalla con mucho
        # texto se perdia justo lo de abajo: "Dejame ver..." no se podia
        # senalar). Al modelo le llegan como mucho 120 (Texto-Pantalla).
        try { . "$Raiz\ocr.ps1"; $ocr = @(Leer-Palabras $nativa 'es-MX' 2) }
        catch { Write-Warning "no pude leer la pantalla: $_" }
        $to.Stop()
        $memoria += Texto-Pantalla $ocr
        if ($Pregunta -match '(?i)mensaje|\bchat\b|escribi[oó]|envi[oó]|me dijo|contest[oó]') {
            $chat = Resumen-Chat $ocr
            $memoria += $chat.texto
            # "¿Que me envio X?": se contesta con el OCR, sin modelo. Con el
            # mensaje de la otra persona ya etiquetado en el prompt, el 8B
            # respondio el del usuario (prueba-chat, 2026-09-23).
            if (-not $respuestaFija -and $chat.otro -and $Pregunta -match '(?i)\bme (envi[oó]|escribi[oó]|mand[oó]|dijo|contest[oó])') {
                $quien = if ($Pregunta -cmatch '(?:envi[oó]|escribi[oó]|mand[oó]|dijo|contest[oó])\s+(\p{Lu}[\p{L}]+)') { $Matches[1] } else { '' }
                $respuestaFija = "Lo último que te escribió$(if ($quien) { " $quien" }): «$($chat.otro)»."
            }
        }
    }
    # (se llama con punto: escribe $ocr y $memoria de aqui)
    if ($nativa -and ($dec.lectura -or $dec.sitio)) { . $leerPantalla }

    # Busqueda ADELANTADA para lo que huele a actualidad: con la frase literal
    # del usuario, en otro runspace, mientras piensa el modelo. Si al final no
    # hace falta, se tira. Sin esto, preguntar el precio del dolar tardaba ~10,5
    # s: modelo, busqueda y otra vez modelo, uno detras de otro.
    $webAdelantada = $null
    if (-not $respuestaFija -and $dec.web) {
        $webAdelantada = [powershell]::Create()
        $null = $webAdelantada.AddScript({ param($raiz, $q) . "$raiz\buscar.ps1"; Buscar-Web @($q) }).AddArgument($Raiz).AddArgument($Pregunta)
        $webEnMarcha = $webAdelantada.BeginInvoke()
    }

    Marca 'antes_modelo'

    # La respuesta del modelo, lista para usar. Nada de "el control numero 23"
    # en la frase: se cambia por el nombre del control (decir.ps1). Y la pulla
    # no puede llevar cifras: el humor no afirma datos.
    . "$Raiz\decir.ps1"
    $leerRespuesta = {
        param($r)
        $json = Extraer-Json $r.texto
        if (-not $json) { throw "el modelo no devolvio JSON. Dijo:`n$($r.texto)" }
        $x = $json | ConvertFrom-Json
        $x | Add-Member -NotePropertyName decir -NotePropertyValue (Limpiar-Decir $x.decir $controles) -Force
        if ("$($x.pulla)" -match '\d') { $x | Add-Member -NotePropertyName pulla -NotePropertyValue $null -Force }
        $x
    }
    # El humor aprendido de internet (humor.ps1): va al modelo para la pulla,
    # pero NO a la evidencia del verificador -- un dato sacado de un meme no
    # cuenta como respaldo.
    $humor = ''
    if (-not $respuestaFija) { try { . "$Raiz\humor.ps1"; $humor = Referencias-Humor 8 } catch { } }
    $preguntar = { Preguntar-Modelo $tmp $Pregunta $controles ($memoria + $humor) $(if ($hayPartida) { $partida }) }

    $r = if ($respuestaFija) {
        @{ ms = 0; texto = (@{ decir = $respuestaFija } | ConvertTo-Json -Compress); tok_s = 0; prompt_n = 0 }
    } else { & $preguntar }
    Marca 'despues_modelo'
    $d = & $leerRespuesta $r

    # ---- Comprobar lo que dice, y buscar lo que falte ------------------------
    #
    # Regla del usuario: no inventar, y tampoco "no se": si falta, BUSCAR y
    # citar. Orden: lo que dijo se coteja con todas las fuentes de esta
    # pregunta; lo que no aparece se busca primero en la pantalla a tamano real
    # (quiza lo leyo de ahi) y despues en internet, con una segunda pasada del
    # modelo que ya tiene los resultados. Si ni asi, lo dice sin inventar.
    $evidencia = { "$Pregunta`n$memoria`n$partida`n" + ((@($controles) | ForEach-Object { $_.nombre }) -join "`n") }
    $faltan = @()
    $consulta = $null
    $web = $null
    if (-not $respuestaFija) {
        $faltan = @(Verificar-Decir $d.decir (& $evidencia))
        if ($faltan.Count -and $nativa -and -not $ocr.Count) {
            . $leerPantalla
            $faltan = @(Verificar-Decir $d.decir (& $evidencia))
        }
        # Pregunta de PANTALLA y lo dicho sigue sin casar con el OCR: segunda
        # pasada con el contraste estirado (texto gris sobre gris) y se
        # repregunta con lo nuevo. Si ni asi, lo dice (abajo, sin_pantalla).
        $sinPantalla = $false
        if ($faltan.Count -and $nativa -and ($dec.lectura -or $dec.sitio)) {
            try {
                . "$Raiz\ocr.ps1"
                $vistos = @($ocr | ForEach-Object { (Plano $_.texto) -replace '\s', '' })
                $nuevas = @(Leer-Contraste $nativa | Where-Object { $vistos -notcontains ((Plano $_.texto) -replace '\s', '') })
                if ($nuevas.Count) {
                    $memoria += "`n`nTEXTO EN PANTALLA, SEGUNDA LECTURA (contraste aumentado; lineas que la primera no leyo):`n" +
                                (($nuevas | ForEach-Object { "- $($_.texto)" }) -join "`n")
                    $r = & $preguntar
                    $d = & $leerRespuesta $r
                    $faltan = @(Verificar-Decir $d.decir (& $evidencia))
                    Marca 'segunda_lectura'
                }
            } catch { Write-Warning "segunda lectura: $_" }
            $sinPantalla = [bool]$faltan.Count
        }
        # Un "no puedo / no se" tambien se busca: la regla es buscar, no rendirse.
        # Salvo si la pregunta es de SUS cosas (su correo, sus archivos, su
        # pantalla): ahi internet no sabe nada y "no tengo acceso" es la verdad.
        # ("no existe" / "no hay informacion": fuera de partida dijo que el
        # aumento Locomotora "no existe" sin buscarlo.)
        $seRinde = (Plano $d.decir) -match '\bno (puedo|tengo (acceso|informacion|datos)|se\b|lo se\b|dispongo|existe|hay (informacion|datos))'
        # Tambien si nombra a alguien de su vida o pide tema: "¿que sabes de
        # Melly?" busco en internet y contesto con un rapero.
        # Y las preguntas de PANTALLA (leer, senalar): lo que no esta en la
        # pantalla no esta en internet ("¿que codigo pone en la nota gris?"
        # acababa buscando en la web).
        $esSuyo = $dec.personal -or $dec.lectura -or $dec.sitio -or ($pt -and ($pt.ids.Count -or $pt.tema)) -or $nombresDichos.Count
        # De SUS cosas no se busca en internet ni aunque falte respaldo: lo que
        # falta ahi no esta en la web. Se le dice que no lo pudo comprobar.
        # (Se probo a contestar SIEMPRE con la web en las preguntas de
        # actualidad: "que dia es hoy" acababa citando una pagina de fechas en
        # vez del reloj del sistema. Lo que lo evita de verdad es el verificador:
        # "23H2, de 2023" dicho de memoria ya no pasa, y eso dispara la busqueda.)
        $consulta = if ($esSuyo) { $null }
                    elseif ("$($d.buscar)".Trim()) { "$($d.buscar)".Trim() }
                    elseif ($faltan.Count -or $seRinde) { $Pregunta } else { $null }
        # Sin los anos que el usuario no dijo: con la regla en el prompt, el
        # modelo siguio buscando "ultimo mundial ... 2023 ganador" (su
        # entrenamiento) y encontro paginas viejas. En codigo, no en el prompt.
        if ($consulta) {
            foreach ($a in [regex]::Matches($consulta, '\b(19|20)\d{2}\b')) { if ($Pregunta -notmatch "\b$($a.Value)\b") { $consulta = $consulta.Replace($a.Value, '') } }
            $consulta = ($consulta -replace '\s+', ' ').Trim()
        }
        # Se deja la respuesta (puede ser una lectura buena de la imagen) y se
        # avisa de lo que no se pudo comprobar, sin pulla.
        if ($esSuyo -and $faltan.Count) {
            $aviso = if ($sinPantalla) { "No lo leo con claridad en la pantalla: $($faltan -join ', ') no lo pude confirmar. Acércalo o hazle zoom y vuelvo a mirar." }
                     else { "$($d.decir.TrimEnd()) (No pude comprobar: $($faltan -join ', '))." }
            $d | Add-Member -NotePropertyName decir -NotePropertyValue $aviso -Force
            $d | Add-Member -NotePropertyName pulla -NotePropertyValue $null -Force
        }
        if ($consulta) {
            $fraseBuscar = Frase 'buscando' 'Déjame buscarlo.'
            Escena @{ estado = 'buscando'; oido = $Pregunta; dice = $fraseBuscar }
            Decir-Ya $fraseBuscar
            Marca 'buscando'
            # buscar.ps1 SIEMPRE cargado aqui: con la busqueda adelantada los
            # resultados llegan del otro runspace y Texto-Web no existia en este.
            try { . "$Raiz\buscar.ps1" } catch { Write-Warning "no pude cargar buscar.ps1: $_" }
            if ($webAdelantada) {
                try { $web = @($webAdelantada.EndInvoke($webEnMarcha))[0] } catch { }
            }
            # Sin fuentes en la adelantada (o sin adelantada): la busqueda
            # completa, con la consulta del modelo y la frase literal.
            # Contando SIN nulos: con $web nulo, @($web.fuentes).Count vale 1 (la
            # trampa de @($null)). Asi, sin busqueda adelantada, NUNCA se buscaba
            # y se hacia una segunda pasada sin resultados: "capital de
            # Australia" acababa en "nada confirmado".
            if (-not @($web.fuentes | Where-Object { $_ }).Count) {
                try { $otra = Buscar-Web @($consulta, $Pregunta); if ($otra) { $web = $otra } } catch { Write-Warning "no pude buscar: $_" }
            }
            Marca 'buscado'
            $hayWeb = [bool]@($web.fuentes | Where-Object { $_ }).Count
            if ($hayWeb) {
                $memoria += "`n`n" + (Texto-Web $web)
                $r = & $preguntar
                $d = & $leerRespuesta $r
                $faltan = @(Verificar-Decir $d.decir (& $evidencia))
                Marca 'despues_web'
            }
            # Si no hubo fuentes, se dice POR QUE (que motor cayo y como), no
            # "el buscador no contesta": en los retos del 2026-09-23 eso no
            # dejaba saber si era un CAPTCHA, un limite o que no habia nada.
            $sinRespaldo = if (-not $hayWeb) { Motivo-Sin-Web $web $consulta }
                           elseif ($faltan.Count -or (Plano $d.decir) -match 'dejame buscar|lo busco|buscando') {
                               Frase 'sin_resultado' "Busqué «$consulta», pero no lo encontré confirmado en las fuentes." @{ consulta = $consulta } }
            if ($sinRespaldo) {
                $d | Add-Member -NotePropertyName decir -NotePropertyValue $sinRespaldo -Force
                $d | Add-Member -NotePropertyName pulla -NotePropertyValue $null -Force
            } elseif ($hayWeb) {
                $d | Add-Member -NotePropertyName decir -NotePropertyValue (Citar $d.decir $web) -Force
            }
        }
    }
    # ---- Pullas: menos y variadas (retos del 2026-09-23) --------------------
    #
    # "Que lo diga cada vez lo hace ver sintetico" y "ya empieza a ser molesto
    # mas que divertido": salia en todas, casi siempre con el molde "¿Y por que
    # no...?" / "¿Y que esperabas...?". En codigo, no pidiendoselo al modelo:
    #   - nunca en respuestas de datos (cifras, hora, metricas, lectura, web)
    #   - nunca con ese molde
    #   - nunca arrancando igual que alguna de las ultimas 6
    #   - y aun asi, solo 1 de cada 3
    $pulla = "$($d.pulla)".Trim()
    if ($pulla) {
        $fRecientes = "$Raiz\frases\.pullas-recientes"
        $recientes = @(try { [IO.File]::ReadAllLines($fRecientes, [Text.Encoding]::UTF8) } catch { })
        $arranque = ((Plano $pulla) -replace '[^a-z0-9 ]', ' ' -split '\s+' | Where-Object { $_ } | Select-Object -First 3) -join ' '
        $esDato = $consulta -or $dec.metricas -or $dec.lectura -or "$($d.decir)" -match '\d' -or $Pregunta -match '(?i)\bhora\b|\bd[ií]a\b|fecha'
        $molde = (Plano $pulla) -match '^\W*y\s+(por que|que esperabas|que tal|acaso)'
        if ($esDato -or $molde -or ($recientes -contains $arranque) -or (Get-Random -Maximum 3) -ne 0) { $pulla = '' }
        else { try { [IO.File]::WriteAllLines($fRecientes, [string[]](@($recientes) + $arranque | Select-Object -Last 6), [Text.UTF8Encoding]::new($false)) } catch { } }
        $d | Add-Member -NotePropertyName pulla -NotePropertyValue $pulla -Force
    }
    # Noticias y preguntas para conocer a alguien, sin sarcasmo (conocer.ps1).
    if ($plan.sin_pulla) { $d | Add-Member -NotePropertyName pulla -NotePropertyValue $null -Force }

    # ---- Memoria de personas: recordar y curiosidad -------------------------
    #
    # Lo nuevo que conto se guarda SOLO si sale de sus palabras (lo coteja
    # Guardar-Recuerdos). La curiosidad, solo sobre alguien que salio en la
    # pregunta (o si pidio tema), sin repetir, y va EN LUGAR de la pulla.
    $recordados = @($nombresDichos | Where-Object { $_ }); $curiosa = $null
    if ($personas -and -not $respuestaFija) {
        try {
            $nuevos = @(Guardar-Recuerdos $Pregunta $d.recordar $personas)
            # Conto algo y el modelo no lo apunto (a "Luis juega voley los
            # sabados" dejo "recordar" vacio): se guarda su frase tal cual, si
            # dice algo mas que el nombre ("Hoy hable con Luis" no).
            if ($plan.conto -and -not @($nuevos | Where-Object { $_ -like "$($plan.persona.id):*" }).Count) {
                $claves = @(@($plan.persona.alias) + $plan.persona.nombre | Where-Object { $_ } | ForEach-Object { Plano-P $_ })
                $resto = @((Plano-P $Pregunta) -split '[^a-z0-9]+' | Where-Object { $_.Length -ge 4 -and $claves -notcontains $_ -and $_ -notmatch '^(hoy|ayer|hable|mira|sabes)$' })
                if ($resto.Count -ge 2) { $nuevos += @(Guardar-Recuerdos $Pregunta ([pscustomobject]@{ persona = $plan.persona.id; hecho = $Pregunta.Trim() }) $personas) }
            }
            $recordados += $nuevos
            # Reflexion cada 5 hechos (conocer.ps1)
            foreach ($id in @($nuevos | ForEach-Object { ($_ -split ':')[0] } | Select-Object -Unique)) {
                try { $null = Reflexionar ($personas | Where-Object id -eq $id | Select-Object -First 1) } catch { Write-Warning "sin reflexion de ${id}: $_" }
            }
            # La pregunta la decide conocer.ps1 si la hay (capa, pendiente); con
            # mala noticia, ninguna.
            $curiosa = if ($plan.pregunta) {
                $null = Apuntar-Curiosidad ([pscustomobject]@{ persona = $plan.persona.id; pregunta = $plan.pregunta }) $pt.ids $personas
                $plan.pregunta
            } elseif ($plan.valencia -ne 'mala') { Apuntar-Curiosidad $d.curiosidad $pt.ids $personas }
            if ($plan.acercar) { $d | Add-Member -NotePropertyName decir -NotePropertyValue ("$($d.decir)".Trim() + ' ' + $plan.acercar).Trim() -Force }
            # Pidio tema y el modelo no pregunto: la curiosidad sale de
            # frases\tema.txt, por la persona elegida (en la prueba, a
            # "Cuentame algo" describio la pantalla y cito una web).
            if (-not $curiosa -and $pt.tema -and $pt.ids.Count) {
                $quien = $personas | Where-Object id -eq $pt.ids[0] | Select-Object -First 1
                $nom = if ($quien.nombre) { $quien.nombre } else { "tu $($quien.id)" }
                $d | Add-Member -NotePropertyName decir -NotePropertyValue (Frase 'tema' "¿Qué es de la vida de $($nom)?" @{ quien = $nom }) -Force
                $curiosa = ''
            }
            if ($curiosa -or $plan.valencia -eq 'mala') {
                # La pregunta va UNA vez: se quitan de "decir" las frases que ya
                # preguntan (con Luis salio la misma pregunta dos veces).
                $sinPreguntas = (@([regex]::Split("$($d.decir)", '(?<=[.!?])\s+') | Where-Object { $_ -notmatch '\?\s*$' }) -join ' ').Trim()
                $d | Add-Member -NotePropertyName decir -NotePropertyValue $sinPreguntas -Force
                $d | Add-Member -NotePropertyName pulla -NotePropertyValue $curiosa -Force
            }
        } catch { Write-Warning "no pude actualizar la memoria de personas: $_" }
    }

    # Lo que se dice en voz alta y se ve en los subtitulos: los hechos y, detras,
    # la pulla.
    $dicho = (@("$($d.decir)".Trim(), "$($d.pulla)".Trim()) | Where-Object { $_ }) -join ' '

    # El numero de control gana sobre las coordenadas a ojo: son el mismo dato
    # que usa Windows para dibujar, no una estimacion.
    $punto = $null
    $via = 'nada'
    # Durante la partida NUNCA se senala: no se ha mirado la pantalla, asi que
    # cualquier coordenada que proponga el modelo es inventada -- y pintarla
    # encima del juego seria ademas lo peor que se puede hacer alli.
    $deSitio = $dec.sitio -and -not $hayPartida
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
        'control', 'texto', 'senalar', 'dibujar' | ForEach-Object {
            $d | Add-Member -NotePropertyName $_ -NotePropertyValue $null -Force
        }
        $via = 'nada (la pregunta no pide un sitio)'
    }
    if ($d.control -and $d.control -ge 1 -and $d.control -le $controles.Count) {
        $c = $controles[$d.control - 1]
        $punto = @($c.x, $c.y)
        $via = "control $($d.control) '$($c.nombre)'"
    } elseif ($deSitio -and $ocr.Count -and ($tPreg = Linea-Por-Pregunta $Pregunta $ocr)) {
        # La linea que nombra la PREGUNTA gana a la que elija el modelo.
        $c = [pscustomobject]@{ x = $tPreg.x; y = $tPreg.y; w = $tPreg.w; h = $tPreg.h; nombre = $tPreg.texto }
        $punto = @($c.x, $c.y)
        $via = "texto de la pregunta '$($tPreg.texto)'"
    } elseif ($d.texto -and $d.texto -ge 1 -and $d.texto -le $ocr.Count) {
        # Una linea del OCR: su rectangulo sale de la imagen a tamano real, tan
        # exacto como el de un control. Mismo formato que un control para la caja.
        $t = $ocr[$d.texto - 1]
        $c = [pscustomobject]@{ x = $t.x; y = $t.y; w = $t.w; h = $t.h; nombre = $t.texto }
        $punto = @($c.x, $c.y)
        $via = "texto $($d.texto) '$($t.texto)'"
    } elseif ($deSitio -and $ocr.Count -and ($tDicho = @($ocr | Where-Object {
                # Sin espacios: el OCR lee el reloj como "12 : 44". Y como palabra
                # entera: "SUPER" (de "RTX 4070 SUPER") casaba dentro de "barra
                # SUPERior" y senalaba la terminal.
                $t = (Plano $_.texto) -replace '\s', ''
                $t.Length -ge 3 -and ((Plano $d.decir) -replace '\s', '') -match "(?<![a-z0-9])$([regex]::Escape($t))(?![a-z0-9])" } |
                                                      Sort-Object { $_.texto.Length } -Descending | Select-Object -First 1)[0])) {
        # Pide un sitio y lo que dice CONTIENE el texto de una linea del OCR
        # ("el reloj marca 12:43"): se senala esa linea, con su rectangulo real.
        # Medido: a "donde esta el reloj" dijo "superior izquierda" (esta en el
        # centro) sin senalar nada, teniendo la hora en el OCR.
        $c = [pscustomobject]@{ x = $tDicho.x; y = $tDicho.y; w = $tDicho.w; h = $tDicho.h; nombre = $tDicho.texto }
        $punto = @($c.x, $c.y)
        $via = "texto que dijo '$($tDicho.texto)'"
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

    # Pedia un SITIO, no hay nada que senalar y aun asi describe un lugar: se
    # lo esta inventando. En los retos del 2026-09-23: "el boton de enviar esta
    # abajo a la derecha" en un Discord que no tiene boton de enviar.
    if ($deSitio -and -not $punto -and (Plano $d.decir) -match '\b(derecha|izquierda|arriba|abajo|esquina|superior|inferior|centro|lateral)\b') {
        $dicho = Frase 'no_encontrado' 'No lo veo en tu pantalla.'
        $via = 'nada: describia un sitio sin poder senalarlo'
    }

    # El overlay INFORMA de que memoria uso, no pregunta -- no puede recibir la
    # respuesta. Va en `oido`, que es el renglon de "lo que entendi".
    $oido = $Pregunta
    if ($mm.cargadas.Count) { $oido += "   ·   memoria: $($mm.cargadas -join ' + ')" }

    $e = @{ estado = 'hablando'; oido = $oido; dice = $dicho }
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
    Marca 'dibujo'

    # ---- La voz ---------------------------------------------------------------
    #
    # El servidor de voz (Supertonic F2, GPU): gano la escucha a ciegas del
    # 2026-09-23 y la primera frase suena en ~260-300 ms. Vuelve en cuanto
    # suena la primera frase; el resto se sintetiza mientras habla. Se le pasa
    # nuestro PID: si el atajo nos mata (Ctrl+Win otra vez, Esc), se calla sola.
    #
    # Si no esta, la reserva: SAPI Sabina (robotica, la peor de la escucha,
    # pero siempre instalada), preparada en paralelo desde el principio.
    $vozSintetizador = $null
    $vozServidor = $false
    if ($vozResidente -and $dicho) {
        try {
            $cuerpoVoz = [Text.Encoding]::UTF8.GetBytes((@{ texto = $dicho; pid = $PID } | ConvertTo-Json -Compress))
            $null = Invoke-RestMethod 'http://127.0.0.1:8098/decir' -Method Post -Body $cuerpoVoz `
                -ContentType 'application/json; charset=utf-8' -TimeoutSec 10
            $vozServidor = $true
            Marca 'voz'
        } catch { Write-Warning "el servidor de voz no contesto: $_" }
    }
    if (-not $vozServidor -and $vozPreparando -and $dicho) {
        try {
            $vozSintetizador = @($vozPreparando.EndInvoke($vozEnMarcha))[0]
            $null = $vozSintetizador.SpeakAsync($dicho)
            Marca 'voz'
        } catch { Write-Warning "no pude hablar: $_" }
    }

    # DESPUES de dibujar, fuera del camino que espera el usuario: nvidia-smi son
    # 49 ms por pregunta. La VRAM libre no cambia en los dos segundos que tarda
    # el modelo, asi que leerla ahora cuenta lo mismo.
    $vramLibre = Vram-Libre

    # El aviso mira el SINTOMA, no la causa. Un umbral de VRAM libre no sirve:
    # con el escritorio normal ya hay menos de 300 MiB libres y el modelo va
    # bien, asi que saltaria siempre. Lo que delata el desalojo es la velocidad:
    # medido, de ~50 a 4-7 tok/s. Por debajo de 25 algo esta robando VRAM.
    if ($r.tok_s -gt 0 -and $r.tok_s -lt 25) {
        Write-Host "AVISO: el modelo genero a $($r.tok_s) tok/s (normal: ~50-60). Algo esta usando la tarjeta y Windows lo ha desalojado de la VRAM; libres ahora: $vramLibre MiB." -ForegroundColor Yellow
    }

    # Linea legible por maquina, para que `hablar.ps1` pueda juntar estos
    # tiempos con los suyos (oido y STT) en una sola fila por frase. Sin esto
    # las etapas viven en dos archivos distintos y no se puede saber cual es la
    # que mas demora, que es justo lo que hay que medir en la sesion.
    #
    # Va con un prefijo fijo para poder pescarla del resto de la salida.
    $medida = [ordered]@{
        pregunta    = $Pregunta
        # El que CONTESTO, leido del servidor, no el que se pidio.
        modelo      = if ($InfoServidor.model_path) { [IO.Path]::GetFileNameWithoutExtension($InfoServidor.model_path) } else { $Modelo }
        captura_ms  = [math]::Round($tc.Elapsed.TotalMilliseconds)
        uia_ms      = [math]::Round($tu.Elapsed.TotalMilliseconds)
        memoria_ms  = [math]::Round($tm.Elapsed.TotalMilliseconds)
        modelo_ms   = $r.ms
        tok_s       = $r.tok_s
        prompt_n    = $r.prompt_n
        vram_libre_mib = $vramLibre
        controles   = $controles.Count
        memorias    = if ($mm.cargadas) { $mm.cargadas -join '+' } else { '' }
        via         = $via
        senalo      = if ($punto) { "$($punto[0]),$($punto[1])" } else { '' }
        trazos      = @($e.trazos | Where-Object { $_ }).Count
        dijo        = $dicho
        # La comprobacion: que afirmaciones no tenian respaldo, que se busco y
        # de donde salio.
        ocr_ms      = [math]::Round($to.Elapsed.TotalMilliseconds)
        ocr_lineas  = $ocr.Count
        sin_respaldo = $faltan -join ' | '
        busco       = "$consulta"
        fuentes_web = if ($web) { (@($web.fuentes) | ForEach-Object { $_.sitio }) -join ', ' } else { '' }
        buscadores_caidos = if ($web.caidos) { ($web.caidos | ConvertTo-Json -Compress) } else { '' }
        recordo     = $recordados -join ' | '
        curiosidad  = "$curiosa"
        valencia    = "$($plan.valencia)"
        acercar     = "$($plan.acercar)"
        fin_epoch_ms = [int64]([DateTimeOffset]$tDibujo).ToUnixTimeMilliseconds()
        marcas       = $MARCAS
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
    # La conversacion reciente, para la proxima pregunta ("¿y ella?").
    try { if (-not $Imagen -and (Get-Command Apuntar-Historial -EA SilentlyContinue)) { Apuntar-Historial $Pregunta $dicho } } catch { }
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
        dijo         = $dicho
        senalo       = if ($punto) { "$($punto[0]), $($punto[1])" } else { '(nada)' }
        via          = $via
        # Con Where-Object: sin el, @($null).Count devuelve 1 y parecia que
        # siempre habia un trazo aunque no se dibujara nada.
        trazos       = @($e.trazos | Where-Object { $_ }).Count
    } | Format-List

    Write-Host "`nel overlay se queda $Segundos s. Ctrl+C para cortar antes."
    Start-Sleep -Seconds $Segundos
} finally {
    # Que termine de HABLAR antes de cerrar: si la frase dura mas que el
    # overlay, cerrarlo cortaria la voz a media palabra. Tope de 30 s.
    if ($vozServidor) {
        try { $null = Invoke-RestMethod 'http://127.0.0.1:8098/esperar' -TimeoutSec 65 } catch { }
    }
    if ($vozSintetizador) {
        $t = [Diagnostics.Stopwatch]::StartNew()
        while ($vozSintetizador.State -eq 'Speaking' -and $t.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 100 }
        $vozSintetizador.Dispose()
    }
    try { $tuberia.WriteLine('salir'); $ov.WaitForExit(3000) } catch { }
    if (-not $ov.HasExited) { $ov.Kill() }
}


