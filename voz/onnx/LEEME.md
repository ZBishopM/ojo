# Pocket TTS en ONNX (experimento, 2026-09-28)

## Lo que hace sonar igual que la voz de siempre (actualizado)

Tres escuchas a ciegas seguidas: la voz actual siempre ganaba (4/4) y el ONNX
sonaba «más claro pero monótono». No era el ruido ni la temperatura:

1. **Otra revisión de los pesos.** `export.py` bajaba la última de
   `kyutai/pocket-tts` (75cfe24), con un tokenizador nuevo. El Pocket instalado
   fija **39592ff** y tokeniza con el `tokenizer.json` del repo sin clonación
   (@00eac05): los ids salen completamente distintos. Hay que fijar la revisión
   en `pocket_tts/config/spanish_24l.yaml` del exportador
   (`...model.safetensors@39592ff23c9ef80098bb74895d104c26275fe2c9`).
2. **La voz «lola» precalculada por Kyutai** (`lola.safetensors`), no clonada desde
   el mp3. Su estado difiere del clonado más que su propio tamaño medio.
3. **Dos detalles del bucle** (`voz/motor_onnx.py` los replica): PyTorch sortea
   ruido también en el prellenado del texto (el paso 0 usa el segundo sorteo) e
   ignora el EOS en los 6 primeros pasos. Más el ruido de torch con semilla 42
   (`ruido_torch42.npy`), reiniciado por frase como hace el servidor.

Con todo igualado: ONNX FP32 = PyTorch FP32 (misma duración, correlación de la
onda +1,000). El INT8 de ONNX Runtime no es el mismo que el de torch: parecido,
no idéntico. Coste medido (1 hilo, sin carga): **ONNX INT8 1,0 núcleo, RTF 0,45,
primer audio 122 ms** (PyTorch INT8: 1,26 / 0,57 / 137 ms). FP32: RTF 1,07, no
llega. Paquete: `F:\ai\tts\pocket-onnx\lola-v39` (flow_lm_main con caché que
crece, tokenizer.json, lola.safetensors, ruido_torch42.npy).

## El modelo nuevo (reentrenado el 2026-09-24) y por qué sonaba «peor»

Kyutai reentrenó español, italiano, portugués, alemán y neerlandés (commit
`2dd944b` en `kyutai/pocket-tts`: «new tokenizers, recomputed voice embeddings») y
sacó **Pocket 3.3.0** el mismo día. Diferencias con 3.2.0 (el instalado):

- `replace_characters` en la config: quita `" “ ” „ « » ( ) [ ] ¡ ¿` y normaliza
  apóstrofes antes de tokenizar. Su comentario: el entrenamiento nunca vio esos
  caracteres, sus embeddings no están entrenados y el modelo «dice sílabas de
  relleno donde aparecen».
- Temperatura por defecto 0,7 → 0,3 («gana en WER y UTMOS en todos los modelos»).
- Voces predefinidas recalculadas (`pocket-tts-without-voice-cloning@4e1e0a3`) y
  `tokenizer.json` nuevo en la misma revisión.
- El bucle de generación no cambia.
- **Fallo en Windows:** 3.3.0 lee el YAML con cp1252 y revienta con las comillas de
  `replace_characters`. Arranca con `PYTHONUTF8=1`.

Lo «más claro pero monótono» era el modelo nuevo usado sin eso (lola clonada,
«¿» dentro, ruido y EOS del runtime). Bien montado (`lola-nuevo`: los pesos
2dd944b = 75cfe24, mismo hash; lola y tokenizer.json @4e1e0a3;
`reemplazos.json`, que `motor_onnx.py` aplica), el ONNX FP32 coincide con
Pocket 3.3.0 en PyTorch (mismas duraciones, correlación +0,995). Coste igual
que el antiguo. La referencia 3.3.0 está en `F:\ai\tts\pocket33\.venv`.

## Lo anterior (con los pesos equivocados)

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
