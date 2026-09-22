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
el supervisor primero, así que