# Mediciones

Todo lo de aquí sale de ejecutar código en este equipo (RTX 4070 SUPER 12 GB,
driver 610.62). Fecha: 2026-09-19. **Ningún número es estimado.**

Regla del proyecto: antes de cada decisión se verifica en internet si hay
versión mejor o corregida. La memoria es punto de partida, no conclusión.

## Discos — por qué todo se movió a SSD

| disco | tipo | lectura secuencial |
|---|---|---|
| I: Barracuda | HDD 1,8 TB | **193 MB/s** |
| F: WD_BLACK SN770 | NVMe 1 TB | **2.572 MB/s** |

**13,3× de diferencia.** Para el modelo de 15,7 GB son ~81 s contra ~6 s solo de
lectura, lo que explica los ~110 s de arranque que ya estaban documentados en
`presets.ini` de voicebox.

Movido de `I:\ai` a `F:\ai` (26,5 GB en 161 s): `models`, `voicebox-models`,
`muletillas`.

**Ya no queda nada apuntando a `I:\ai`.** Se repuntaron los dos consumidores que
habían quedado atrás, que eran los que impedían borrar el duplicado:

| qué | apuntaba a | apunta a |
|---|---|---|
| `~/.config/rice-llm.ps1` (el Win+Space) | `I:\ai` | **`F:\ai`** |
| `D:\2026-projects\companera\iniciar.ps1` | `I:\ai` | **`F:\ai`** |

Los dos usaban además el `llama.cpp` **10164** de `I:`, unas 890 compilaciones
por detrás del b11056 de `F:`. Verificado tras el cambio: el 4B de la compañera
carga en **3,2 s**, `rice-llm -Status` responde, y el 35B de `F:` lleva toda la
sesión sirviendo.

`F:\ai\presets.ini` es nuevo, copiado del de `I:` con dos arreglos obligados por
la compilación nueva: `no-mmap = true` → `load-mode = none` (si no, **los seis
presets fallan al arrancar**) y `cache-ram = 1024` en todos. Lleva también un
preset `[qwen3-vl-8b]` para el modelo de visión.

**Pendiente: borrar `I:\ai` (27,6 GB).** El entorno lo protege y el borrado se
rechaza con «this path is protected from removal», así que tiene que hacerlo el
usuario a mano. Ya no lo usa nada.

## Captura de pantalla — `captura/`

| | monitor activo | escritorio entero |
|---|---|---|
| resolución al modelo | **1280×720** | 1280×411 |
| blit mediana | **15,5 ms** | 34,7 ms |
| total mediana | **27,7 ms** | 47,2 ms |
| p95 | **32,4 ms** | 55,6 ms |

El escritorio virtual aquí son 4480×1440 (1920×1080 + 2560×1440). Reducirlo a
1280 de lado mayor deja 411 px de alto: ilegible para el modelo. Capturar solo
el monitor de la ventana activa arregla la resolución **y** casi divide el
tiempo por dos.

## llama.cpp — hubo que actualizar

| | build | fecha |
|---|---|---|
| lo que había en `I:\ai` | 10164 | 2026-07-28 |
| lo instalado en `F:\ai` | **11056** | 2026-09-19 |

Unas 890 compilaciones de diferencia. **`llama-b11056-bin-win-cuda-12.4-x64.zip`
+ `cudart-llama-bin-win-cuda-12.4-x64.zip`**, extraídas en `F:\ai\llama.cpp`.
CUDA 12.4 y no 13.4 para coincidir con lo que ya funcionaba en este equipo.

### Cambio de interfaz que rompe la configuración vieja

**`--no-mmap` ya no existe.** Lo sustituye `--load-mode MODE`:

| modo | qué hace |
|---|---|
| `auto` | mmap salvo que el dispositivo no lo soporte |
| `none` | sin modo especial — **el equivalente del viejo `--no-mmap`** |
| `mmap` | mapea el modelo en memoria |
| `mmap+mlock` | mmap y fuerza a mantenerlo en RAM |

`I:\ai\presets.ini` usa `no-mmap = true` en los seis presets: **todos fallan con
la compilación nueva**. Hay que cambiarlos a `load-mode = none`.

Pendiente de medir: aquella nota de «1,2 tok/s con mmap contra 23,4 sin ella» se
midió **desde el HDD a 193 MB/s**. Desde NVMe a 2.572 MB/s puede que ya no
aplique y `mmap` salga bien.

## El modelo de visión que ya estaba en disco

`Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf` (15,7 GB) + `mmproj-F16.gguf` (0,84 GB),
servidos con `--n-cpu-moe 24 --ctx-size 8192 --flash-attn on --load-mode none`.

**VRAM con el modelo cargado: 11.304 MiB de 12.282.** Casi no queda nada para
DaVinci ni para juegos.

### La trampa del razonamiento, confirmada también en el 35B

| | tiempo | tokens | respuesta |
|---|---|---|---|
| por defecto | 4.465 ms | 80, agotados | **vacía** |
| `chat_template_kwargs: {enable_thinking: false}` | **361 ms** | 3 | «Discord» |

Sin ese parámetro el modelo razona, el razonamiento va a `reasoning_content`,
`content` sale **vacío** y se agota el límite de tokens pensando. Estaba
documentado para Qwen3.5-4B; **aplica igual al 35B**. Es obligatorio.

### Latencia real del bucle

Dos mediciones que parecen contradecirse y no lo hacen:

| escenario | primer token |
|---|---|
| misma imagen repetida (caché de prompt caliente) | **158 ms** |
| **captura nueva en cada pasada** | **1.886 ms** |

Con imagen nueva, 6 pasadas:

```
captura mediana          48 ms
primer token mediana  1.886 ms
hasta poder hablar    1.933 ms  (p95 1.963)
respuesta completa    2.793 ms
```

El coste es evaluar los ~550 tokens visuales a 299 tok/s ≈ 1,8 s. El presupuesto
del plan daba 0,8-1,3 s: **no se cumple por este camino**.

### La consecuencia de diseño

Los 158 ms de la caché caliente **no son un artefacto que descartar: son el
objetivo**. Si la imagen se envía al modelo en cuanto se pulsa el atajo —
mientras el usuario todavía está hablando, que son 2-4 s — sus tokens se evalúan
durante el habla, y cuando llega la pregunta transcrita la caché ya está
caliente.

Eso convierte 1.886 ms en ~158 ms de espera percibida. **El pre-calentamiento no
es una optimización opcional: es la arquitectura.**

Calidad de las respuestas, en español y sin pedirlo:

> «El usuario está viendo un video de YouTube sobre Hearthstone Battlegrounds
> mientras juega o analiza una partida en el juego.»

## Qué decisión queda abierta, y por qué no la tomo yo

El estado del arte en *GUI grounding* (ScreenSpot-Pro, leaderboard de septiembre
de 2026) desmiente la tabla con la que se escribió el plan:

| # | modelo | ScreenSpot-Pro | ¿local? |
|---|---|---|---|
| 1 | GPT-6 Astra | 92,7% | no |
| 2 | Claude Opus 4.8 | 87,9% | no |
| 3 | GPT-5.4 | 85,4% | no |
| 9 | **Muse Glimmer 30B** (Meta, Apache 2.0) | **75,4%** | sí |
| — | Qwen3-VL-8B | 52,7% | sí |

Qwen3-VL-8B, el candidato del plan, acierta **la mitad** que un modelo frontera.
Para un modo agente que actúa, eso es uno de cada dos clics en el sitio
equivocado.

Muse Glimmer 30B es el mejor con pesos abiertos, pero Meta apunta a **K-Quant de
~17 GB** y aquí hay 12 GB de VRAM: no cabe sin reparto a CPU.

Es una decisión de dinero y privacidad, no técnica, y por eso queda para el
usuario.

## Overlay — `overlay/`

Ventana en capa sobre el monitor del ratón, con la misma receta ya depurada de
`ws-slide`: `WS_EX_LAYERED | TRANSPARENT | TOPMOST | NOACTIVATE | TOOLWINDOW` y
`UpdateLayeredWindow(ULW_ALPHA)`. Rasterizado con tiny-skia (antialias) y texto
con fontdue sobre la **JetBrains Mono Nerd Font** del rice.

Medido en el demo de 12 s a 1920×1080:

```
cuadros                693        fps 57,8
pintar mediana        1,05 ms     (tiny-skia)
presentar mediana     3,93 ms     (swap BGRA + UpdateLayeredWindow)
                      ~5 ms por cuadro, de 16,7 disponibles a 60 fps
```

Presentar cuesta cuatro veces más que pintar: el grueso no es dibujar sino
cruzar R y B y subir el buffer. Si algún día estorba, ahí está el margen.

### Dos correcciones que salieron al mirarlo

Se renderizaron las escenas a PNG (`--prueba`) y se compusieron sobre gris para
poder juzgarlas:

- **El bocadillo se montaba sobre el cursor.** Estaba a 26 px y a la misma
  altura, así que tapaba el anillo y la línea conectora medía cero. Ahora va a
  54 px y 34 px más abajo, con la línea visible.
- **El anillo quedaba tapado por la flecha.** Radio 16 con el cursor encima y la
  punta en el centro. Subido a 24.

### El flag de captura, y por qué NO es el modo por defecto

`WDA_EXCLUDEFROMCAPTURE` esconde la ventana de **todas** las tuberías de
captura, incluida Windows.Graphics.Capture — la que usa `shadowplay-wgc`. Hace
falta para que el modelo no vea sus propias flechas, pero con él puesto
shadowplay tampoco graba el overlay.

Por eso el overlay arranca **visible** y `--oculto` es opt-in. En el orquestador
el flag se activará solo durante el instante del BitBlt.

Eso deja la revisión con shadowplay operativa: `ojo-overlay --demo`, Alt+F10, y
la repetición contiene el overlay.

## Bucle funcional — `ojo.ps1`

Captura → modelo con salida estructurada → el overlay dibuja. Sin voz todavía.

Tres preguntas reales sobre un escritorio de cuatro paneles (VS Code, esta
sesión, y dos terminales):

| pregunta | captura | modelo | resultado |
|---|---|---|---|
| «¿qué aplicación es y dónde su botón importante?» | 163 ms | 6.991 ms | identificó VS Code bien; **apuntó al borde entre paneles**, no al botón |
| «¿cuántos paneles hay y qué hay abajo a la izquierda?» | 65 ms | 4.536 ms | **4 paneles, info de sistema** — correcto, y señaló (0,25, 0,75) |
| «¿dónde está el uso de GPU?» | 57 ms | 3.811 ms | «barra superior derecha» en (0,85, 0,03) — **cerca**, la barra marca ahí |

Dos aciertos claros y un fallo de precisión fina, que es exactamente lo que
anticipaba el 52,7% de ScreenSpot-Pro: describe bien, señala regular. Contar
paneles y ubicar zonas se le da; clavar un botón concreto, no.

El modelo tarda 3,8-7,0 s porque genera JSON entero sin transmitir y con
`max_tokens` alto. La Fase E (pre-calentamiento y streaming) es la que ataca eso.

### Dos fallos de fontanería, y lo que enseñan

**BOM en la tubería.** La primera escena —la de «mirando» mientras el modelo
piensa— se perdía siempre con `expected value at line 1 column 1`. Es el BOM que
.NET antepone al primer `WriteLine` sobre stdin. `trim()` de Rust **no lo quita**
porque U+FEFF no cuenta como espacio en blanco. Arreglado en el lector con
`trim_start_matches('\u{feff}')`: quien escriba en esa tubería no tiene por qué
saber esto.

**`StandardInputEncoding` no existe en PowerShell 5.1.** Primer intento de
arreglo, y rompía el script según con qué consola se lanzara. Sustituido por un
`StreamWriter` explícito sobre el flujo crudo, que funciona en 5.1 y en 7.

## Precisión fina — `uia/`

