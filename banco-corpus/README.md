# Ojo

Un acompañante que, **a demanda**, mira la pantalla, escucha la pregunta,
responde hablando en español, dibuja encima para señalar y —en modo agente—
actúa.

Inspirado en [heyclicky.com](https://www.heyclicky.com/) (cerrado, solo macOS,
de pago) y en la copia libre
[clicky-windows](https://github.com/Bitshank-2338/clicky-windows) (MIT, Python,
**solo lectura**: señala pero nunca toca el ratón).

Plan completo en `~/.claude/plans/wobbly-marinating-bubble.md`.

## La regla del proyecto

**Nada se da por bueno sin medirlo.** Cada etapa tiene presupuesto de latencia y
un binario que la cronometra aislada. Los números de este README salen de
ejecutar el código en este equipo, no de estimaciones.

## Presupuesto de latencia, hasta la primera palabra hablada

| etapa | presupuesto | medido |
|---|---|---|
| captura + JPEG | 20-35 ms | **27,7 ms** (p95 32,4) |
| STT | 300 ms | **235 ms** — Parakeet int8 en CPU, no Whisper |
| VLM primer token | 400-900 ms | **151 ms** con caché caliente, 1.026 en frío |
| TTS primer audio | ~40 ms | pendiente |
| **total** | **0,8-1,3 s** | pendiente de juntarlo (Fase E) |

El renglón del STT decía «300 ms, heredado de voicebox». Se midió y whisper-base
tarda **885 ms** aquí; el presupuesto sólo lo cumple Parakeet. Heredar números
sale caro.

Solo se consigue **transmitiendo**: el TTS arranca con la primera frase del VLM,
sin esperar la respuesta entera. Se optimiza *tiempo hasta la primera palabra*,
no tiempo total.

## Estado

- [x] **Captura** (`captura/`) — medida, con una decisión de diseño corregida
- [x] **Overlay** (`overlay/`) — cursor, anillo, trazos, bocadillo, subtítulos
- [x] **Bucle funcional** (`ojo.ps1`) — captura → modelo → dibujo, sin voz
- [x] **Precisión fina** (`uia/`) — rectángulos reales del sistema, 4/4 en Discord
- [x] **Memorias temporales** (`memoria.ps1`) — selector determinista, 14/14
- [x] **Oído** (`stt/`) — Parakeet int8 en CPU, 235 ms; atajo sin probar a mano
- [x] **Arranca solo** — tres filas en `rice-supervisor.ps1`; nada que lanzar
- [ ] TTS en español (Fase D)

## Arranca con el equipo

No hay ningún comando que lanzar. `rice-supervisor.ps1` levanta las tres piezas
al iniciar sesión y las revive si se caen:

| pieza | cómo se comprueba | por qué así |
|---|---|---|
| `ojo-oido` | mutex `Global\ojo-oido` + `/salud` | es un `python.exe`, como voicebox |
| `ojo-hotkey` | mutex `Global\ojo-hotkey` | es un `AutoHotkey64`, como el otro |
| `ojo-vlm` | sonda a `:8099/health` | es un `llama-server`, como el 35B |

**Para jugar o editar**, `rice-modo-juego.ps1` libera **10 GB de VRAM**
(11.748 → 1.747 MiB) y `-Volver` lo devuelve. `-Estado` dice qué hay puesto.
- [ ] TTS en español (Fase D)
- [ ] Pre-calentamiento del prompt (Fase E)
- [ ] Banco de precisión (Fase F)
- [ ] Modo agente (Fase G)

Pendientes de estética en `TODO.md` — decisión tomada: primero funcional.

## Cómo se usa hoy

```powershell
cd D:\2026-projects\ojo
.\ojo.ps1 "donde esta el boton de exportar?"
.\ojo.ps1 "que aplicacion es esta?" -Segundos 20
.\ojo.ps1 -Servidor      # solo levanta llama-server y sale
.\ojo.ps1 -Modelo 8b "..."          # el 8B, que cabe entero en VRAM
```

Banderas para volver a medir sin tocar código:

| bandera | qué hace |
|---|---|
| `-SinUia` | ni lista de controles ni enganche: el punto de partida |
| `-SinLista` | sin lista en el prompt, pero deja el enganche |
| `-Enganchar` | engancha la coordenada al control real (apagado: empeora) |
| `-MaxControles N` | cuántos controles van en el prompt (40 por defecto) |
| `-CacheRam N` | MiB de caché de prompts en RAM (1024; el defecto de llama es 8192) |
| `-Modelo 35b\|8b` | cuál de los dos servir |
| `-SinMemoria` | sin memorias temporales, para medir lo que aportan |
| `-Memoria <nombre>` | carga esa memoria a la fuerza, sin puntuar |

## memorias/

Notas cortas de un solo tema que se cargan cuando la pregunta las pide. **No es
gestión de contexto: es el arreglo de un fallo medido.** El 8B se equivoca
cuando en el contexto hay otro valor asignado a la misma clave por la que se
pregunta —0/5 en tres casos— y con una nota corta acierta 5/5.

Curar **eligiendo archivos no sirve**: se midió, y un valor rival puede estar
repartido en varios. Por eso son notas escritas a mano y no referencias.

```powershell
.\memoria.ps1 -Listar      titulares y presupuesto
.\memoria.ps1 -Calibrar    acierto del selector contra el conjunto anotado
.\memoria.ps1 -Olvidar     descarga todo
```

El selector es determinista a propósito: elegir entre candidatos parecidos es
justo lo que el modelo hace mal, así que no elige él. Si la mejor puntuación no
le saca 1,6× a la segunda, pregunta.

