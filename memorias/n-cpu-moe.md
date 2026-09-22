---
titular: El reparto GPU/CPU de un modelo MoE que no cabe en VRAM
claves: n-cpu-moe, ncpu, mue, moe, reparto, cpu, gpu, capas, expertos, offload, ancho, banda, llama-bench
---

`--n-cpu-moe` dice cuántas capas de expertos se quedan en RAM en vez de la VRAM.
Solo hace falta cuando el modelo **no cabe entero** en la tarjeta.

El 35B es un MoE de 35B totales pero **3B activos** por token, y se eligió justo
por eso: el cuello de esta máquina no es la VRAM sino el ancho de banda de la
RAM, unos 45 GB/s reales en DDR4-3200. Un modelo denso de 27B tendría que leer
27B de parámetros por token desde ahí e iría a paso de tortuga; este lee ~1 GB.

Dos trampas medidas: `llama-bench` recomendó 18 y con el servidor real **18 no
cabe**, porque el banco no reserva el contexto entero ni compite con el
navegador. Y el reparto cuesta RAM en cada token, sin bandera que lo evite.
