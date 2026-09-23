# Ojo — pendientes

Plan completo en `~/.claude/plans/wobbly-marinating-bubble.md`.
Números en `MEDICIONES.md`.

## Cerrado el 2026-09-23

- [x] Voz: Supertonic F2 en GPU, residente (`voz/servidor_voz.py`), elegida en
      dos escuchas a ciegas; texto corregido para hablar (`voz/texto_voz.py`).
- [x] Carácter GLaDOS en lo que dice, sin perder aciertos; el humor va en su
      propio campo y se aprende de internet cada día (`humor.ps1`).
- [x] **Internet con fuentes**: SearXNG local (DuckDuckGo, reserva
      Brave/Mojeek/Qwant), `buscar.ps1`, verificador en código, cita del sitio.
      `banco-verdad.ps1`: 5/8 → 8/8, 0 inventos.
- [x] Hechos del sistema (hora, fecha, ventana, RAM/VRAM/CPU/GPU) y OCR a
      tamaño real ×2 para preguntas de pantalla.
- [x] Workspaces de GlazeWM.
- [x] Recomendar aumento de la pantalla, con precarga de la build.
- [x] VRAM de Hearthstone: 406 MiB → fuera de la lista; conserva la visión.
- [x] `--oculto` imposible con una partida de LoL abierta.
- [x] Estética del overlay: los siete puntos de abajo.
- [x] Rice sincronizado a `dotfiles` (commit local; el `push` es tuyo).

## Queda, y por qué no se hizo hoy

- [ ] **Proceso residente + atajo fuera de AHK.** Ahorro medido: 370-490 ms
      por pregunta (`arranque_ps`), de 2,5-5 s. Pide que el atajo hable con un
      proceso vivo: se cambia el camino del atajo, y eso hay que probarlo con
      las manos. Van juntos (el binario del atajo sería el cliente).
- [ ] **Bonsai contra el 8B y `medir-hora.ps1`**: paran el modelo mucho rato;
      correrlos con el PC libre.
- [ ] **`{"control": null}`**: medir con Discord delante (probar-senalar).
- [ ] **En una partida real**: VRAM de LoL con la voz (725 MiB) y el 4B,
      overlay en pantalla completa, OCR de la elección de aumentos, y que
      `--oculto` se rechace de verdad.
- [ ] **DuckDuckGo pide CAPTCHA en ráfagas**: en uso normal no debería;
      vigilar `sin respaldo` / "no pude buscarlo" en `sesion.csv`.

## Estética del overlay — a corregir después de que el bucle funcione

Decisión del usuario: primero funcional, luego bonito. Estos salieron al mirar
los PNG de `--prueba`. Todos hechos el 2026-09-23 (commit 268f437), comprobados con `--prueba`.

- [x] **Los números de paso son pequeños.** Círculo de radio 15 sobre 1920 px de
      ancho. Se ven, pero no mandan. Probar 20-22 y comparar.
- [x] **Las flechas no tocan los círculos de paso.** Queda un hueco de unos
      píxeles que se nota. La flecha debería arrancar del borde del círculo, no
      de un punto suelto cerca.
- [x] **La píldora de estado es discreta de más.** Texto a 14 px en la esquina;
      si el objetivo es saber siempre si te escuchó, tiene que verse sin
      buscarla. Subir tamaño o moverla junto a los subtítulos.
- [x] **El halo del cursor ensucia el anillo.** Los cuatro círculos concéntricos
      dejan un manchón marrón que resta contraste al anillo ámbar. Bajar alfa o
      recortarlo al radio del anillo.
- [x] **Sin animación de entrada ni de salida.** Los trazos aparecen y
      desaparecen de golpe. Un fundido de 150 ms se notaría mucho.
- [x] **El panel de subtítulos no parte líneas largas.** Una frase larga se sale
      del ancho de pantalla. Falta ajuste de línea.
- [x] **Sin modo claro.** Toda la paleta asume fondo oscuro. Sobre una ventana
      blanca el texto crema pierde contraste.

## Precisión fina — hecho, y lo que quedó cojo

Hecho: `uia/` lee los rectángulos reales y `ojo.ps1` se los ofrece al modelo.
Medido sobre Discord, **4 aciertos de 4** contra 1 de 4 sin la lista. Detalle y
los tres experimentos fallidos en `MEDICIONES.md`.