Captura la pantalla del monitor activo, se la manda al modelo, y dibuja encima
lo que responde: una frase en los subtítulos y, si apunta a algo, el cursor con
su anillo y las cajas o flechas que haya pedido.

Todavía **se escribe la pregunta**: la voz son las fases C y D. Este bucle existe
para probar antes lo arriesgado — si el modelo acierta *dónde* están las cosas.

Piezas sueltas, cada una utilizable por su cuenta:

```powershell
overlay\target\release\ojo-overlay.exe --demo            secuencia guionizada
overlay\target\release\ojo-overlay.exe --prueba escenas\ escenas a PNG
overlay\target\release\ojo-overlay.exe --servir          lee escenas JSON de stdin
captura\target\release\ojo-captura.exe --repetir 20      mide la captura
```

El overlay en `--servir` es un lienzo tonto: una escena JSON por línea. Quien
orquesta puede ser un script hoy y un binario mañana.

## captura/

```
ojo-captura.exe              una captura, tiempos en JSON
ojo-captura.exe --repetir 20 mediana y p95
ojo-captura.exe --salida x.jpg
ojo-captura.exe --todo       escritorio virtual entero, para comparar
ojo-captura.exe --demo       autocomprobación
```

### Lo que cambió al medir

La primera versión capturaba el escritorio virtual entero. Aquí son **4480×1440**
(dos monitores: 1920×1080 + 2560×1440), y al reducir el lado mayor a 1280 quedan
**411 px de alto**. Ningún modelo de visión lee texto de interfaz con esa altura.

Capturando solo el monitor de la ventana activa:

| | monitor activo | escritorio entero |
|---|---|---|
| lo que ve el modelo | **1280×720** | 1280×411 |
| blit mediana | **15,5 ms** | 34,7 ms |
| total mediana | **27,7 ms** | 47,2 ms |
| p95 | **32,4 ms** | 55,6 ms |

Arregla la resolución **y** casi divide el tiempo por dos. Es exactamente el
motivo de medir antes de construir encima.

### Decisiones y por qué

**BitBlt, no Windows.Graphics.Capture.** WGC abre una sesión de captura y eso
cuesta decenas de ms en frío, que aquí se pagarían en cada pregunta. BitBlt lee
el escritorio ya compuesto. Contrapartida real: no ve contenido en superposición
por hardware (algunos juegos a pantalla completa). Si llega a importar, se añade
WGC como segundo camino.

**No se reutiliza `shadowplay-wgc`,** aunque ya capture a 60 fps. Codifica a HEVC
por hardware directo a un anillo en RAM y no guarda fotogramas crudos: habría que
decodificar. Y añadir trabajo a su callback ya se midió una vez — hundió el vídeo
de 55 a 21 fps.

**Vecino más cercano al reducir.** El destinatario es un modelo, no un ojo: un
remuestreo con pesos gastaría presupuesto para mejorar algo que nadie mira.

**1280 px de lado mayor, JPEG al 80.** Más resolución multiplica los tokens sin
mejorar el acierto.

## Lo que ya existe en el rice y se va a reutilizar

| pieza | dónde |
|---|---|
| overlay con alfa por píxel | `ws-slide` — `UpdateLayeredWindow(ULW_ALPHA)` |
| **overlay invisible a la captura** | `ws-slide:159` — `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` |
| atajo global | AutoHotkey + evento con nombre |
| STT y barge-in | voicebox — Whisper base 300 ms, TEN VAD |
| llama.cpp | `F:\ai\llama.cpp\llama-server.exe` (b11056, en el NVMe) |

Esa segunda fila evita el bug más tonto posible: sin ella la IA vería sus propias
flechas en la captura siguiente.

## Modelos

**Visión.** El problema se llamaba *GUI grounding* y su banco es ScreenSpot-Pro,
donde Qwen3-VL-8B marca 52,7. **Eso ya no es el cuello.** Desde que `uia/` lee
los rectángulos reales, el modelo no adivina coordenadas: elige un nombre de una
lista. Medido en Discord, 4 aciertos de 4.

Lo que sí sigue pidiendo un modelo bueno es *cuál* elegir. Medido: con 40
controles acierta 3/4 y con 150 también 3/4 — **la longitud de la lista no es el
problema, la discriminación sí**.

Trampa que sigue vigente: Ollama no carga el sidecar `mmproj` de los GGUF de
visión nuevos. Hay que usar llama.cpp directo.

Dos modelos en disco, y `ojo.ps1 -Modelo 35b|8b` cambia entre ellos:

| | 35B (`Qwen3.6-35B-A3B` Q3_K_XL) | **8B (`Qwen3-VL-8B` Q8_0)** |
|---|---|---|
| tamaño | 16,8 GB | 8,11 + 1,08 de mmproj |
| ¿cabe en 12,28 GB de VRAM? | **no, ni a 1 bit** | **sí, entero** |
| reparto a CPU | `--n-cpu-moe 24` | ninguno |
| RAM tras las consultas | 10,45 GB | **2,4 GB** |
| carga (desde NVMe) | 14,7 s | **5,1 s** |
| aciertos de control | 3/4 | **4/4** |
| primer token, caché caliente | 510 ms | **151 ms** |

El 8B es el predeterminado. Gana en todo menos en VRAM, que es donde se le pidió
que gastara.

`--cache-ram 1024` es obligatorio en los dos: el defecto de llama-server son
8.192 MiB de RAM para la caché de prompts, y era la mayor fuga que teníamos.

**Voz.** Descartados por medición propia: Chatterbox Turbo tiene suelo de 1,3 s
por petición, y Kokoro, pese a sus 682-727 ms, «en español destroza los
titubeos». Candidato a medir: **Piper** (RTF ~0,03, primer audio ~40 ms, voces
es_ES y es_MX), asumiendo que suena más robótico.
