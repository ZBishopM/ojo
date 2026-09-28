# Pocket TTS en ONNX (experimento, 2026-09-28)

Para bajar la CPU de la voz Lola. No está integrado en `servidor_voz.py`.

- `export_flow_lm_crece.py`: se pone en `scripts/` de
  [pocket-tts-onnx-export](https://github.com/lomotron/pocket-tts-onnx-export)
  (el repo de KevinAHM ya no existe; esta es una copia). Exporta FlowLM con la
  caché de atención que **crece por concatenación**, en vez de un tensor fijo de
  1000 posiciones reescrito entero (`ScatterND`) en cada paso.
- `medir_onnx.py`: núcleos, RTF y primer audio, con el runtime `pocket_tts_onnx.py`
  de KevinAHM (HF `KevinAHM/pocket-tts-onnx`).

Receta: `python export.py --language spanish_24l --quantize` (paquete fijo, con
los pesos actuales) y luego cambiar `flow_lm_main_int8.onnx` y el
`flow_lm_state_manifest` de `bundle.json` por los de `export_flow_lm_crece.py`.

## Medido (i5-11400F, 1 hilo, frase de 9,7 s, lola)

| | núcleos | RTF libre | RTF con 8 procesos quemando | primer audio |
|---|---|---|---|---|
| PyTorch, 1 hilo (lo de hoy) | 1,26 | 0,57 | 1,30 | 137 ms |
| ONNX INT8 de KevinAHM (HF) | 0,99 | 1,34 | — | 682 ms |
| ONNX nuestro, caché fija | — | 1,21 | — | — |
| **ONNX nuestro, caché que crece** | **0,98** | **0,51-0,57** | **1,24-1,46** | **142 ms** (voz acondicionada una vez) |

- **El paquete de HF de KevinAHM no es el mismo modelo** que el Pocket actual: contra
  PyTorch su `flow_lm_main` difiere 6,7 en la salida (el nuestro en FP32, 0,0000;
  en INT8, 0,33). Mezclar sus piezas con las nuestras cortaba las frases.
- Por paso de 80 ms de audio: la caché fija gastaba 31 ms en `ScatterND` y 19 ms
  en `Gather`, frente a 19 ms de cálculo real. Con la caché que crece, el paso
  baja de 74 a 33 ms.
- El decodificador Mimi: 38 ms por cada 240 ms de audio, casi todo convoluciones.
  Su caché pesa un 5 %: ahí no hay mucho que ganar.
- AVX-512 VNNI presente (INT8 acelerado). 2 hilos: RTF 0,38 libre pero 3,2 núcleos.