El fallo de la sección anterior («describe bien, señala regular») tiene arreglo y
no pasa por cambiar de modelo. Es el camino de **UFO2**, el agente de escritorio
de Microsoft: no adivinar coordenadas, **leerlas**. UI Automation devuelve el
rectángulo exacto con el que Windows dibuja cada control.

### El resultado, sobre Discord

Misma pregunta, mismo modelo, misma captura. Lo único que cambia es si el
mensaje lleva la lista de controles:

| pregunta | solo el modelo | con la lista de UIA |
|---|---|---|
| ¿dónde silencio el micrófono? | 0,52 · 0,02 | **control 'Mute'** |
| ¿dónde están los ajustes de usuario? | 0,98 · 0,02 | **control 'User Settings'** |
| ¿dónde desactivo el sonido de los auriculares? | 0,95 · 0,02 | **control 'Deafen'** |
| ¿dónde está el botón de cerrar? | 0,98 · 0,02 | **control 'Close'** |

**4 de 4 contra 1 de 4.** Y fíjate en los números de la columna del medio: 0,52 ·
0,02 · 0,95 · 0,98, todos redondos y todos arriba. El modelo no está localizando,
está nombrando regiones. Los tres primeros están mal: esos botones viven abajo a
la izquierda.

Imagen comentada: `escenas/precision-uia-vs-vlm.png` — verde el rectángulo de
UIA, rojo donde apuntó el modelo solo.

### Cuánto cuesta

| ventana | controles | ms |
|---|---|---|
| Claude | 24 | **41** |
| Zed | 1 | 38 |
| WindowsTerminal | 9 | 66 |
| Discord | 40 de 144 | **164** |
| Firefox, 30 pestañas | 40 | **330** |
| Hearthstone Deck Tracker | 18 | 710 |

Corre **en paralelo** con la captura y con el envío al modelo, así que no suma a
la latencia percibida mientras se quede por debajo del primer token.

### Tres cosas que se probaron y salieron mal

Van aquí porque la próxima persona las va a intentar igual.

**1. La petición de caché de UIA es más lenta, no más rápida.** La documentación
dice que `FindAllBuildCache` agrupa los viajes COM en uno. Medido en Firefox:

| | ms |
|---|---|
| `FindAll` + propiedades `Current*` | **952** |
| `FindAllBuildCache` + `Cached*` | 1.330 |
| **`FindAll` con condición por tipo** | **330** |

Lo que gana no es agrupar los viajes, es **no hacerlos**: con una condición
`OR` sobre los tipos de control, el árbol se recorre del lado de la aplicación y
solo cruzan los que valen. La caché obliga a materializar propiedades de todo el
árbol, justo lo contrario.

**2. Enganchar la coordenada del modelo al control más cercano empeora.** Parecía
la mejor idea de todas: cero tokens de contexto, y el modelo solo tiene que
acertar la zona. Medido:

| pregunta | modelo solo | enganchado |
|---|---|---|
| ¿dónde están los ajustes de usuario? | 0,98 · 0,02 | **'Minimizar'** |
| ¿dónde silencio el micrófono? | 0,5 · 0,02 | **'Pinned Messages'** |

El enganche no distingue «falló por poco» de «falló de sitio». Un punto vago se
ve vago; un rectángulo verde sobre Minimizar parece correcto. **En modo agente
eso pulsaría.** Queda como `-Enganchar`, apagado, para volver a medirlo con un
modelo que acierte la zona de forma fiable.

**3. Ordenar la lista por alto en vez de por área.** Un cuadro de búsqueda es
ancho y bajo, así que por área parece un contenedor y se cae del corte. Sonaba
bien. Contando cuántos de los cuatro objetivos entran en 40:

| orden | aciertos |
|---|---|
| del árbol | 1/4 |
| por alto | 2/4 |
| **por área, tras quitar duplicados** | **3/4** |

### Dos trampas de Windows que costaron tiempo

**La ventana oculta que parece visible.** GlazeWM esconde los espacios de trabajo
*ocultando por DWM*: la ventana sigue diciendo `IsWindowVisible`, conserva sus
coordenadas y UIA devuelve rectángulos perfectamente plausibles de algo que no se
está dibujando. La primera imagen de comparación salió con los rectángulos de
Firefox pintados encima de la captura de Zed, y parecían correctos. Se arregla
con `DwmGetWindowAttribute(DWMWA_CLOAKED)`. Pasa igual con los escritorios
virtuales y con las UWP suspendidas.

**Chromium no enciende la accesibilidad hasta que alguien la pide.** La primera
consulta a Discord devolvió **0 controles**; la siguiente, 40. Para el
orquestador significa una consulta de calentamiento al arrancar, que encaja con
el pre-calentamiento que ya exigía la caché del modelo.

### Lo que UIA no ve, y por eso la visión sigue haciendo falta

Zed devuelve **1 control** (el menú de sistema) porque se dibuja entera con la
GPU. Lo mismo valdrá para juegos y para cualquier interfaz pintada a mano. Ahí la
lista llega vacía y el modelo vuelve a sus coordenadas. Las dos vías conviven a
propósito.

### CORRECCIÓN — no era el contexto, era un bug mío

Aquí ponía que «con 150 controles el servidor devuelve error de contexto». **Es
falso.** El log decía otra cosa:

```
[json.exception.parse_error.101] parse error at line 1, column 203097:
ill-formed UTF-8 byte; last read: '...68. [item] <cortado>'
```

El servidor **nunca parseó el JSON**, así que jamás vio un contexto.
`Invoke-RestMethod -Body <cadena>` partía el cuerpo a medio carácter multibyte —
los nombres de Discord llevan emoji y matemáticas Unicode. Arreglado pasando
bytes UTF-8 explícitos, que es el mismo arreglo que ya hizo falta en la tubería
del overlay.

Con el bug arreglado, **149 controles pasan sin problema**. Y entonces se puede
medir la pregunta de verdad:

| pregunta | 40 controles | 150 controles |
|---|---|---|
| ¿dónde silencio el micrófono? | 'Mute' | 'Mute' |
| ¿dónde están los ajustes de usuario? | 'User Settings' | 'User Settings' |
| ¿dónde desactivo los auriculares? | **'Deafen'** | 'User Settings' |
| ¿dónde está el buscador? | coordenadas a ojo | **'Search GRUPO DE DISCORD'** |
| **aciertos** | **3/4** | **3/4** |
| **tiempo** | **~3,1 s** | ~5,0 s |

**Empatan, y la larga cuesta 1,9 s más.** Gana un objetivo y pierde otro: más
opciones confunden tanto como ayudan. Se queda en 40.

Lo que esto enseña es dónde está el cuello: **no es cuántos controles caben,
es la capacidad del modelo para discriminar entre ellos.** Ahí es donde un
modelo mejor se notaría, no en la longitud de la lista.

### Lo que sigue mal

El modelo **nunca dice «no está en la lista»**. Ante «¿dónde escribo un
mensaje?» eligió 'Find or start a conversation' en vez de admitir que faltaba.
Elección forzada.

## Memoria — 13,3 GB de RAM y el equipo con 777 MB libres

Claude Code mató un shell de fondo por presión de memoria. Al mirarlo:

```
llama-server   WorkingSet 13.273 MB   Private 27.815 MB
sistema        777 MB libres de 32.650
```

### La causa principal no era el modelo

`llama-server` reserva por defecto **8.192 MiB de RAM del sistema** para la
caché de prompts (`-cram, --cache-ram N`). Nunca la pusimos. El log la mostraba
desalojando sin parar:

```
srv alloc: - making room for prompt cache entry, removing oldest entry (size = 223.012 MiB)
```

Once desalojos seguidos de entradas de ~220 MiB. Reservaba para 37 entradas y
usábamos 2.

**No se pone a 0: esa caché ES el pre-calentamiento.** Puesta en 1.024 MiB:

| | antes | después |
|---|---|---|
| WorkingSet | 13.273 MB | **10.454 MB** |
| memoria comprometida | 27.815 MB | **20.471 MB** |
| VRAM | 11.355 MiB | 11.350 MiB |
| carga del modelo | ~110 s (desde HDD) | **14,7 s** (desde NVMe) |

**−2,8 GB residentes y −7,3 GB comprometidos.** La diferencia entre las dos
cifras es que buena parte de la caché estaba comprometida pero no residente.

Y el pre-calentamiento sigue entero — misma imagen tres veces:

```
pasada 1:  2.000 ms   943 tokens,     0 en cache
pasada 2:    510 ms   943 tokens,   939 en cache
pasada 3:    534 ms   943 tokens,   939 en cache
```

### Lo que NO se puede arreglar con banderas

`--n-cpu-moe 24` mantiene 24 capas de expertos en RAM y las usa en **cada
token**. Mientras el modelo no quepa entero en VRAM, esa RAM es obligatoria.

Y el 35B no cabe de ninguna manera:

| cuantización | tamaño | ¿cabe con mmproj + KV en 12,28 GB? |
|---|---|---|
| UD-IQ1_M | 10,0 GB | raspando, **a 1 bit** |
| UD-IQ2_XXS | 10,8 GB | no queda nada para el escritorio |
| UD-Q2_K_XL | 12,3 GB | no |
| **UD-Q3_K_XL (el actual)** | **16,8 GB** | no, de largo |

### Dos cosas verificadas que NO hay que tocar

- **`--load-mode none` ya es lo correcto.** Es el viejo `--no-mmap` y es
  exactamente lo que evita inflar la RAM. Confirmado en la discusión #19883.
- **El bug #26110 no nos afecta.** `mlock` implica `mmap` y duplica el buffer
  hasta *(archivo entero) + (porción en CPU)*, pero no usamos `mlock`.

### El 8B, que sí vive solo en VRAM

`Qwen3-VL-8B-Instruct-Q8_0` (8,11 GB) + `mmproj-F16` (1,08 GB), servido **sin
`--n-cpu-moe`**. Misma pantalla, mismas preguntas, misma lista de UIA:

| | 35B Q3_K_XL | **8B Q8_0** |
|---|---|---|
| RAM recién cargado | 9.108 MB | **1.226 MB** |
| RAM tras las consultas | 10.454 MB | **2.409 MB** |
| memoria comprometida | 20.471 MB | **11.954 MB** |
| VRAM | 11.350 MiB | 11.794 MiB |
| capas en CPU | 24 | **ninguna** |
| carga desde NVMe | 14,7 s | **5,1 s** |
| aciertos de control | 3/4 | **4/4** |
| respuesta completa | 2,6-3,5 s | **2,35-2,59 s** |
| primer token, imagen nueva | 2.000 ms | **1.026 ms** |
| primer token, caché caliente | 510 ms | **151 ms** |

**Gana en todas menos en VRAM**, que es justo lo que se le pidió: que la use
toda. La RAM baja 4,3× y la latencia se parte por dos.

El 52,7% de ScreenSpot-Pro que hacía dudar de este modelo medía *grounding* —
adivinar coordenadas. Ya no las adivina: se las da `ojo-uia`. Lo que se le pide
ahora es elegir un nombre de una lista, y ahí el 8B a 8 bits no se queda corto.

Pasa a ser el predeterminado (`-Modelo 8b`). El 35B sigue en disco para poder
repetir la comparación; son **16,5 GB** que se liberan cuando lo confirmes.

### ¿Y para el rice? No. Y aquí está por qué

El 35B también es el modelo del **Win+Space** (`~/.config/rice-llm.ps1`), que es
otro trabajo: asistente general, no mirar pantallas. La pregunta de si el 8B lo
sustituye ahí se respondió con un banco de pruebas, `banco-modelos.ps1`, donde
**cada prueba se comprueba sola**: la regex se ejecuta contra cadenas reales, el
código generado se ejecuta de verdad, el JSON se parsea y se comparan sus
valores, y los textos salen de archivos reales de este equipo.

