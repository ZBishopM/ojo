---
titular: Voz — escuchar y hablar, y qué está medido de cada cosa
claves: voz, whisper, stt, tts, hablar, escuchar, microfono, audio, transcribir, piper, kokoro, atajo
---

**Escuchar.** Whisper base, **300 ms medidos** en voicebox, en
`F:\ai\voicebox-models`. Falta volver a medirlos con este micro y esta voz en
vez de heredar el número. El barge-in usa TEN VAD con salto de 10 ms.

**Hablar.** Nada elegido todavía. Descartados por medición propia: Chatterbox
Turbo tiene suelo de 1,3 s por petición, y Kokoro, pese a sus 682-727 ms, «en
español destroza los titubeos». El candidato es **Piper** (RTF ~0,03, primer
audio ~40 ms, voces es_ES y es_MX), asumiendo que suene más robótico.

**Invocación.** Ctrl+Win mantenido, como un walkie: se habla mientras se
mantiene y se suelta al acabar. Eso elimina el detector de fin de frase.

Nada de esto está conectado aún: el bucle de hoy se escribe a mano.