- [ ] **Elección forzada: el modelo nunca dice «no está en la lista».** Con 40 de
      los 144 controles de Discord, ante «¿dónde escribo un mensaje?» eligió
      'Find or start a conversation' en vez de admitir que faltaba. Probar a
      exigirle `{"control": null}` explícito y medir si lo respeta.
- [x] ~~Caben 40 y hacen falta más~~ — **resuelto y además era falso el
      diagnóstico**. No era el contexto: era un bug de codificación UTF-8 en la
      petición. Arreglado, pasan 149. Medido: 40 y 150 empatan a 3/4 aciertos y
      la larga cuesta 1,9 s más. Se queda en 40. El cuello no es cuántos caben,
      es que el modelo los distinga.
- [ ] **Consulta de calentamiento al arrancar.** Chromium devuelve 0 controles la
      primera vez. Encaja con el pre-calentamiento de la Fase E; es la misma
      llamada.
- [ ] **Volver a medir `-Enganchar`** cuando el modelo acierte la zona de forma
      fiable. Hoy convierte fallos vagos en fallos con pinta de seguros.
- [ ] **Usar `px`/`py` en modo agente, no las normalizadas.** `ojo-uia` ya
      devuelve el centro en píxeles físicos justamente para pulsar; normalizar y
      desnormalizar solo añade redondeo.

## Memorias temporales — hechas y cerradas

`memoria.ps1` + ocho notas en `memorias/`. Selector determinista, **14/14**.
La pregunta que fallaba 0/8 sale **8/8**.

- [x] ~~El selector cuesta 649 ms~~ — era el proceso, no el trabajo. Se carga
      con punto (`. memoria.ps1 -ComoModulo`): **155 ms**.
- [x] ~~Cuando duda no hay a quién preguntar~~ — **carga las dos**. El overlay
      es `WS_EX_TRANSPARENT | NOACTIVATE` y nunca podría recibir la respuesta;
      con notas de ~150 tokens y presupuesto de 1.500 no hay nada que decidir.
      El overlay informa de lo que cargó.
- [x] ~~Señala cosas que no vienen a cuento~~ — **5/5 y 5/5**. Una regla en el
      prompt daba 4/5 y 3/5: decidir cuándo callarse es un juicio, y eso es lo
      que el modelo hace peor. Lo decide un filtro por marcadores del texto de
      la pregunta, que solo suprime y nunca fuerza.
- [ ] **Escribir más notas.** Ocho cubren lo de esta sesión. Cada tema nuevo
      debería dejar la suya, y el conjunto anotado de `-Calibrar` crecer con él.
- [ ] **Los marcadores de `$MARCAS_SITIO` están calibrados con diez preguntas.**
      Si alguna forma de pedir un sitio no está en la lista, el síntoma es que
      deja de apuntar cuando debería. Se añade el marcador y se vuelve a correr
      `probar-senalar.ps1`.

## Método del banco — dos agujeros tapados

- [x] ~~Preguntas sin respuesta en el corpus contadas como fallo del modelo~~ —
      el banco comprueba que la respuesta esperada **aparece en el corpus** y
      marca `INVALIDA` si no. Probado como unidad. Pasó **tres veces** antes de
      taparlo, y la tercera acabó en una frase falsa publicada.
