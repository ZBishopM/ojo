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

## Por qué el modelo nuevo no tiene el acento, y cómo arreglar el de ahora (2026-09-29)

Fuentes (Kyutai): PR #326 y #321 de `kyutai-labs/pocket-tts`, issue #166.

- **El español nuevo es un fine-tune del profesor de inglés de 24 capas sobre
  CML-TTS**, con tokenizador nuevo, un pulido con habla «in the wild» y un CFG
  horneado. De ahí la fonética inglesa («un americano hablando español»). Mejora la
  exactitud: 1,55 % de palabras mal contra 2,70 % (24 capas) y las palabras sueltas
  bien el 65-87 % de las veces contra el 28-47 %.
- En Pocket el acento de la voz de referencia también pesa (issue #166: las voces
  por defecto eran inglesas y salía acento inglés en francés). Pero la lola del
  antiguo y la del nuevo salen de la MISMA grabación, y el nuevo no conserva el
  acento: por eso se probó trasladarlo con habla de la voz actual (escucha 10).
- **Licencia: no clonar a nadie.** La README de Kyutai prohíbe «voice impersonation
  or cloning without explicit and lawful consent». No se usan voluntarios de
  conjuntos de datos (Google/OpenSLR) como referencia; solo lola.
- **Fallo real del modelo antiguo con la semilla 42:** una frase de UNA palabra sale
  en inglés. Medido con Parakeet en 12 palabras: 3 bien (`Bueno→Yeah`,
  `Perfecto→Perfect`, `Claro→Yeah`, `Vale→Okay`). Cambiar de semilla no basta (la
  mejor, la 14, acierta 10 de 12). Sí funciona **pegar las frases de una o dos
  palabras a la frase anterior** (`bateria2.py prev2`): 13 → 10 palabras perdidas en
  las 10 frases de prueba (12 → 9 con medio segundo de silencio delante; el modelo
  nuevo, 9). Pegarlas a la SIGUIENTE empeora (18): el principio de la frase es el
  punto débil del modelo antiguo (5-6 de sus 12-13 fallos son la primera palabra
  de una frase; en el nuevo, 1 de 9), y las pérdidas son reales, no del reconocedor.
- Pendiente de la escucha 11 (usuario): si `frases()` de `servidor_voz.py` pasa a
  pegar las frases de 1-2 palabras a la anterior.
- Sospechoso 2026-09-29: el habla de la voz actual como referencia tiene palabras
  perdidas («Ya», «Yo», «vez»); no importa para clonar (no se pasa el texto).

## Escucha 9 y errores contados (2026-09-29)

Escucha a ciegas 9: el usuario reconoció el modelo antiguo por su **acento entre
chileno y argentino** (PyTorch: expresión 5, gusto 4). El nuevo, en PyTorch 3.3.0 y en
ONNX: claridad 4, expresión 1, «un americano intentando hablar español». La lola
nueva sale de la MISMA grabación (common_voice_es_19762977): el acento lo neutraliza
el modelo reentrenado, no la referencia.

Palabras perdidas en las 10 frases de `frases_prueba.json`, transcritas con el
Parakeet del oído (scratchpad `bateria.py` y `errores_bateria.py`). Hay una base de
~9 (siglas y nombres: elperu, VRAM, GB, DaVinci, vóley) que falla en todas:

| variante (frases separadas, como el servidor) | perdidas |
|---|---|
| nuevo, ONNX INT8 | 9 (solo la base) |
| **antiguo, PyTorch INT8 (el servidor de hoy)** | **13** («bueno» suelto, «Calante» por «adelante») |
| antiguo, FP32 (PyTorch = ONNX) | 15 |
| antiguo, PyTorch INT8 + relleno de frases cortas | 15 |
| antiguo, ONNX INT8 + relleno | 20 |
| antiguo, ONNX INT8 (por tensor o por canal) | 22 |
| cualquiera uniendo frases de 1-2 palabras a la siguiente | peor |

Conclusión:
- El modelo antiguo en ONNX INT8 pronuncia peor que en PyTorch INT8 (22 contra 13),
  con cualquiera de las dos cuantizaciones. **No integrar el ONNX del modelo antiguo:
  el servidor sigue con PyTorch.**
- El modelo nuevo no falla, pero no tiene el acento.
- Pendiente: darle acento al modelo nuevo (clonar referencias con acento
  chileno o argentino, temperatura) o arreglar los fallos del antiguo.

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