| prueba | qué comprueba | 35B | 8B |
|---|---|---|---|
| regex | la ejecuta contra 2 cadenas que debe capturar y 2 que no | **3/3** | 2/3 |
| codigo | ejecuta el PowerShell generado, espera 1060 | 1/1 | 1/1 |
| json | parsea y compara 4 valores contra la tabla original | 1/1 | 1/1 |
| extraccion | `presets.ini` real → n-cpu-moe de `[qwen-32k]` | 1/1 | 1/1 |
| espanol | 3 líneas exactas, sin viñetas, con acentos | 1/1 | 1/1 |
| contexto_largo | 15k tokens reales → el valor **por defecto** de `cache-ram` | **3/3** | **0/3** |
| contexto_largo2 | 15k tokens reales → `WDA_EXCLUDEFROMCAPTURE` | 3/3 | 3/3 |
| velocidad | tokens por segundo generando | 26,7 tok/s | **47,8 tok/s** |
| RAM tras trabajar | | 10.764-11.662 MB | **1.118-1.489 MB** |
| carga | | 13,3-14,4 s | **3,2-5,2 s** |
| VRAM | a ctx 16k, sin mmproj | 8.061 MiB | 11.418 MiB |

**La prueba que decide es `contexto_largo`, y la primera explicación que le di
era demasiado grande.**

Escribí que el 8B «no discrimina». Eso lo sostenía **una** pregunta, tres
veces, en un prompt cargado en contra: `1024` (la respuesta incorrecta) aparecía
**14 veces** y `8192` solo 9. Nueve configuraciones más tarde, la explicación
correcta es otra y es mucho más estrecha.

### Qué falla exactamente — nueve configuraciones

| prueba | qué cambia | 8B | 35B |
|---|---|---|---|
| `d_corto` | los dos valores en **256 tokens** | **5/5** | 5/5 |
| `d_curado` | 11.246 tokens, **sin el archivo del distractor** | **5/5** | 5/5 |
| `contexto_largo2` | 15.006 tokens, pregunta **sin rival** | 3/3 | 3/3 |
| `d_patron3` | 15.993 tokens, la clave preguntada no está en config | 5/5 | 5/5 |
| `d_patron2` | 15.993 tokens, «ranuras» contra `parallel = 1` | 5/5 | 5/5 |
| `d_invertido` | se pide **el valor rival** (1024) | **5/5** | 5/5 |
| `d_largo` | 15.993 tokens **con** `cache-ram = 1024` | **0/5** | 5/5 |
| `d_orden` | lo mismo, documentos al revés | **0/5** | 5/5 |
| `d_conflicto` | otra clave: `n-cpu-moe`, prosa 18 contra config 24-40 | **0/5** | 5/5 |

**La regla que sale de ahí, y se cumple en las nueve:**

> El 8B falla cuando en el contexto hay **otro valor asignado a la misma clave
> por la que se pregunta**. Da igual el tamaño —falla a 16k y acierta a 11k— y
> da igual el orden. Sin valor rival acierta siempre, incluso con 15.993 tokens.

Las tres cosas que **descartan** las explicaciones fáciles:

- **No es longitud.** `d_curado` son 11.246 tokens y acierta 5/5.
- **No es que no lea el matiz.** `d_invertido` le pide el valor que usamos
  *nosotros* y acierta 5/5. Entiende perfectamente «por defecto» contra «el
  nuestro»; lo que no hace es ganarle a la clave repetida.
- **No es posición.** `d_orden` invierte los documentos y sigue 0/5.

### Y una prueba que hubo que tirar

`d_patron1` preguntaba cuál es el `load-mode` por defecto esperando «auto».
**Fallaron los dos modelos, 0/5.** Al revisarlo, los documentos solo listan los
modos y **nunca dicen cuál es el predeterminado**: la pregunta no tiene
respuesta en el corpus.

Que fallen los dos es la señal de que el problema es la pregunta. Sin esa
comprobación habría apuntado un fallo del 8B que no existe. Se conserva en el
script como `P-DPatron1Invalida`, fuera de `$PRUEBAS`, para que nadie la
reinvente.

### Curar el contexto: funciona a veces, y el «a veces» importa

La hipótesis era que cargar solo el documento relevante quita el rival. Se
midió, y el resultado está partido:

| | 8B |
|---|---|
| `d_curado` — quitar `presets.ini` deja `cache-ram` sin rival | **5/5** |
| `d_conflicto_cur` — quitar `presets.ini` **no** deja `n-cpu-moe` sin rival | **0/5** |

En el segundo caso sigue diciendo 24 porque `MEDICIONES.md` también contiene
`--n-cpu-moe 24`. **El distractor no estaba confinado a un archivo.**

La conclusión de diseño es concreta: curar **eligiendo archivos** no basta,
porque un valor rival puede estar repartido. Lo que sí funciona, medido, es un
contexto **corto y de un solo tema** — `d_corto` acierta 5/5 con 256 tokens.

### Por qué el 8B sigue sin sustituir al 35B en el rice

El Win+Space es justo el sitio donde se pega documentación entera y se pregunta
por un valor. Ahí el rival aparece solo, y el 35B lo resuelve 5/5 en los tres
casos donde el 8B saca 0/5.

Se quedan los dos, cada uno en lo suyo:

| | modelo | por qué |
|---|---|---|
| `ojo.ps1` | **8B** | elige de una lista corta; gana en todo |
| `rice-llm.ps1` (Win+Space) | **35B** | discrimina mejor con documentos largos |

Para repetirlo: `.\banco-modelos.ps1`, o `-Solo contexto_largo -Vueltas 5` para
insistir en la que decide.

## Memorias temporales — `memoria.ps1` y `memorias/`

Construidas **después** del diagnóstico y con su forma, no antes. Como curar
eligiendo archivos no basta, cada memoria es una **nota corta escrita a mano de
un solo tema**: ocho notas, 123-195 tokens cada una, 1.334 en total.

En el prompt van siempre los **titulares** (ocho líneas) y solo el **cuerpo** de
lo que se cargue. Detrás de la imagen, para no romper la caché de prefijo.

### El selector no es el modelo, y eso es el diseño

Elegir entre candidatos parecidos es justo lo que falla, así que el modelo no
elige. La puntuación cuenta términos sobre `titular` y `claves`, normaliza por
el número de términos de la pregunta, y las `claves` pesan 1,5 contra 1,0 porque
están escritas para enganchar. Si la mejor no le saca **1,6×** a la segunda,
**pregunta** en vez de adivinar.

`memoria.ps1 -Calibrar` mide el acierto del selector contra un conjunto anotado
a mano de 14 preguntas, dos de ellas que **no deben cargar nada**:

```
acierto de seleccion: 14/14
```

Llegó a 14/14 desde 13/14: *«¿qué hace n-cpu-moe?»* puntuaba **cero**. Los
compuestos con guion se indexaban enteros, y la raíz de cinco letras dejaba
`n-cpu-moe` en `n-cpu`, que no engancha con `cpu` ni con `moe`. Ahora se indexan
enteros **y** por partes. Sin el conjunto anotado ese fallo no se ve.

### Lo que arregla, medido de extremo a extremo

La pregunta que fallaba 0/5 con el corpus entero, ahora por `ojo.ps1`:

| | aciertos |
|---|---|
| con memoria | **5/5** |
| `-SinMemoria` | **0/5** |

Y el desglose de una pasada dice algo que la tasa de acierto esconde:

| | entrada | salida | generación | qué contesta |
|---|---|---|---|---|
| sin memoria | 945 tok | 300, **tope agotado** | 8.854 ms | «reserva **3 GB**» |
| con memoria | 1.379 tok | 156 | **4.599 ms** | «**8.192 MiB**» |

Sin memoria **no dice que no lo sabe: se lo inventa y se lo atribuye a la
pantalla** («según el texto mostrado en la imagen»). Eso es peor que fallar,
porque suena igual que un acierto.

Y con memoria **genera menos y tarda menos**, porque deja de divagar. Las 434
fichas de entrada que cuesta se pagan solas.

### Lo que cuesta

| | antes | ahora |
|---|---|---|
| selector | 649 ms | **155 ms** |
| tokens añadidos al prompt | 306-434 | igual |
| las ocho notas juntas | 1.334 tokens, presupuesto 1.500 | igual |

Los 649 ms eran **proceso, no trabajo**: `ojo.ps1` lanzaba `memoria.ps1` con
`pwsh`. Ahora se carga con punto (`. memoria.ps1 -ComoModulo`, que define las
funciones y no ejecuta nada) y lo que queda son los 155 ms de leer ocho
archivos.

### Cuando el selector duda, carga las dos

Preguntar era el diseño original y **no tenía dónde contestarse**: el overlay es
`WS_EX_TRANSPARENT | WS_EX_NOACTIVATE` y no recibe ni clics ni teclas, y con el
atajo de la Fase C no habrá terminal.

Cargar las dos disuelve el problema: las notas son de 123-195 tokens y el
presupuesto es de 1.500, así que caben nueve. Y no reintroduce el fallo del
modelo — `d_corto` acierta 5/5 con los dos valores rivales en 256 tokens.

```
> memoria.ps1 -Pregunta "cuanta memoria usa el modelo?"
dudaba, cargadas las dos: modelo-vision + discos-modelos
```

El overlay **informa** de lo que se cargó, en el renglón de «lo que entendí». No
pregunta.

Eso obligó a arreglar la contabilidad de `-Calibrar`: un empate que contiene la
respuesta correcta no contaba ni como acierto ni como fallo, y ahora la memoria
buena **sí** entra en el contexto, así que es un acierto. Sin tocarlo, el 14/14
mediría un comportamiento que el código ya no tiene. Sigue en **14/14**.

### Señalar cuando nadie ha preguntado por un sitio

Medido con `probar-senalar.ps1`: cinco preguntas de pantalla que **deben**
apuntar y cinco de conocimiento que **no**.

| | pantalla | conocimiento |
|---|---|---|
| al principio | 5/5 | **0/5** — apuntaba en las cinco |
| con una regla en el prompt | **4/5** | 3/5 |
| **con filtro determinista** | **5/5** | **5/5** |

Apuntaba a `'Send a gift'`, a `'Minimize'`, a coordenadas sueltas. La regla en
prosa mejoró el conocimiento pero **rompió una de pantalla**: decidir cuándo
callarse es un juicio entre opciones parecidas, que es justo lo que este modelo
hace peor.

Lo decide ahora el texto de la pregunta, con una lista de marcadores
(`donde`, `señala`, `qué botón`, `haz clic`…). El modelo sigue proponiendo lo
que quiera; el filtro solo **suprime**, nunca fuerza a apuntar.

Es el mismo patrón que el selector de memorias: lo que el modelo hace mal no se
le pide.

### Un artefacto de medición que casi me engaña

Midiendo la no-regresión aparecieron lotes con la mitad de las salidas vacías —
5 de 8, luego 8 de 10— y llegué a escribir que era un intermitente de `ojo.ps1`.

**No lo era.** Volcando cada salida a un archivo en vez de capturarla por la
tubería, **16 de 16 salieron completas**, con y sin `-Olvidar` por delante. Era
mi arnés de medición. Las cifras de aquellos lotes (4/5, 3/8) estaban
contaminadas; las buenas son las de los volcados a disco:

| | aciertos |
|---|---|
| con memoria | **8/8** |
| `-SinMemoria` | **0/8** |

### Un aviso de llama.cpp que no habíamos visto

Al cargar el 8B:

```
load_hparams: Qwen-VL models require at minimum 1024 image tokens to function
correctly on grounding tasks
load_hparams: if you encounter problems with accuracy, try --image-min-tokens 1024
```

Nuestras capturas dan **939 tokens de prompt en total**, texto incluido: estamos
por debajo de ese mínimo. No se ha tocado porque la prueba ya da 4/4 y subir los
tokens de imagen encarece el prefill, que es la latencia que más duele. Queda
apuntado para el banco de precisión de la Fase F, donde sí habrá casos fallando
que medir.

No se sabe si el 35B avisaba lo mismo: `llama.log` se reescribe en cada arranque
y el suyo ya no está.

### Una trampa que parece optimización

