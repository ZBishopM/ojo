# Mañana — qué hacer al encender

## No hay que lanzar nada

`rice-supervisor.ps1` arranca con la sesión y levanta las tres piezas de Ojo en
su primer tick (unos 40 s tras el escritorio):

| pieza | qué es | cuánto tarda |
|---|---|---|
| `ojo-oido` | el micrófono, Parakeet en CPU | ~4 s |
| `ojo-hotkey` | Ctrl+Win mantenido | inmediato |
| `ojo-vlm` | el modelo — **cuál, ahora depende** | 3-5 s |

**Nuevo: el modelo cambia solo según si hay un juego abierto.**

| hay abierto | modelo | VRAM que deja libre |
|---|---|---|
| nada | Qwen3-VL-8B con visión | ~500 MiB |
| LoL, Hearthstone o Battle.net | Qwen3.5-4B de texto | **7.632 MiB** |

Verificado en producción anoche: con Battle.net abierto el supervisor mató el
8B y puso el 4B en 40 segundos, y la VRAM libre pasó de 417 a 7.632 MiB.

**Ojo con esto:** si Battle.net se queda abierto en segundo plano, Ojo se
queda en el perfil de texto y **no ve la pantalla**. Es lo que se pidió, pero
conviene saberlo. Cerrarlo devuelve el 8B en la vuelta siguiente.

Comprobar qué hay puesto:

```powershell
rice-modo-juego.ps1 -Estado
```

## Lo primero, y es medir

Tres cosas que no pude comprobar sin ti y de las que depende lo demás.

**1. Cuánta VRAM pide LoL de verdad.** Todo el presupuesto cuelga de los ~4,5
GB que recordabas, y eso no es una medición.

```powershell
nvidia-smi --query-gpu=memory.used --format=csv -l 1
```

Abrir LoL hasta estar en partida, anotar el máximo. Hay 7.632 MiB libres, así
que debería sobrar de largo.

**2. Que el puerto 2999 conteste.** En partida:

```powershell
cd D:\2026-projects\ojo
.\lol.ps1 -Legible      # los hechos resumidos
.\lol.ps1 -Crudo        # la respuesta entera, por si falta algún campo
```

Sin partida sale con código 1 y no imprime nada; eso es lo correcto.

**3. Que el overlay se vea sobre el juego.** Estás en pantalla completa
exclusiva (`WindowMode=2`). El overlay ya reafirma su posición encima dos veces
por segundo, que es lo máximo que se puede hacer desde el código. Mantener
Ctrl+Win en partida y ver si sale. **Si no sale**, la salida es poner el juego
en «sin bordes», que es lo que exigen Blitz y OBS para pintar encima.

## Preguntarle durante la partida

Mantener **Ctrl+Win**, hablar, soltar. Lo de siempre.

Cuando hay partida, Ojo **no mira la pantalla**: lee los datos que el propio
juego sirve. Medido anoche, «¿cómo es nuestra composición?» → **1.028 ms** y
los cinco campeones con sus puestos, exactos. La misma clase de pregunta
mirando una captura costó 14.427 ms y fallaba.

**Lo que ya funciona:** composición de los dos equipos, quién lleva qué ítems,
tu oro, tu nivel, el marcador, el minuto.

**Lo que todavía NO:** «qué ítems me armo». Los datos del juego dicen lo que
llevas, no lo que conviene. Para eso faltan el catálogo de ítems y la búsqueda
web, que están en `TODO.md`.

## La sesión de Discord, pendiente en limpio

La tanda del 22 no vale. Guion y hoja en `sesion-guion.md`.

Antes de la primera frase, dos comprobaciones que no son opcionales:

1. **Discord delante y visible.** Si está en otro espacio, GlazeWM lo oculta por
   DWM y la lista de controles llega vacía. Ya invalidó una medición entera.
2. Que devuelva **40 controles**:

   ```powershell
   D:\2026-projects\ojo\uia\target\release\ojo-uia.exe --ventana discord --max 40
   ```

3. **Y ningún juego abierto**, o el perfil será el de texto y no habrá visión.

Cada frase deja una fila en `sesion.csv`. **Columna nueva: `vram_libre_mib`.**
Si esa columna baja, la tanda está contaminada y se sabe sin tener que
adivinar — que es justo lo que faltó el 22.

## Cosas que saber

- **No hay voz de salida.** Se lee en los subtítulos. El TTS es la Fase D.
- Si AltSnap se despista y la barra espaciadora deja de responder,
  **Win+Shift+Z** lo recupera.
- **Anti-cheat:** ventanas encima aparte no son lo que persigue Vanguard —
  Discord, OBS y Blitz hacen lo mismo. Lo que sí persigue es inyección de
  código, y eso en esta máquina lo hace AltSnap (`hooks.dll` en cada proceso).
  `rice-modo-juego.ps1` lo para.

## Lo que quedó a medias

Todo en `TODO.md`, sección «copiloto de partida». Lo gordo:

- **«Qué ítems me armo»**: falta el catálogo de Data Dragon y la búsqueda web.
- **Internet con fuentes**: SearXNG y búsqueda automática cuando dude.
- **El atajo fuera de AutoHotkey**, con `RegisterHotKey` como hacen `launcher`
  y `ws-slide`.
- **Sin explicar**: el 8B da 32 tok/s y el banco daba 50,16, con todo cerrado.
  Shadowplay ya está descartado (cuesta un 5%, medido). La sospecha es el
  mmproj, sin comprobar.
- **Borrar `I:\ai`** — 27,6 GB, el entorno me lo protege, lo lanzas tú:

  ```powershell
  Remove-Item 'I:\ai' -Recurse -Force
  ```