- [x] ~~El corpus estaba vivo~~ — apuntaba a `MEDICIONES.md`, que es donde
      escribo los resultados: creció de 14.089 a 24.271 fichas **el mismo día**.
      Ahora es una copia congelada en `banco-corpus\` con tope por archivo,
      64.279 chars. Refrescar exige `-RefrescarCorpus`.
- [ ] **Revisar qué comparaciones quedaron contaminadas.** Las del 8B contra el
      35B se hicieron seguidas y valen; las de Bonsai son de horas después, con
      el corpus ya crecido. Repetirlas sobre el corpus congelado.

## Sesión con micrófono — listo para cuando se siente

- [x] ~~Tiempos partidos en dos archivos~~ — `ojo.ps1` emite una línea `MEDIDA`
      y `hablar.ps1` la funde en `sesion.csv`, una fila por frase, con
      **`hasta_dibujo_ms`**: de soltar la tecla a que aparece el dibujo.
- [x] ~~Guion y hoja de puntuación~~ — `sesion-guion.md`, quince frases y
      cuatro preguntas por frase.
- [ ] **Correr la sesión.** Requiere que él hable. Discord visible o no vale.
- [ ] **Probar `sesion.csv` de punta a punta** con una frase real: hasta ahora
      solo se ha probado con silencio, que sale por la rama corta.

## Funcional

- [x] ~~Atajo Ctrl+Win mantenido~~ — `ojo-hotkey.ahk` + `hablar.ps1`. Valida
      sin errores; **falta probarlo con manos**.
- [x] ~~STT con Whisper base~~ — **no es Whisper.** Medido: Parakeet TDT 0.6B v3
      en int8 da **235 ms** contra 885 de whisper-base, con la misma precisión y
      769 MB de RAM en CPU. Los «300 ms heredados de voicebox» no se cumplían.
- [ ] **Medir el STT con su micro y su voz.** Las ocho frases del banco son voz
      sintética y los tres motores sacan 0% de WER: la prueba no discrimina.
      Hace falta que hable él, con el ruido de su cuarto.
- [ ] **Probar el atajo con manos.** Que Ctrl+Win mantenido no despiste a
      AltSnap, que los dos órdenes de pulsación disparen, y que Esc aborte.
- [x] ~~Arrancar el demonio del oído con la sesión~~ — **arranca todo**. Tres
      filas en `rice-supervisor.ps1` (oído, atajo y modelo), por mutex y por
      sonda porque el nombre de proceso no distingue. No hizo falta tocar
      `rice-autostart.ps1`: el supervisor arranca lo que falta.
- [x] ~~Interruptor para jugar~~ — `rice-modo-juego.ps1` libera **10 GB de
      VRAM** (11.748 → 1.747 MiB) y `-Volver` lo devuelve todo solo.
- [x] ~~Los dos modelos podían pisarse~~ — `Levantar-Servidor` se niega si el
      35B está en el 8080. Probado con un servidor falso.
- [x] ~~Reiniciar y no tocar nada~~ — **cerrado el 2026-09-21**. Arranque a las
      10:26, las tres piezas de Ojo en pie a las 10:27:22: **54 segundos**, sin
      tocar nada. Oído, atajo y modelo respondiendo, VRAM 11.585 MiB.
- [ ] **Un arranque de más del oído al encender.** El log muestra `ojo-oido
      started` a las 10:27:22 y otra vez a las 10:27:52; después, nada en 18
      minutos, y los dos mutex están tomados. O sea: **carrera puntual en el
      arranque, no bucle**, y el duplicado se suicida solo por el mutex — que
      es para lo que está. Coste: un proceso de más por encendido.

      Causa probable: `escuchar.py` toma el mutex dentro de `main()`, y antes
      de eso importa `numpy` y `sounddevice`. Moverlo arriba del todo cerraría
      la ventana.
- [ ] **El supervisor no sabe «aparcar» un componente.** `Health` solo se
      consulta si el proceso está VIVO; si falta, lo arranca sin preguntar.
      Probado con un 8080 falso. Consecuencia: mientras el Win+Space tenga la
      tarjeta, el supervisor intenta levantar el de Ojo cada 30 s, `ojo.ps1` se
      niega por su guarda, y el log se llena. **No es peligroso, es ruido.**
      Arreglarlo bien pide que `Check` sepa mirar un puerto, y eso toca
      `lib/rice-proc.ps1`, que lo usa todo el rice.
- [x] TTS en español: medido y elegido (Supertonic F2, ver MEDICIONES.md)
- [ ] Pre-calentamiento: mandar la imagen al pulsar, no al soltar (Fase E)
- [ ] Banco de precisión con capturas suyas anotadas (Fase F)
- [ ] Modo agente con confirmación (Fase G)

## Memoria — hecho a medias

- [x] ~~13,3 GB de RAM~~ — la caché de prompts del servidor son 8.192 MiB por
      defecto y nunca la pusimos. Con `--cache-ram 1024`: **10,45 GB residentes
      y 20,5 GB comprometidos**, contra 13,3 y 27,8. El pre-calentamiento sigue
      entero (939 de 943 tokens en caché).
- [x] ~~Que viva solo en VRAM~~ — **hecho.** Qwen3-VL-8B Q8_0 sin `--n-cpu-moe`:
      **1,2 GB de RAM** recién cargado, 2,4 GB tras las consultas, contra 10,5
      del 35B. Y no empató: ganó. 4/4 aciertos contra 3/4, latencia a la mitad,
      carga en 5,1 s. Es el predeterminado.
- [x] ~~Borrar el 35B~~ — **no se borra, y ahora está medido por qué.**
      `rice-llm.ps1` (Win+Space) es su dueño, y el banco de 8 pruebas
      (`banco-modelos.ps1`) dice que el 8B no lo sustituye ahí: falla **0/3** en
      distinguir un valor por defecto de otro parecido dentro de 15k tokens,
      mientras el 35B acierta 3/3. No es debilidad de contexto largo — con una
      pregunta sin distractor el 8B acierta 3/3 y 3,4× más rápido. Es que no
      discrimina. Cada modelo se queda en su sitio.
- [ ] **`--image-min-tokens 1024`.** llama.cpp avisa de que los Qwen-VL lo
      necesitan para tareas de *grounding* y nuestras capturas se quedan en 939
      tokens de prompt. No se tocó porque la prueba ya da 4/4 y subirlo encarece
      el prefill. Medirlo en el banco de la Fase F, con casos que fallen.
- [ ] **Recompilar llama.cpp con `GGML_CUDA_FA_ALL_QUANTS=ON`** si algún día
      hace falta cuantizar el KV. Con los binarios del zip oficial,
      `--cache-type-k q8_0` + `--flash-attn on` cae a CPU en silencio.

## Decisión abierta

- [ ] **Qué modelo de visión.** El leaderboard de ScreenSpot-Pro desmiente la
      tabla del plan: Qwen3-VL-8B (52,7%) acierta la mitad que un modelo
      frontera (Claude Opus 4.8, 87,9%). Muse Glimmer 30B es el mejor abierto
      (75,4%) pero pide ~17 GB y aquí hay 12. Es decisión de dinero y privacidad.

      **Menos urgente desde UIA.** Lo que fallaba era *dónde*, y eso ya no lo
      pone el modelo. Lo que sigue pidiendo un modelo mejor es *cuál*: elegir
      entre 40 nombres en inglés a partir de una pregunta en español.

## Limpieza

- [ ] **Borrar `I:\ai` — 27,6 GB, y tiene que hacerlo él.** Ya no lo usa nada:
      `rice-llm.ps1` y `companera\iniciar.ps1` se repuntaron a `F:\ai` y están
      verificados (el 4B carga en 3,2 s, `rice-llm -Status` responde). El
      entorno protege esa ruta y rechaza el borrado desde aquí.

      ```powershell
      Remove-Item 'I:\ai' -Recurse -Force
      ```

- [x] ~~`I:\ai\presets.ini` usa `no-mmap = true`~~ — resuelto en el nuevo
      `F:\ai\presets.ini`: `load-mode = none` en los seis, más `cache-ram = 1024`
      y un preset `[qwen3-vl-8b]`. El de `I:` se va con la carpeta.

## Tras la auditoría del 2026-09-22 (tarde)

Todo lo cerrado está en `MEDICIONES.md`, sección «auditoría», y en `git log`
(un commit por cambio). Lo que queda, en orden de valor:

- [ ] **Una muestra REAL del puerto 2999.** Todo lo de partida se ha probado con
      `prueba-lol/` (API falsa por HTTPS + proceso inerte), no con el juego. En
      una partida: `.\lol.ps1 -Crudo > prueba-lol\real.json`, y desde entonces
      `.\prueba-lol\partida.ps1 -Empezar -Datos .\prueba-lol\real.json` prueba
      contra datos de verdad. Es lo que confirmaría la identidad por Riot ID.
- [x] **VRAM real de Hearthstone.** El 8B ya aguanta ~2,3 GB de otra
      aplicación. Si Hearthstone pide menos, sale de la lista del supervisor y
      Ojo **conserva la visión** en Hearthstone — que es lo útil ahí, porque no
      hay API de datos y ver las cartas sí importa.
- [ ] **~340 ms de cargar lol.ps1 + Data Dragon en cada pregunta de partida**
      (marcas: servidor → captura). Casi todo es parsear el JSON del catálogo.
      Solo se arregla bien con un proceso que viva entre preguntas.
- [ ] **Un proceso residente en vez de uno por pregunta.** Queda ~380 ms de
      arrancar PowerShell y leer los scripts en cada pregunta (marcas
      `arranque_ps` + `cargado`). Es lo siguiente más grande después del modelo.
      Cambio de arquitectura: medir antes de decidir.
- [ ] **Subir los cambios del rice al repositorio `dotfiles`.**
      `rice-supervisor.ps1` y el nuevo `rice-lanzar-limpio.ps1` viven en
      `~\.config` y el repositorio no los tiene aún. `sync.ps1` los trae; el
      `push` a GitHub es tuyo.

## Pendiente de la noche del 2026-09-22 — copiloto de partida

Lo que se hizo funciona y está medido (ver `MEDICIONES.md`). Esto es lo que
quedó a medias, en orden de valor.

### Lo primero al encender

- [ ] **Medir la VRAM real de LoL.** Todo el presupuesto cuelga de un número
      que no es una medición, es un recuerdo (~4,5 GB).

      ```powershell
      nvidia-smi --query-gpu=memory.used --format=csv -l 1
      ```
      Abrir LoL hasta estar en partida y anotar el máximo. Con el perfil de
      partida puesto quedan 7.632 MiB libres, así que hay margen de sobra —
      pero hay que verlo, no suponerlo.

- [ ] **Probar la ruta de partida contra el puerto 2999 de verdad.** Hoy se
      probó con hechos inventados, por el mismo camino pero sin el juego.
      En partida:

      ```powershell
      .\lol.ps1 -Legible      # los hechos resumidos
      .\lol.ps1 -Crudo        # la respuesta entera, por si falta algún campo
      ```
      Y después el atajo, preguntando «cómo es nuestra composición».

- [ ] **Ver si el overlay se dibuja sobre LoL.** El juego está en pantalla
      completa exclusiva (`WindowMode=2` en su `game.cfg`). El overlay ya
      reafirma su banda de z cada 500 ms, que es lo máximo que se puede hacer
      desde el código. Si aun así no sale, la salida es `WindowMode=1` —sin
      bordes—, que es lo que exigen Blitz y OBS para pintar encima.

### Lo que falta para que sea el copiloto que pidió

- [x] ~~**Data Dragon cacheado**~~ — hecho: `ddragon.ps1`. Parche 16.18.1, 316
      ítems de la Grieta en 54 KB, se rehace solo cuando cambia el parche.
      `lol.ps1` ya añade `puedo_comprar` a los hechos de la partida.

- [ ] **La otra mitad de «qué ítems me armo»: lo que CONVIENE.** El catálogo
      dice qué te puedes permitir; no dice qué se arma este parche ni contra
      quién.

      **Y no está en Data Dragon:** el campo `recommended` de cada campeón
      viene **vacío** (comprobado con Lux en el 16.18.1). Riot dejó de
      publicarlo. Esto necesita web, no hay atajo.

- [x] **Internet con fuentes.** Su regla, literal: *«no quiero que invente, ni
      que diga que no sabe, quiero que cuando no lo sepa o esté en duda lo
      BUSQUE automáticamente y cite sus fuentes»*. SearXNG propio y una
      herramienta `buscar(q)` por tool-calling (`llama-server` ya corre con
      `--jinja`). Lo local se marca como exacto; lo de la web se cita.

- [ ] **Sacar el atajo de AutoHotkey.** Ctrl+Win no lo reserva el shell, así que
      `RegisterHotKey` sirve — y eso es una petición al shell, no un gancho
      global como el que usan AHK y `ws-slide`. La soltada se detecta con
      `GetAsyncKeyState`, igual que hace `ws-slide` para Super.

      Precedente dentro del propio rice: `launcher` y `ws-slide` llevan sus
      atajos en Rust, sin AHK. `ws-slide:454` deja escrito por qué él sí
      necesita el gancho (Win+1..9 las reserva el shell, error 1409). Ctrl+Win
      no está en ese caso.

- [x] **Impedir `WDA_EXCLUDEFROMCAPTURE` durante la partida.** Una ventana
      escondida de las capturas del anti-cheat es la firma de un tramposo. Hoy
      `--oculto` no es el modo por defecto, pero tampoco está prohibido.

### Cerrado

- [x] ~~**El 8B da 32,0 tok/s y el banco daba 50,16**~~ — **tenía causa**: el
      escritorio crecía y Windows desalojaba parte del modelo (reproducido: 43 →
      4,4 tok/s robándole 1,4 GB). Arreglado con Q6_K + KV q8_0 + sin
      calentamiento: 8.279 MiB, 62 tok/s, y aguanta el mismo robo sin frenarse.
      Lo de «transitorio, sin causa» que escribí por la mañana era falso.

- [x] ~~**Comprobar que el arranque automático funciona sin tocar nada**~~ —
      reinicio real: las cinco piezas corriendo a los 7 minutos y el supervisor
      eligió el 8B correctamente al no haber juegos.