**No poner `--cache-type-k/v q8_0`.** Halvaría el KV, pero si el binario no se
compiló con `GGML_CUDA_FA_ALL_QUANTS=ON`, `--flash-attn on` con KV cuantizado
**cae en silencio a atención por CPU** y el prefill se va 25-45× más lento.
Nuestros binarios son los del zip oficial y no sabemos cómo están compilados.

## Fase C — el oído: `stt/`

### El motor, elegido con números y no heredado

El plan arrastraba «Whisper base, 300 ms medidos en voicebox». Ese número **no
se cumple aquí**. Voicebox carga Whisper con transformers y torch: arranque de
segundos y VRAM que no hay, porque el modelo de visión ocupa 11,4 de 12,28 GB.
Así que el STT tiene que vivir en CPU o no vivir.

Investigando salió **Parakeet TDT 0.6B v3** de NVIDIA: 25 idiomas con detección
automática de idioma, por encima de Whisper large-v3 en las medidas publicadas,
con un cuarto del tamaño y pensado para CPU. Corre con `onnx-asr` —
onnxruntime y nada más, sin torch ni NeMo: ocho paquetes.

Medido sobre ocho frases en español de 2,4-3,6 s, los tres en el mismo runtime:

| motor | mediana | RTF | frases exactas | RAM del demonio |
|---|---|---|---|---|
| **parakeet int8** | **235 ms** | **0,081** | **8/8** | **769 MB** |
| parakeet fp32 | 234 ms | 0,081 | 8/8 | 2.556 MB |
| whisper-base | 885 ms | 0,297 | 8/8 | — |

**Parakeet es 3,8× más rápido que whisper-base**, y el presupuesto de 300 ms
del plan sólo lo cumple él. int8 sale gratis: misma velocidad, las mismas ocho
frases exactas, y **un tercio de la RAM** — que importa porque este proceso
vive residente al lado del modelo de visión.

### Lo que esta medida NO dice

Las ocho frases son **voz sintética** (SAPI, es-MX Sabina). Los tres motores
sacan 0% de WER, así que la prueba **no discrimina en precisión**: sirvió para
descartar que alguno no entendiera español, y para nada más. La precisión de
verdad —con su micrófono, su acento y el ruido de su cuarto— **está sin medir**
y necesita que hable él.

Y una trampa que costó una vuelta: la primera versión de las frases se escribió
en ASCII, así que la voz leyó «se-nala» en vez de «señala» y los dos motores
fallaron esa frase. **Parecía cosa de los motores y era del audio.** Con las
tildes puestas, 8/8 los tres. Cuando fallan todos, sospechar del banco.

### El demonio, y por qué es residente

`stt/escuchar.py` se queda vivo con el modelo caliente. Cargarlo cuesta 3,9 s y
el presupuesto entero hasta la primera palabra es de 1,3 s: pagarlo en cada
pregunta es imposible. Hace además una inferencia en vacío al arrancar, porque
onnxruntime construye el grafo en la primera y si no **la primera pregunta del
día** sería la lenta, que es justo la que se recuerda.

```
GET /salud     estado, micrófono y motor
GET /empezar   al PULSAR el atajo
GET /parar     al soltarlo: para, transcribe y devuelve el texto
GET /cancelar  Esc, tira lo grabado sin transcribir
```

### Los AirPods están vetados en el código

Si el micrófono por defecto es un manos libres, el demonio **se niega a
arrancar y lo dice**, en vez de elegir otro por su cuenta. Cambiar el micrófono
a espaldas del usuario es peor que parar. Se ve con `--dispositivos`:

```
 88  Auriculares con micrófono (... Hands-Free ... AirPods Pro de Carlos) [VETADO]
por defecto: Micrófono (Blue Snowball )
```

### El atajo

`ojo-hotkey.ahk`, **aparte** de `wezterm-hotkey.ahk` para que un fallo aquí no
se lleve los atajos que ya funcionan. Ctrl+Win mantenido, como un walkie;
`hablar.ps1` hace el resto al soltar, fuera de AHK, porque bloquear su bucle de
mensajes mientras el modelo piensa dejaría el teclado sordo.

Dos cuidados de esta máquina, escritos en el propio archivo:

- **No se sintetiza ninguna pulsación de Win.** AltSnap vigila esa tecla y es
  justo lo que lo desincroniza; el síntoma es que se come la barra espaciadora.
- **Hay dos atajos para el mismo gesto.** Si se pulsa Win y luego Ctrl dispara
  uno, y al revés el otro. Un cerrojo evita que cuenten dos veces.

Ctrl+Win está libre: ningún binding con `ctrl+lwin` en GlazeWM, comprobado.

**Sin probar con manos:** que la tecla mantenida se comporte, y la precisión con
su voz. Las dos necesitan que esté delante.

## Arranque automático — Ojo es parte del rice, no un comando

Tener que lanzar Ojo a mano no era un paso pendiente, era un defecto. El rice
ya tiene `rice-supervisor.ps1`, que arranca lo que falta y revive lo que se cae
cada 30 s. Ojo entra ahí con tres filas y **no hace falta tocar
`rice-autostart.ps1`**: el supervisor arranca en su primer tick lo que no esté.

### Por qué las tres van por mutex o por sonda, nunca por nombre

| pieza | el nombre no sirve porque… |
|---|---|
| oído | es un `python.exe`, y el backend de voicebox también |
| atajo | es un `AutoHotkey64`, y `wezterm-hotkey` también |
| modelo | es un `llama-server`, y `rice-llm` levanta otro para el 35B |

Comprobar por nombre daría por vivo lo que está muerto en los tres casos.
`dwindle` ya resolvía lo mismo con `Check = 'Mutex'`.

### Dos defectos que cazó leer `lib/rice-proc.ps1` antes de escribir

Los dos salen de la misma línea del supervisor:

```powershell
if ($Component.Kill) { & $Component.Kill }
else { Get-Process $Component.Match | Stop-Process -Force }
```

1. **Con `Check = 'Mutex'`, el `Match` es el nombre de un mutex.**
   `Get-Process` sobre eso no mata nada: la instancia colgada seguiría viva y
   **la nueva se suicidaría al no poder tomar el mutex**. Cualquier componente
   con mutex y sonda de salud necesita un `Kill` propio.
2. **Con `Match = 'llama-server'`, el kill por defecto habría matado los dos**
   servidores, incluido el 35B del Win+Space. El `Kill` filtra por
   `--port 8099`, igual que `glaze-bar` filtra por su `--x`.

Y un detalle de `Grace`: **solo se aplica si lo arrancó el supervisor**. Lo que
ya estaba vivo al iniciar sesión se sondea en el primer tick.

