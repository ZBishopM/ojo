---
titular: La caché de prompts de llama-server y la RAM que se come
claves: cache-ram, cram, cache, prompt, ram, memoria, reserva, defecto, precalentamiento
---

`llama-server` reserva **8.192 MiB de RAM del sistema por defecto** para la
caché de prompts (`-cram, --cache-ram N`). Nadie la pide y casi nadie la sabe.

Aquí se puso en 1.024 MiB. Medido: la RAM residente bajó de 13.273 a 10.454 MB
y la comprometida de 27.815 a 20.471.

**No se pone a 0.** Esa caché es lo que hace que repetir un prompt cueste 151 ms
en vez de 1.026 — es el pre-calentamiento, no un lujo. Con 1.024 MiB caben unas
cuatro entradas de ~220 MiB, más de las que hacen falta.
