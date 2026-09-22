# Al encender — qué hay y qué falta

## No hay que lanzar nada

El supervisor levanta las tres piezas de Ojo con la sesión. El modelo depende de
si hay un juego abierto, y ahora cambia **en el mismo latido** (antes esperaba
dos, más dos minutos de gracia):

| hay abierto | modelo | libres | cambio |
|---|---|---|---|
| nada | Qwen3-VL-8B **Q6_K** con visión | ~2.700 MiB | — |
| LeagueClient, League of Legends o Hearthstone | Qwen3.5-4B de texto | ~7.300 MiB | ~7-35 s |

Battle.net **ya no** cuenta: vive en la bandeja y dejaba a Ojo ciego.

## Lo que cambió en la auditoría (todo medido, un commit por cambio)

- **El 8B ya no se hunde solo.** Antes, con ~300 MiB libres, el escritorio
  crecía y Windows lo desalojaba: 50 → 12 tok/s en 25 minutos sin ningún
  juego. Ahora es Q6_K (8.279 MiB, 62 tok/s, misma calidad en los dos bancos)
  y aguanta que otra aplicación le quite ~2,3 GB.
- **Más rápido de soltar a dibujo**: 2.614 → 2.091 ms en el camino del atajo.
- **El modelo ya no se ve a sí mismo** en la captura.
- **En partida**: identidad robusta al Riot ID, compras que encajan con tu
  campeón, «qué termino con lo que llevo», y la composición con los cinco
  nombres. 1,0-1,5 s por pregunta.
- **Sin números de control** en la voz.

Detalle en `MEDICIONES.md` (sección «auditoría») y en `git log`.

## Lo primero, y solo lo puedes hacer tú

1. **Una partida de LoL de verdad.** Todo lo de partida está probado con una
   partida falsa (`prueba-lol\`). En partida:

   ```powershell
   cd D:\2026-projects\ojo
   .\lol.ps1 -Crudo > prueba-lol\real.json      # la muestra real
   nvidia-smi --query-gpu=memory.used --format=csv -l 1   # la VRAM del juego
   ```

   Y mantener **Ctrl+Win**: «¿cómo es nuestra composición?», «¿qué termino
   con lo que llevo?». Si el overlay no se ve encima (juegas en pantalla
   completa exclusiva), la salida es poner el juego en «sin bordes».

2. **Hearthstone**, lo mismo con `nvidia-smi`. Si pide menos de ~2 GB, sale de
   la lista y Ojo conserva la visión ahí — que es lo útil, porque no hay API
   de datos y ver las cartas sí importa.

## Pendiente, en orden

- **Búsqueda web con fuentes** («qué conviene armarse este parche»): Riot ya no
  publica builds; solo sale de la web.
- **Un proceso residente** para Ojo: quedan ~380 ms por pregunta de arrancar
  PowerShell y leer scripts, y ~340 ms en partida de parsear el catálogo.
- **Sacar el atajo de AutoHotkey** (`RegisterHotKey`, como `launcher`).
- **Subir el rice a `dotfiles`**: `rice-supervisor.ps1` y el nuevo
  `rice-lanzar-limpio.ps1` están solo en `~\.config`. El `push` es tuyo.
- Repetir la sesión de micrófono en limpio, Fase A del corpus, estética del
  overlay, y borrar `I:\ai` (27,6 GB, lo lanzas tú).