Comprobado en la máquina, no supuesto: los mutex `Global\` se crean sin ser
administrador — `Global\glazewm-dwindle-ps` existe, creado por un pwsh normal.

### La guarda de VRAM, que no existía

El 35B y el 8B **no caben a la vez**: 11,3 + 11,4 GB sobre 12,28. Nada lo
impedía, y quedarse sin VRAM hace que CUDA se desborde por PCIe — ya pasó, y
está contado en `rice-llm.ps1` (generación a 2 tok/s con 127 MiB libres).

`Levantar-Servidor` ahora se niega si el puerto 8080 contesta. Probado en las
dos ramas, con un servidor falso en 8080 para forzar la que bloquea.

### El interruptor para jugar

Con 11,4 GB de VRAM tomados desde el arranque, jugar exige apagarlo — y a mano
no vale, porque el supervisor lo revive en 30 s. `rice-modo-juego.ps1` ya paraba
el supervisor primero, así que era el sitio correcto. Medido:

| | VRAM |
|---|---|
| con todo vivo | 11.748 MiB |
| tras `rice-modo-juego.ps1` | **1.747 MiB** |
| a los 40 s | 1.747 MiB — no lo revive |
| tras `-Volver` + un tick | 11.734 MiB |

**10 GB liberados con un comando**, y todo vuelve solo. El log del supervisor
muestra cada pieza arrancada **una vez**, sin duplicados:

```
16:57:48 [ojo-oido] started
16:57:49 [ojo-hotkey] started
16:57:49 [ojo-vlm] started
```

Falta la única prueba que de verdad cierra esto: **reiniciar y no tocar nada**.

## Ternary Bonsai 2 27B — medido aquí

Un 27B multimodal con pesos ternarios que, sobre el papel, cabría entero en la
tarjeta y sustituiría a los dos modelos. Se midió porque las cifras publicadas
son del propio fabricante y **ninguna mide interfaces**, que es lo único que
Ojo le pediría.

### Antes de gastar la descarga

Su ficha avisa de que **llama.cpp estándar no lo ejecuta**: rechaza `PQ2_0` y
`PTQ1_0`, y **«carga `Q2_0` sin avisar y produce basura»**. Necesita el fork de
PrismML, que va en `F:\ai\llama.cpp-prism` **al lado y nunca encima** de
nuestro b11056.

Primera comprobación, antes que nada: el fork `prism-b10709` **tiene**
`--cache-ram`, `--load-mode`, `--n-cpu-moe`, `--flash-attn` y `--mmproj`. La
comparación es limpia; no hay que medirlo con banderas distintas.

De paso, algo que la prueba `d_patron1` no pudo responder: el propio `--help`
dice `--load-mode MODE (default: auto)`. El corpus no lo decía, pero el binario
sí.

Y los archivos se verificaron **al byte** contra la API de Hugging Face
(7.206.168.928 y 931.145.856), no por «parece completo»: la primera descarga se
reinició sola y dejó 3,81 GB con pinta de estar bien.

### Que no esté cargando basura en silencio

| señal | resultado |
|---|---|
| carga sin rechazar el tipo | **sí**, en 6,5 s |
| respuesta coherente | **sí** — frase correcta en español |
| VRAM cuadra con 7,58 GB | **sí**: 9.976 MiB totales − 1.219 de escritorio = 8,8 GB con KV |

La respuesta de la prueba fue *«La capital de Perú es Lima, que no es cruzada
por ningún río importante»* — coherente, que es lo que se comprobaba, pero
**falsa**: el Rímac cruza Lima. No invalida nada aquí; queda anotado.

### Lo que ya está medido

| | 35B | 8B | **Bonsai** |
|---|---|---|---|
| regex, código, json, extracción, español | 5/5 | 4/5 | **5/5** |
| velocidad | 26,7 tok/s | 47,8 tok/s | **34,3 tok/s** |
| carga | 14,4 s | 5,2 s | **4,7 s** |
| RAM tras trabajar | 10.764 MB | 1.489 MB | **2.052 MB** |
| VRAM | 8.061 MiB | 11.418 MiB | **9.333 MiB** |

**37,1 tok/s** en la prueba suelta y 34,3 en la del banco, sobre una RTX 4070
SUPER. Es el primer número en GPU de consumo que existe para este modelo: lo
publicado son 143 tok/s en una 5090 y 46,8 en un M5 Max.

### El tokenizador, que casi arruina la comparación

El banco de discriminación **no llegó a correr** la primera vez:

```
request (21132 tokens) exceeds the available context size (16384 tokens)
```

El mismo corpus que el 8B parte en **15.993** fichas y el 35B en **15.637**,
Bonsai lo parte en **21.132**: un **32% más** para el mismo texto. Tokenizador
distinto — base Qwen3.8 contra Qwen3-VL.

No es un detalle de configuración: **a `--ctx-size` igual, Bonsai ve un 32%
menos de texto**. Comparar a 16k a los tres no era comparar. Sus pruebas de
discriminación se repitieron a 24576.

### Discriminación: iguala al 35B

Lo que el 8B no sabe hacer:

| prueba | 35B | 8B | **Bonsai** |
|---|---|---|---|
| `d_corto` (256 fichas, los dos valores) | 5/5 | 5/5 | **3/3** |
| `d_largo` (22k con valor rival) | 5/5 | **0/5** | **3/3** |
| `d_conflicto` (otra clave, mismo patrón) | 5/5 | **0/5** | **3/3** |
| `d_invertido` (se pide el valor rival) | 5/5 | 5/5 | **3/3** |

**Bonsai discrimina como el 35B.** Y lo hace con **1,8 GB de RAM contra 10,4**,
cargando en 5,2 s en vez de 19,7.

El precio está en el tiempo de respuesta con documentos largos: **9,3 s** para
`d_largo` contra 3,4 s del 35B. Parte es que procesa 22k fichas en vez de 15,6k
por lo del tokenizador, y parte es que va más lento.

### Conocimiento de fábrica: aquí sí pierde, y de forma consistente

Diez preguntas de hecho comprobable, sin documentos delante — la prueba
`hechos`, nacida del fallo del Rímac:

| modelo | aciertos |
|---|---|
| 8B Q8_0 | **10/10** |
| 35B Q3_K_XL | **10/10** |
| **Bonsai PQ2_0** | **9/10** |

Falla **solo** el Rímac, y **las cinco vueltas**, siempre con la misma
invención: *«El río Lima»*. No es azar, es un hueco.

**Y eso contesta la pregunta que motivó todo esto.** Los tres escenarios
posibles eran: fallan los tres (no es la cuantización), falla solo uno (su
cuantización borró conocimiento), o aciertan todos (fue una respuesta suelta).

Salió el segundo. **La cuantización importa**, y de forma concreta: 1,76 bits
perdieron un dato que un Q3 de 35B conserva. No es «pocos bits pierden datos»
en general — es este modelo a este nivel.

Que el hueco caiga justo en geografía peruana no es casualidad barata: el
conocimiento local es lo primero que se va cuando se comprime.

### Controles de UIA: la prueba que no tiene datos de nadie

La categoría «Visión» que publica el fabricante agrega CharXiv, A-OKVQA,
OmniDocBench, RealWorldQA y OCRBench. **Ninguna mide interfaces.** Así que
sobre lo único que Ojo le pediría, esto es el único dato que existe:

| | 35B | 8B | Bonsai |
|---|---|---|---|
| aciertos sobre cuatro controles de Discord | 3/4 | **4/4** | 3/4 |
| tiempo por respuesta | 2,6-3,5 s | **2,4-2,6 s** | 3,1-4,5 s |

Bonsai acertó Mute, User Settings y Close, y en «desactivar el sonido de los
auriculares» se cayó a coordenadas en vez de elegir 'Deafen'.

**La primera vez esta medición dio 0/4 y era falsa.** El motivo está abajo.

### Una trampa que invalidó una medición entera

`ojo-uia --ventana discord` enganchó **«Discord Overlay»** —una ventana
auxiliar con CINCO controles— en vez de la ventana real, que tiene 144. La
tabla salió 0/4 y parecía que Bonsai no sabía elegir; lo que pasaba es que **no
había de dónde elegir**, y sus respuestas eran razonables para una lista vacía
(«No veo un botón de cerrar en la lista de controles»).

Lo delató el propio informe: `controles : 0` y `controles : 5` donde antes
ponía 40. **El número de controles hay que mirarlo siempre antes que el
resultado.**

Arreglado: la bandera `--ventana` se queda con **la ventana más grande** de las
que casan, no con la primera. El área separa la aplicación de sus satélites sin
mantener una lista de nombres raros. Solo afecta a las pruebas — el uso real va
por la ventana activa, que nunca es un overlay.

### El veredicto: sustituye al 35B, no al 8B

| | 35B | 8B | **Bonsai** |
|---|---|---|---|
| hechos de fábrica | 10/10 | 10/10 | 9/10 |
| **discriminación** (`d_largo`, `d_conflicto`) | 5/5 | **0/5** | **3/3** |
| controles de UIA | 3/4 | **4/4** | 3/4 |
| velocidad | 26,7 tok/s | **47,8** | 34,3 |
| respuesta con documento largo | 3,4 s | — | 9,3 s |
| **RAM** | 10.764 MB | **1.489 MB** | 2.052 MB |
| carga | 14,4 s | 5,2 s | **4,7 s** |
| VRAM | 8.061 MiB | 11.418 MiB | 9.333 MiB |

**Para Ojo se queda el 8B**: 4/4 en controles contra 3/4, y casi el doble de
rápido. Es su trabajo y lo hace mejor.

**Para el Win+Space, Bonsai es candidato serio a sustituir al 35B**: discrimina
igual de bien —que es exactamente donde el 8B se hunde— con **una quinta parte
de la RAM** (2,0 GB contra 10,8) y cargando en un tercio del tiempo. Paga con
un hecho perdido y con respuestas más lentas en documentos largos (9,3 s contra
3,4), en parte porque tokeniza un 32% más.

### Bonsai razona por defecto

Al probar `logprobs` sin `enable_thinking: false`, el `content` volvió **vacío**
y los tokens generados eran su razonamiento: *«We need answer user's question
in Spanish»*. Misma trampa que Qwen3.6, y el banco ya la evita — pero cualquier
llamada nueva tiene que acordarse.

### Dónde se van los 9,3 s de Bonsai, y cómo se arreglan

La pregunta era si se puede acercar al 8B en velocidad. Primero hay que saber
**en qué se va el tiempo**, y no es donde parecía:

| | tokens | tiempo |
|---|---|---|
| **prefill** (leer el documento) | 18.273 | **14.455 ms** a 1.264 tok/s |
| generación (escribir la respuesta) | 5 | 127 ms a 31,5 tok/s |

**El 99% es prefill.** Eso descarta de entrada la optimización obvia: el
decodificado especulativo acelera la *generación*, así que aquí mejoraría ese
1%. No sirve para documentos largos.

Lo que sí sirve es la **caché de prompts**, y el efecto es enorme:

| | prefill | en caché |
|---|---|---|
| primera vez | 14.661 ms | 0 |
| segunda pregunta | **572 ms** | 17.757 de 18.275 |
| tercera | **568 ms** | 17.759 de 18.268 |

**26× más rápido de la segunda pregunta en adelante** — pero solo con el orden
correcto.

**EL ORDEN IMPORTA, y es la misma lección que la imagen en `ojo.ps1`.** La
caché guarda el **prefijo**. Con la pregunta delante del documento, cada
pregunta nueva cambia el prefijo desde el primer token y **no cachea nada**:
medido, 0 de 18.275 fichas. Con el documento delante y la pregunta al final,
cachea 17.757.

Así que para el Win+Space —pegar un documento y preguntarle varias cosas— la
regla es: **documento primero, pregunta al final**. La primera pregunta cuesta
14 s y las demás medio segundo.

Para Ojo el reparto es el contrario: el prompt es corto (~1.000 fichas, 0,8 s
de prefill) y lo que domina es generar. Ahí Bonsai va a 31,5 tok/s contra los
47,8 del 8B, y **ahí sí** tendría sentido el decodificado especulativo — si
aparece un modelo borrador con su mismo vocabulario.

**CORRECCIÓN.** Aquí decía que Bonsai falló la pregunta de `n-cpu-moe` en este
corpus y la acertó en el del banco, y concluía que «el resultado depende del
corpus». **Es falso, y el error era mío.**

La respuesta —«llama-bench dijo que el óptimo era 18»— está **solo** en
`rice-llm.ps1`, y ese archivo **no estaba** en el corpus que le di
(`MEDICIONES.md` + `presets.ini`). Le pregunté algo que no aparecía en el
texto. Comprobado con `Select-String` sobre los cuatro archivos.

Su discriminación se queda en **3/3 limpio**, sin la sombra que yo le puse.

**Tercera vez con el mismo error** —ya pasó con `d_patron1`, que preguntaba un
valor por defecto que el corpus nunca decía— así que deja de ser mala suerte.
El banco ahora **comprueba que la respuesta esperada aparece en el corpus**
antes de puntuar, y si no aparece marca la prueba `INVALIDA` en vez de
apuntarle un fallo al modelo.

### `logprobs` funciona, y hace medible «estar en duda»

El servidor devuelve la probabilidad de cada token generado:

```
"We"      logprob -1,042  p=35,3 %
" need"   logprob -0,000  p=100,0 %
" answer" logprob -0,047  p=95,4 %
```

Es un parámetro **por petición** (`logprobs: true`), no una bandera del
servidor. Abre la puerta a disparar una búsqueda cuando la confianza baje, sin
preguntarle al modelo si está seguro — que es justo lo que peor hace.

## El corpus del banco estaba vivo, y eso contamina comparaciones

Se descubrió al reventar una prueba: `d_conflicto_cur` pasó de **14.089 a
24.271 fichas** el mismo día, con los mismos archivos. Un 72% más.

El motivo: el corpus apuntaba a los archivos **vivos** del proyecto, y uno de
ellos es **este mismo `MEDICIONES.md`**. Cada vez que documentaba una medición,
el corpus de la siguiente crecía.

**La consecuencia es peor que el error.** Dos modelos medidos a horas distintas
no estaban leyendo el mismo texto, así que **las comparaciones entre modelos
hechas en momentos distintos de la sesión arrastran ese sesgo**. Las que se
hicieron seguidas —el 8B contra el 35B en `d_largo`— sí son válidas; las de
Bonsai, medidas horas después, se tomaron sobre un corpus más grande.

Arreglado: el banco usa `banco-corpus\`, una **copia congelada** con tope de
tamaño por archivo, que deja el total en **64.279 caracteres** — los mismos
~64.000 del corpus original. Refrescarla exige `-RefrescarCorpus` a propósito,
porque hacerlo invalida la comparación con lo medido antes.

Un banco cuyo contenido cambia mientras lo usas no mide nada.

## La guarda que impide culpar al modelo de una pregunta imposible

Antes de puntuar una pregunta de recuperación, el banco comprueba que la
respuesta esperada **aparece en el corpus**. Si no aparece, marca `INVALIDA` y
no cuenta como fallo.

Probado como unidad, sin gastar modelo:

```
corpus CON la respuesta  -> ok=True   invalida=False
corpus SIN la respuesta  -> ok=False  invalida=True
```

Existe porque el error se repitió **tres veces**: `d_patron1` preguntando un
valor por defecto que el corpus nunca decía, y dos veces con `n-cpu-moe 18`,
que vive solo en `rice-llm.ps1`. La tercera acabó en una frase falsa publicada
en este archivo.

## Scripts

| archivo | qué mide |
|---|---|
| `captura/` | captura, reducción y JPEG, por etapas |
| `medir-discos.ps1` | lectura secuencial de cada disco |
| `medir-vlm.ps1` | arranque en frío del servidor + una consulta |
| `preguntar.ps1` | una consulta contra un servidor ya cargado |
| `medir-bucle.ps1` | **el bucle real: captura nueva + consulta** |
| `overlay/` | `--demo` en pantalla, `--prueba <dir>` a PNG sin ventana |
| `uia/` | controles reales de una ventana, con `--demo` de autocomprobación |
| `comparar-precision.ps1` | pinta UIA contra el modelo sobre una captura real |
| `banco-modelos.ps1` | pruebas que se comprueban solas, para elegir modelo |
| `memoria.ps1` | selector de memorias; `-Calibrar` mide su acierto |
| `probar-senalar.ps1` | si apunta cuando toca y se calla cuando no |
| `stt/banco-stt.py` | motores de voz a texto: velocidad, RAM y WER |
| `stt/generar-frases.ps1` | frases en español con la voz del sistema |
| `stt/escuchar.py` | el demonio del oído; `--probar 3` graba y transcribe |
| `memorias/` | las notas, una por tema, con titular y claves |

`ojo.ps1` tiene tres interruptores para volver a medir esto sin tocar código:
`-SinUia` (el punto de partida), `-SinLista` (sin lista en el prompt) y
`-Enganchar` (el enganche que hoy está apagado).

Para levantar el servidor a mano:

```powershell
F:\ai\llama.cpp\llama-server.exe `
  --model F:\ai\models\Qwen3.6-35B-A3B-UD-Q3_K_XL.gguf `
  --mmproj F:\ai\models\mmproj-F16.gguf `
  --ctx-size 8192 --n-cpu-moe 24 --n-gpu-layers 99 `
  --flash-attn on --threads 6 --parallel 1 --load-mode none `
  --port 8099 --host 127.0.0.1
```

