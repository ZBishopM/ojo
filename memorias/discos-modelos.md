---
titular: En qué disco viven los modelos y quién usa cada uno
claves: disco, ssd, nvme, hdd, ruta, carpeta, donde, guardado, velocidad, lectura, mover
---

Todo lo de IA local está en **`F:\ai`** (WD_BLACK SN770, NVMe). El HDD lee a
193 MB/s y el NVMe a 2.572: **13,3× de diferencia**, que en un modelo de 16 GB
son 110 s de carga contra 15.

Quién usa qué:

- `ojo.ps1` → `qwen3-vl-8b`, el modelo de visión
- `rice-llm.ps1`, el lanzador del Win+Space → el 35B
- `companera\iniciar.ps1` → `Qwen3.5-4B-UD-Q5_K_XL`

Los tres apuntaban antes a `I:\ai`, en el disco lento. Esa carpeta es ya un
duplicado huérfano de 27,6 GB pendiente de borrar a mano.

`F:\ai\presets.ini` tiene los presets del router, con `load-mode = none` porque
la bandera `--no-mmap` desapareció en la compilación b11056.
