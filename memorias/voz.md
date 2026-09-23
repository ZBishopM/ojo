---
titular: Voz — escuchar y hablar, y qué está medido de cada cosa
claves: voz, whisper, stt, tts, hablar, escuchar, microfono, audio, transcribir, piper, kokoro, supertonic, atajo, personalidad, glados
---

**Escuchar.** Whisper base, **300 ms medidos** en voicebox, en
`F:\ai\voicebox-models`. Falta volver a medirlos con este micro y esta voz en
vez de heredar el número. El barge-in usa TEN VAD con salto de 10 ms.

**Hablar: Supertonic 3, voz F2, en la GPU.** Ganó dos escuchas a ciegas del
usuario (2026-09-23) entre las que empiezan a sonar en menos de 400 ms. Vive
en `voz\servidor_voz.py` (puerto 8098, mutex `Global\ojo-voz`, lo lanza el
supervisor). Primera frase en ~230-300 ms, 725 MiB de VRAM. Se calla sola si
muere el proceso que preguntó. Reserva: SAPI Sabina.

**Descartadas, medidas:** Chatterbox Multilingual (RTF 2,5), Supertonic en
CPU (1,4 s), Piper Daniela (1,1 s), Piper Claude y Sabina (mal puntuadas),
Kokoro (destroza el español), Qwen3-TTS (RTF ~3). Sin probar: XTTS-v2 (pide
aceptar la licencia CPML) y Dalia de Windows (adaptador con administrador y
voz de un espejo de terceros).

**Pronunciación: es del texto.** `voz\texto_voz.py` pasa números a palabras y
reescribe nombres en inglés («Yax», «a pe», «Sáilas»). Si tropieza con una
palabra, se añade a `PRONUNCIACION`.

**Personalidad: es del prompt.** Bloque «Caracter de decir» en los dos prompts
de `ojo.ps1` (GLaDOS: dato primero, pulla corta al final, español latino, con
un ejemplo). Medido sin pérdida de aciertos (MEDICIONES.md).

**Invocación.** Ctrl+Win mantenido, como un walkie: se habla mientras se
mantiene y se suelta al acabar.