---

# 2026-09-22 (madrugada) — Ojo durante la partida

## Lo que se hizo y está medido

### La causa real del desastre del 22, repartida

Dos causas, y yo atribuí mal la primera vez. La escalada de 9 s a 63 s pasó
**antes** de que arrancara nada: Battle.net a las 00:17:29 y Hearthstone a las
00:18:33, y a las 00:16:20 ya iba a 63 s. Esa parte fue mi fuga de overlays.
Los 222 s del final son la fuga **más** el juego.

El mecanismo del juego tiene nombre y fecha: desde el driver **536.40** el
driver de Windows no da error al quedarse sin VRAM, derrama a RAM del sistema
por PCIe en silencio. Caída publicada 5-10×; la nuestra 47,8 → 6,1 tok/s.

### Números nuevos, todos de hoy

| | VRAM del modelo | tok/s | |
|---|---|---|---|
| escritorio solo | — | — | **729 MiB** (antes documenté 1.747) |
| 8B Q8_0 + mmproj | 10.674 MiB | **32,0** | deja 411-597 MiB libres |
| 4B texto, KV q8_0 | **3.619 MiB** | **94,1** | deja **7.632** libres |

`--sleep-idle-seconds` **existe** en nuestro b11056 (visto en su `--help`).
Descartado por el requisito de cero recargo, no por no servir.

`--no-mmproj-offload` descartado con fuente: el proyector en CPU lleva el
encoding de una captura hasta 300 s.

**shadowplay-wgc cuesta un 5%**, no un 36%: 33,84 tok/s sin él contra 32,00 con
él. Medido parándolo. Descartado como sospechoso.

### El hallazgo: durante LoL no hay que mirar la pantalla

League sirve sus propios datos en `https://127.0.0.1:2999/liveclientdata/`,
documentado por Riot y **sin clave**: campeones, ítems con nombre y precio, oro,
las dos composiciones, marcador, minuto. Certificado autofirmado.

Eso borra captura, UIA y visión durante la partida — y sin visión no hace falta
mmproj ni modelo de visión, que es justo lo que no cabía.

Medido hoy, «¿cómo es nuestra composición?»:

| | tiempo | resultado |
|---|---|---|
| 8B mirando una captura (sesión del 22) | 14.427 ms | fallaba |
| 4B con los datos del puerto 2999 | **1.028 ms** | los cinco campeones y sus puestos, exactos |

14 veces más rápido, y además acierta.

## Lo que se arregló

- **`vram_libre_mib` en `ultima-medida.json` y en `sesion.csv`.** La sesión del
  22 no se pudo diagnosticar desde el CSV porque el dato que lo explicaba no
  estaba anotado. Verificado: una fila real trae `"vram_libre_mib":411`.
- **El overlay reafirma su banda de z.** Se creaba encima una sola vez y no lo
  volvía a pedir. Es la lección que glaze-bar ya tenía escrita
  (`crates/glaze-bar/src/main.rs`, «Re-assert TOPMOST too»): el bit sobrevive,
  la posición en el orden z no. El caso que importa aquí es un juego tomando el
  primer plano. Dos veces por segundo, dentro de `presentar`.
- **Bug viejo, encontrado de paso.** `$d.control = $null` reventaba con
  «La propiedad 'senalar' no se encuentra» cuando el modelo contestaba escueto
  y omitía la clave. Solo fallaba al ESCRIBIR — leerla devuelve `$null` sin
  quejarse — y por eso se escondía. Arreglado con `Add-Member -Force`.
- **`[int]` en PowerShell REDONDEA, no trunca.** Lo cazó la prueba de
  `lol.ps1`: 754 s son el minuto 12:34 y salía 13:34, y 1543,7 de oro salían
  1544 — con eso el modelo te diría que te llega para algo de 1544. Los dos con
  `[math]::Floor`.

## El cambio de perfil, verificado en producción

El supervisor mira si hay `LeagueClient`, `League of Legends`, `Hearthstone` o
`Battle.net`. Si los hay, `4b-texto`; si no, el `8b` con visión. Un servidor
vivo con el perfil equivocado se declara enfermo, y el supervisor ya sabe matar
y relanzar.

Observado de verdad, con Battle.net abierto:

```
02:46:00  Qwen3-VL-8B-Instruct-Q8_0   VRAM libre:   417 MiB
02:46:20  (ninguno)                   VRAM libre: 11192 MiB
02:46:40  Qwen3.5-4B-UD-Q5_K_XL       VRAM libre:  7632 MiB
```

Va en el latido de 30 s del supervisor y no en una suscripción a eventos de
proceso, a sabiendas de que eso choca con la regla de «eventos, no
temporizadores»: `LeagueClient.exe` vive minutos antes de la partida, así que
medio minuto sobra. Si midiendo no sobra, toca el evento y **sustituye** a
esto.

## Sobre Vanguard, porque es su cuenta

Vanguard persigue inyección de código, lectura de memoria del juego y software
que pulsa teclas por ti. Ventanas encima aparte no: Discord, OBS y Blitz hacen
eso mismo.

Dos reglas que salen de ahí:

1. **`WDA_EXCLUDEFROMCAPTURE` nunca durante una partida.** El overlay lo usa
   solo en el instante del BitBlt y ya no es su modo por defecto, pero hay que
   garantizarlo: una ventana invisible a las capturas del anti-cheat es
   literalmente la firma de un tramposo. **Sin verificar todavía.**
2. **AltSnap fuera**, que es lo único que inyecta de verdad (`hooks.dll` en
   cada proceso). `rice-modo-juego.ps1` ya lo para.

## Lo que NO está comprobado, y no hay que dar por bueno

- **La VRAM real de LoL.** Los ~4.600 MiB son su recuerdo, no una medición.
- **Que el overlay se vea sobre LoL.** `WindowMode=2` en su `game.cfg`, o sea
  pantalla completa exclusiva. La reafirmación de banda es lo mejor que se
  puede hacer desde el código; si aun así no se ve, toca `WindowMode=1`.
- **La ruta de partida con una partida de verdad.** Se probó con hechos
  inventados por el mismo camino, no contra el puerto 2999 vivo.
- **Por qué el 8B da 32 tok/s y no los 50,16 del banco.** Con todo cerrado.
  Sospecha: el banco corría **sin mmproj**, con 1,08 GB más libres. Sin medir.
  → **Resuelto abajo, y la sospecha era falsa.**

---

# 2026-09-22 (mañana) — tras el reinicio

## El arranque automático, comprobado de verdad

Reinicio real, sin lanzar nada a mano. A los 7 minutos: las cinco piezas
`corriendo`, sin juegos abiertos, y el supervisor había elegido **el 8B con
visión**, que es lo correcto. Es la prueba que llevaba dos días pendiente.

## Los 32 tok/s eran transitorios, y mi hipótesis era falsa

| | tok/s |
|---|---|
| banco histórico (sin mmproj) | 50,16 |
| anoche, tras horas de sesión | 32,0 |
| **hoy, recién arrancado** | **50,66** |

Escribí que sospechaba del mmproj —que el banco corría sin él y por eso iba más
rápido—. **Falso**: hoy el 8B corre *con* mmproj y da 50,66, y además con menos
VRAM libre que anoche (328 MiB contra 411). No era la memoria.

~~Lo que fuera se limpió con el reinicio y ya no es reproducible. Queda como
estado degradado de sesión larga, sin causa identificada, y no como regresión.~~

**CORRECCIÓN (misma tarde): tenía causa, y era reproducible.** Veinticinco
minutos después de escribir lo de arriba, el 8B iba a **12,4 tok/s** sin ningún
juego. Firefox, dwm y Discord habían crecido, y con ~300 MiB libres Windows
desalojó parte del modelo a RAM. Reproducido quitándole 1,4 GB con otro
proceso: de 43 a **4,4** tok/s. El reinicio no «limpió» nada: colocó el modelo
de nuevo antes de que el escritorio creciera. Ver la auditoría, abajo.

## Data Dragon: el catálogo sí, la build no

| | |
|---|---|
| parche | **16.18.1** |
| ítems de la Grieta en caché | **316** |
| tamaño | **54 KB** recortados, de ~1 MB crudo |
| descarga | 102 ms |
| segunda llamada | 367 ms, sin red |

**El campo `recommended` viene VACÍO.** Comprobado con Lux en el 16.18.1: cero
bloques. Riot dejó de publicar las builds recomendadas en Data Dragon.

Eso parte la pregunta «¿qué ítems me armo?» en dos mitades, y conviene tenerlo
claro antes de prometer nada:

| mitad | de dónde sale | estado |
|---|---|---|
| qué me puedo permitir ahora | Data Dragon + tu oro | **hecho** |
| qué conviene este parche, contra quién | web | **pendiente** |

Medido con el 8B sobre los hechos de una partida:

| pregunta | tiempo | resultado |
|---|---|---|
| «¿qué me puedo comprar ahora?» | 1.411 ms | dos ítems reales, dentro del oro |
| «¿cómo es la composición rival?» | 3.490 ms | los cinco, con puesto y nivel |

## Tres trampas de PowerShell, las tres cazadas por la prueba

Ninguna se habría visto leyendo el código.

1. **`@($null)` NO es un array vacío.** Es un array de un elemento nulo, con
   `Count = 1`. Un ítem sin `into` —o sea, un ítem **completo**, justo el que
   hay que proponer— parecía subir a algo, y el filtro los descartaba todos. La
   lista salía vacía siempre.

2. **Una política de certificados es GLOBAL AL PROCESO.** `lol.ps1` instalaba
   una que solo confiaba en loopback, para el certificado autofirmado del
   juego, con un comentario mío que decía «da igual, este proceso no habla con
   nadie más». Dejó de ser verdad al añadir Data Dragon: el CDN se rechazaba
   con *«No se puede establecer una relación de confianza para el canal seguro
   SSL/TLS»*. Ahora loopback pasa siempre y el resto se valida normal.

3. **`Invoke-RestMethod` en 5.1 decodifica como ISO-8859-1** cuando la cabecera
   no trae charset, que es el caso de este CDN. «Espada del guardián» se
   guardaba como «Espada del guardiÃ¡n», y el catálogo está en español: tocaba
   a media lista. Con `WebClient` y UTF-8 explícito, correcto en 5.1 y en 7.

**Y un cuarto, de método:** el `catch` original era mudo. Convertía «no hay
red» y «la caché está rota» en el mismo silencio. Ahora guarda el porqué en
`catalogo_fallo`, y por eso las tres de arriba se encontraron en minutos.

---

# 2026-09-22 (tarde) — auditoría de todo lo cambiado, con A/B

Pedido: revisar cada cambio sin fiarse de la documentación, y quedarse con la
versión que gane en una prueba. Cada cambio es un commit en `git` (el proyecto
no tenía control de versiones; ahora sí), para poder revertir el que pierda.

## El fallo de fondo: el 8B se desalojaba sin juego ninguno

| | tok/s | memoria |
|---|---|---|
| recién arrancado | 50,66 | ~300 MiB libres |
| 25 min después, solo escritorio | **12,4** | parte del modelo en RAM |
| otro proceso le quita 1,4 GB | **4,4** | reproducido a propósito |
| se quita ese proceso, 30 s | 42,1 | se recupera solo |

Windows no da error: desaloja al modelo y el modelo va diez veces más lento. El
contador `SharedUsage` NO sirve para verlo: el 8B lleva 760 MiB en compartida
desde que arranca (búferes de host a propósito). Lo que lo delata es `tok/s`.

### Desglose real (llama-server con `-lv 4`)

| pieza | MiB |
|---|---|
| pesos Q8_0 | 7.670 |
| KV f16 a 8192 | 1.152 |
| visión: cómputo (calentamiento a 1472×1472) | 372 |
| LLM: cómputo | 128 |
| mmproj + contexto CUDA | ~1.400 |

### Palancas, una a una (banco de visión fijo + banco de texto)

| config | VRAM | tok/s | leer | señalar | texto |
|---|---|---|---|---|---|
| Q8_0 (antes) | 10.720 | 48,8 | 4/5 | 2/6 | 12/18 |
| + KV q8_0 | 10.192 | 50,8 | 4/5 | 2/6 | — |
| + sin calentamiento | 10.061 | 50,7 | 4/5 | 2/6 | — |
| Q8_0 + mmproj Q8_0 | 9.641 | 50,7 | 4/5 | 3/6 | — |
| **Q6_K** + mmproj F16 | **8.279** | **62,5** | 4/5 | **3/6** | **12/18** |
| Q6_K + mmproj Q8_0 | 7.912 | 62,6 | 4/5 | 3/6 | — |

`--image-max-tokens 1024` no cambia nada (el búfer lo fija el calentamiento):
descartado.

**Elegido: Q6_K + mmproj F16 + KV q8_0 + sin calentamiento.** Q6_K genera más
rápido porque hay menos bytes que mover por ficha; el único que pierde es el
prefill de 22k fichas (6,8 → 7,5 s), que Ojo no usa. El mmproj se queda en F16:
el margen ya sobra y es lo más sensible de la visión. Descargas verificadas
contra el SHA-256 que publica Hugging Face.

### La prueba que importa: repetir el robo de VRAM

| ladrón | libres | 8B antes | 8B después (Q6_K) |
|---|---|---|---|
| ~1,4 GB | 870 | 43 → **4,4** | 61 → **62-64** |
| ~2,3 GB | 297 | — | 63 → 57 (empieza a notarse) |

**Margen: ~2,3 GB de crecimiento de otras aplicaciones**, contra ~300 MiB antes.

## Latencia de cada pregunta: dónde se iban ~930 ms

Marcas de tiempo nuevas en `ultima-medida.json` (`marcas`):

| tramo | antes | ahora |
|---|---|---|
| arrancar PowerShell + leer el script | ~240 | ~240 |
| cargar funciones + memoria.ps1 | ~143 | ~143 |
| comprobar el servidor | ~44 | ~40 |
| **overlay: matar, lanzar y `Sleep 400`** | **~430** | ~15 |
| `nvidia-smi` en el camino | 49 | 0 (después de dibujar) |

Y **el `Sleep 400` hacía que el modelo se viera a sí mismo**: la captura se
tomaba con el overlay ya pintado. Comprobado con la imagen enviada: traía la
píldora «mirando» y el bocadillo «Déjame ver…» tapando el centro inferior.
Ahora se captura antes de abrir el overlay (comprobado con dos capturas).

De soltar la tecla a dibujo, mediana de 10:

| | total | fontanería |
|---|---|---|
| solo ojo.ps1, antes de la auditoría (Q8_0) | 3.693 | 927 |
| captura antes del overlay | 3.194 | 523 |
| + Q6_K, /props, etc. | 2.280 | 483 |
| camino del atajo, dos procesos | 2.614 | 843 |
| **camino del atajo, un proceso 5.1** | **2.091** | 506 |
| camino del atajo, un proceso 7 | 2.312 | 548 |

## Fallos encontrados por el camino (con su reproducción)

1. **Cuelgue al levantar el servidor.** `Start-Process -RedirectStandardError`
   hace heredar handles: `llama-server` se quedaba con la salida de `ojo.ps1`,
   y `hablar.ps1` (que la lee con `Out-String`) esperaba para siempre.
   Reproducido: colgado a 60 s con el servidor listo. Arreglado: 8,6 s.
2. **Tres `llama-server` a la vez en el 8099.** Windows deja escuchar a varios
   en el mismo puerto (cpp-httplib activa `SO_REUSEADDR`). 285 MiB libres.
   Arreglado: si ya hay uno en el puerto, se le espera. Probado con dos
   arranques simultáneos: queda uno.
3. **`$SERVIDOR` contra el parámetro `-Servidor`**: PowerShell no distingue
   mayúsculas. El script esperaba 400 s a un servidor ya levantado. **Quinta**
   vez que esa trampa muerde aquí.
4. **El `param()` de un archivo cargado con punto** pisa las variables de quien
   lo carga: el `-ComoModulo` de `ddragon.ps1` apagaba `lol.ps1` entero, con
   código 0. **Sexta.** Arreglo de fondo: los archivos que se cargan con punto
   ya no tienen `param()`.
5. **La prueba de `lol.ps1` no podía fallar**: apuntaba fallos en
   `$script:fallos` y miraba un `$fallos` local vacío.
6. **Un scriptblock como callback de certificados** rompe TODO el HTTPS nuevo
   del proceso en 5.1 («No hay ningún espacio de ejecución disponible»): .NET
   lo llama desde otro hilo. Mi primera prueba decía que funcionaba porque
   reutilizaba una conexión ya abierta. Sustituido por `curl.exe -k` (22 ms,
   contra 202 ms de compilar la clase C#).
7. **Las etiquetas de ítem de Riot mienten**: Bandlemusa lleva `AttackSpeed` y
   no da velocidad de ataque; el Elixir de cólera lleva `Damage` y es un
   consumible. El filtro pasa a mirar las **estadísticas**. Y mi prueba de ese
   filtro era **circular** (comprobaba con las mismas etiquetas): 59/59 mientras
   a Jinx se le proponían un incensario de soporte y un elixir. Ahora compara
   contra listas escritas a mano.
8. **`@( @(a,b) @(c,d) )` aplana** los pares en una lista suelta. Hace falta
   la coma unaria.

## Partida de League

- **Identidad**: sin `#tag`, probando `riotId`, `riotIdGameName` y
  `summonerName` (fallo abierto de Riot #857). Si no hay exactamente una
  coincidencia, lo dice y da los equipos por color.
- **Puerta**: solo `League of Legends` (el cliente no abre el 2999 y costaba
  ~2 s por pregunta en selección de campeón).
- **Prompt propio de partida**, datos delante de la pregunta, y el más fuerte
  de cada equipo **calculado** (el 8B no sacaba bien el máximo de cinco KDA):

| | aciertos | ms |
|---|---|---|
| prompt de pantalla | 14/16 | 1.142 |
| **prompt de partida** | **16/16** | **535** |

- Propuestas de compra con 3.500 de oro, ahora:
  - Lux: Rabadon, Zhonya, Llamasombría, Amanecer y anochecer, Creagrietas, Bastón del Vacío
  - Jinx: Filo infinito, Fuerza de trinidad, Cortasendas, Lord Dominik, Rey arruinado, Navaja de asalto
  - Garen: Filo infinito, Sanguinaria, Fuerza de trinidad, Baile de la muerte, Cortasendas, Hidra titánica

## Cambio de perfil

| | entrar en partida | volver a la visión |
|---|---|---|
| antes | 57 s | **154 s** |
| después | 7 s (peor caso ~35) | 33 s |

La vuelta tardaba dos minutos y medio porque `Grace = 120` impedía incluso mirar
el perfil tras arrancar el de texto. Ahora el cambio se hace en el mismo latido
y la espera por carga lenta se mide por la edad del proceso.

## Números de control en la voz

2 de las 10 respuestas grabadas que señalaban un control decían el número
(«la lista de controles, número 23»). `decir.ps1` lo sustituye por el nombre;
6 comprobaciones con frases reales.

## Una hora de uso normal (18:11-19:11)

13 muestras, cada 5 minutos, con el escritorio de siempre: **63,0-63,7 tok/s**
en 11 de 13, y **~2.900 MiB libres estables** toda la hora (2.877-2.939).

Dos muestras más bajas, 53,2 y 54,5 (18:36 y 18:41), con la VRAM libre
**igual** que en las demás. No es desalojo — ese da 4-12 tok/s y baja la VRAM
libre —, es otra cosa usando la GPU a la vez (vídeo, la grabación continua).
Volvió sola a 63 en la siguiente. Antes de la auditoría, la misma hora habría
acabado en ~12 tok/s: fue lo que pasó esta mañana en 25 minutos.

## Voz: banco de motores (2026-09-23)

Seis frases (`voz/frases.txt`), en caliente, con el cliente de LoL abierto y
el 4B cargado. «Primera» = sintetizar la primera frase de cada respuesta, que
es lo que se espera si se habla frase a frase. Criterio escrito antes de medir:
gana la mejor puntuada a ciegas entre las que empiezan en **< 400 ms**.

| motor | dónde | primera (peor de 6) | RTF medio | ¿cumple? |
|---|---|---|---|---|
| SAPI Sabina (actual) | CPU | 38-102 ms (frase entera) | ~0,01 | sí |
| **Piper es_MX-claude-high** | CPU | **336 ms** | 0,063 | sí |
| Supertonic 3, 8 pasos | CPU | 2.261-3.473 ms | 0,34-0,42 | no |
| Supertonic 3, 4 pasos (F1-F5) | CPU | 1.367-1.738 ms | 0,24-0,31 | no |
| Chatterbox Multilingual | GPU, 3,8 GB | 20.068 ms | 2,48 | no |

- Supertonic no se acerca a lo anunciado (167× tiempo real en un M4 Pro): aquí
  va a 3-4× tiempo real. Con 2 pasos, 731 ms para una frase de 6 s. Los hilos
  (auto o 6) no cambian nada.
- Chatterbox Multilingual genera audio de duración normal (no alucina); es
  lento de verdad. El Turbo (solo inglés) iba a RTF 0,6: el multilingüe no
  tiene esas optimizaciones.
- Voces naturales de Windows (Dalia): sin medir. El adaptador pide
  administrador y la voz que funciona con él solo está en un espejo de
  terceros.

**Escucha a ciegas, ronda 1** (naturalidad / personalidad, 1-5): Supertonic
F4 **4/4**, F2 3/3, F1 3/2, Piper claude 2/1, Chatterbox 1/2, Supertonic F3
1/1, F5 1/1, SAPI Sabina 1/1. Fallos que marcó el usuario en casi todas:
«Jax» leído en inglés, «AP» como palabra, «4300» mal dicho, y acento de España
en las Supertonic.

Los fallos de pronunciación son del TEXTO: `voz/texto_voz.py` pasa números a
palabras y reescribe nombres en inglés («Yax», «a pe»). Vale para cualquier
motor.

**Ronda 2, medida** (texto ya corregido, 7 frases):

| motor | primera (peor) | RTF | ¿cumple? |
|---|---|---|---|
| **Supertonic 3 F4, GPU**, 8 pasos | **295 ms** | 0,044 | sí |
| **Supertonic 3 F2, GPU**, 8 pasos | **297 ms** | 0,040 | sí |
| Piper es_MX-claude-high | 399 ms | 0,048 | justo |
| Piper es_AR-daniela-high | 1.127 ms | 0,227 | no |

**Escucha a ciegas, ronda 2** (naturalidad / personalidad / pronunciación):
**Supertonic F2 GPU 5/3/5** (elegida), F4 GPU 3/4/3, Piper Daniela 4/2/4,
Piper Claude 2/1/3. En producción: servidor residente, voz a ~300 ms del
subtítulo, 725 MiB de VRAM.

## Personalidad (GLaDOS) y aciertos, 8B Q6_K

| prompt | partida inventada | frases reales | ms |
|---|---|---|---|
| sin carácter | 16/16 | 6/8 | 587 / 900 |
| v1: «pulla si cabe» | 14/16 | 7/8 | 965 / 1.099 |
| v2: latino, pulla ≤ 8 palabras al final | 15/16 | 6/8 | 746 / 962 |
| **v3: v2 + un ejemplo** | **16/16** | **6/8** | 754 / 956 |

- v1 se comía campeones en la composición para hacer el chiste, y hablaba
  de «vosotros». El ejemplo de v3 es lo que lo arregla.
- Los 2 fallos de las frases reales son los mismos sin carácter: a «¿qué
  daño hace el equipo rival?» contesta «2 de daño mágico y 3 de daño
  físico» (cuenta campeones, no concluye). Estaba 8/8 cuando se midió: es
  una regresión previa, pendiente.
- Visión con v3: leer 8/10 (las dos «falladas» dicen «las doce y
  diecisiete» en palabras, correcto; el banco busca «12:17»), señalar 8/12;
  antes 4/5 y 3/6. Sin pérdida.

En GPU hace falta `onnxruntime-gpu[cuda,cudnn]` (CUDA 13) y
`onnxruntime.preload_dlls()` antes de crear la sesión; sin eso, «LoadLibrary
failed for cudnn64_9.dll».

## Verdad: comprobar lo que dice y buscar lo que falta (2026-09-23)

Punto de partida, medido: a «¿qué día es hoy?» contestaba «un día de trabajo,
como siempre»; a «¿a cuánto está el dólar?», «no puedo darte el tipo de
cambio». Sin herramientas: la captura reducida a 1280, la lista de controles y
notas.

Lo que se añadió (`ojo.ps1`, `buscar.ps1`, `buscador.py`, `ocr.ps1`, captura):

- **Hechos del sistema** en cada pregunta: hora, fecha, ventana activa; y RAM,
  VRAM, CPU y GPU si se pregunta por ellas (el OCR de la barra lee «16 .5/126»
  por «10.5/12G»: su letra es diminuta).
- **OCR a tamaño real, ampliado ×2**, solo si la pregunta es de pantalla: a ×1
  leía «B.94kWh», a ×2 «6.94kWh». ~450 ms. Sus líneas se pueden señalar
  (`{"texto": N}`) como los controles.
- **`decir` / `pulla` / `buscar`**: el humor va aparte y no puede llevar cifras.
- **Verificador en código** (`Verificar-Decir`, 11 comprobaciones en
  `prueba-verificar.ps1`): cifras y nombres propios de `decir` contra todas las
  fuentes. Lo que falta → OCR → internet con una segunda pasada. Si ni así,
  «busqué X, pero no lo encontré confirmado».
- **SearXNG local** (solo DuckDuckGo, 127.0.0.1:8888, ~700 ms por consulta),
  la consulta del modelo y la frase literal a la vez, 3 páginas leídas en
  paralelo. Búsqueda adelantada para lo que huele a actualidad. Cita del sitio
  añadida en código si el modelo no la da.

`banco-verdad.ps1` (8 preguntas: hora, fecha, dólar, último mundial, reloj y
VRAM de la barra, un correo que no está, workspaces):

| versión | aciertos | inventos | ms medio |
|---|---|---|---|
| antes | 5/8 | — | 3.075 |
| primera | 5/8 | 0 | 5.230 |
| **final** | **8/8** | **0** | 5.476 |

Lo que costó llegar ahí, por si vuelve:
- El modelo metía **años de su entrenamiento** en la consulta («último mundial
  2024» → contestó el de 2024). Regla: sin años que el usuario no dijo; si las
  fuentes discrepan en fecha, gana la más reciente respecto a HECHOS.
- **«A cuánto» disparaba el OCR** (~1 s) en una pregunta de internet: el OCR
  va ahora solo con palabras de pantalla.
- **Rendirse** («no puedo darte…») también busca, salvo en preguntas de sus
  cosas (correo, archivos): ahí internet no sabe nada.
- **DuckDuckGo corta a ratos** en ráfagas (0 resultados y al minuto 10): un
  reintento.

Sin pérdida en los demás bancos (8B Q6_K, con Hearthstone abierto, así que
los ms no se comparan): partida 16/16, frases reales **8/8** (antes 6/8: la
regla de nombrar QUIÉN hace cada daño arregla «¿qué daño hace el equipo
rival?»), visión leer 8/10 y señalar 8/12.

**Hearthstone: 406 MiB de VRAM** (medido con el juego abierto). Sale de la
lista del supervisor: Ojo conserva la visión ahí.

## Decisiones tipadas «a lo Jev» contra reglas (2026-09-23)

Jev (TypeSafe AI, acceso anticipado desde el 15-09-2026) devuelve decisiones
con tipo y probabilidad en vez de texto. Es de nube, con lista de espera y
solo texto: se probó el PATRÓN con el modelo local (`decidir.ps1`: esquema
JSON + logprobs, entrada solo la pregunta) contra `Decidir-Con-Reglas`, en
`banco-decidir.ps1` (49 preguntas × 7 decisiones, etiquetas a mano):

| | aciertos | ms |
|---|---|---|
| reglas | 314/343 (91,5%) | ~0 |
| modelo tipado (8B) | 317/343 (92,4%) | 939 (mediana) |
| reglas corregidas con lo que cazó el banco | 321/343 | ~0 |

Criterio previo (ganar y < 200 ms): no entra. Y su confianza no avisa:
muchos fallos llevan 1,0. Las reglas corregidas se ajustaron sobre este mismo
banco: parte es sobreajuste.

## Enganche al texto dicho

A «¿dónde está el reloj?» decía «superior izquierda» (está en el centro) sin
señalar nada. Si pide un sitio y lo dicho contiene una línea del OCR
(comparando sin espacios: el OCR lee «12 : 44»), se señala esa línea:
(0,49; 0,01), el reloj.

## Tras los retos del usuario (2026-09-23, tarde)

| reto | antes | ahora |
|---|---|---|
| «¿Cuánto virra me estoy usando?» | «23% de la batería de tu portátil» | 10,5 de 12 GB en tu RTX 4070 SUPER |
| «¿cuánta batería me queda?» | — | PC de escritorio, sin batería |
| último mensaje de Irene (chat inventado) | leía uno del usuario | «Perfecto, trae el postre», 3 de 3 |
| botón de enviar que no existe | «abajo a la derecha» | «No lo veo en tu pantalla…» |
| buscador | «no contesta» en 3 retos | 6 motores a la vez; si falla, dice cuál |
| capital de Australia | «nada confirmado» | Canberra, citando |
| último mundial de LoL | «nada confirmado» | T1, Worlds 2025, según strafe |

Causas:
- **Buscador**: DuckDuckGo y Qwant con CAPTCHA, Brave «too many requests»,
  Bing 0 resultados sin avisar en consultas largas; los provocó nuestro
  volumen (~40 búsquedas en minutos). Ahora DuckDuckGo, Bing, Mojeek,
  Startpage, Yep y Wikipedia a la vez, reserva Google/Yahoo/Presearch/Brave/
  Qwant, y 6 consultas por minuto como tope. Sin proxies ni sigilo.
- **Nunca se buscaba sin la búsqueda adelantada**: `@($null).Count` es 1, y
  «¿hay fuentes?» salía que sí sin haber buscado.
- **Verificador**: «T1» en mayúsculas contra evidencia en minúsculas; y
  «Canberra» contra «Camberra» (una letra en nombres largos vale).
- **El oído**: «virra» → VRAM, «Yoyos» → JoJo (`vocabulario.txt`).
- **El 8B no razona el lado del chat** ni con la regla en el prompt: el
  último mensaje de cada lado se calcula en código.

Extractor de texto, mismas 17 páginas (`ab-extractor.ps1`):

| | páginas con el dato | ms |
|---|---|---|
| **regex propio** | **4** | 60-420 |
| Trafilatura | 2 | 1.000-2.800 |

Memoria de personas (`prueba-personas.ps1`, sobre una copia): 7/7 tras
arreglar lo que el 8B hacía mal con nombres («Me llamo Bishop» lo decía como
suyo) y con fichas vacías (a Melly le atribuía el perfil del usuario).

Pullas: 0 en 12 preguntas seguidas (antes, en todas). Partida 16/16,
frases reales 8/8, verdad 7/8 con 0 inventos (el 8.º, el mundial,
arreglado después).

## Pantalla, conocer personas y pruebas a la vista (2026-09-23, noche)

Leer la pantalla: el «8/10» de `banco-vision` mandaba la captura de 1280x720
SOLA al modelo, sin el OCR ni el verificador que usa Ojo de verdad.
`banco-pantalla.ps1` mide el camino real (`ojo.ps1 -Imagen`) sobre 27
imágenes trampa dibujadas con la verdad conocida, a 1080p, 1440p y 900p,
más los 10 casos de la captura de referencia:

| | trampas | referencia | total |
|---|---|---|---|
| imagen sola al modelo | 21/27 | 7/10 | 28/37 |
| **camino real** | **27/27** | 5/10 | **32/37** |

Los 5 que fallan son de la referencia de 1280x720: el OCR lee «22:27» por
12:17 y «219w» por 218 W. En uso real la captura es nativa. Lo que se
arregló está en el commit 2c8d653 (señalar por palabras de la pregunta, a
nivel de palabra; segunda lectura con contraste; no truncar el OCR; «marca»
no es señalar; nada de internet para preguntas de pantalla).

Conocer personas (`conocer.ps1`, `prueba-conocer.ps1` sobre una copia): 12
comprobaciones sin modelo y 6 turnos con él, todo OK. Salió:

- A «Luis juega vóley los sábados» el 8B dejó `recordar` vacío en 2 de 2
  pasadas: si contó algo y no se apuntó, se guarda su frase tal cual.
- `Historial-Texto` reventaba en cuanto había historial (PowerShell 5.1:
  `ConvertFrom-Json` da el array como UN objeto) y se llevaba la memoria de
  personas entera: las respuestas fijas dejaban de salir.
- La pregunta de seguimiento a veces es sobre el usuario («¿cuál es TU
  equipo favorito?») en vez de sobre Luis. Sin arreglar.

Chat: con el mensaje de la otra persona ya etiquetado en el prompt, el 8B
contestó el del usuario (2 de 2, también con el código de antes: no lo
causó el cambio). «¿Qué me envió X?» se contesta ahora con el OCR, sin
modelo.

Memorias: sin BOM, PowerShell 5.1 las pasaba al modelo en mojibake
(«cachÃ©»).

Regresión tras todo: verdad 8/8 con 0 inventos, partida 16/16, frases
reales 8/8, personas 7/7, verificador 17/17, chat 2/2. Todas las pruebas,
con sus fallos, en `pruebas-resumen.json` (`resumen-pruebas.ps1 -Correr`).

## Pantallas reales, VRAM por proceso y voces ligeras (2026-09-23, noche)

`banco-pantalla` sobre los dos monitores congelados (`congelar-escena.ps1`),
con la verdad del sistema y de UI Automation, más las 27 trampas dibujadas:

| | trampas | pantallas reales | total |
|---|---|---|---|
| imagen sola | 21/27 | 8/13 | 29/40 |
| **camino real** | **27/27** | **13/13** | **40/40** |

Primera vuelta con pantallas reales: señalar 0/6. El control nombrado en
la pregunta se perdía (`[string]$Controles` pisaba `$controles`), ganaba
una línea del OCR con una sola palabra en común, y Discord da por UIA
botones que no se ven. Arreglado en `ojo.ps1`; el banco solo pide controles
cuyo nombre se ve. «GPU 52°» leído «520»: corregido por plausibilidad.

VRAM por proceso sin juego (`vram.ps1`): 8B 8.540 MiB, voz 811, DaVinci
728, Firefox 556, dwm 507, Discord 152, otros 497. Usada: 11.473 de 12.282
(nvidia-smi).

Voces (`voz/probar_ligera.py`, sin nada más corriendo):

| | primer audio | RTF | dónde |
|---|---|---|---|
| F2 actual | 271-546 ms (frase entera) | 0,03-0,07 | GPU, ~811 MiB |
| Pocket TTS spanish_24l, lola | 195-276 ms | ~0,78 (1,25 núcleos) | CPU, 1,7 GB RAM |
| Pocket TTS spanish, lola | 82-102 ms | ~0,26 | CPU; silencios largos |
| Pocket TTS spanish_24l, eve | 190-233 ms | ~0,69 | CPU |

Escucha a ciegas 3 en la página MVP.