---
titular: El puente para mandarle órdenes a DaVinci Resolve
claves: davinci, resolve, fusion, puente, ordenes, comp, nodo, timeline, render, script
---

Resolve no acepta scripting externo sin Studio, pero **sí** ejecuta lo que haya
en su carpeta `Scripts\Utility`. Ahí vive `puente_rice.py`: lee `ordenes.json`,
hace el trabajo y escribe `ordenes-resultado.json`.

Disciplina que costó una cuelgue de 25 minutos:

- `ordenes.json` **se borra nada más leerlo**, para que un cuelgue no lo
  reejecute al reabrir.
- Techo de tiempo `PRESUPUESTO = 60.0` segundos.
- Se exporta un `.drp` antes de cualquier lote que modifique algo.
- **Nunca `tool.GetInput(id)` sobre una entrada de imagen**: fuerza un render
  completo. Para leer valores se usa `inp[0]`, y se filtra por
  `INPS_DataType != "Text"`.

Un `.comp` de Fusion es texto plano, así que `comp.Save(ruta)` saca el grafo
entero de una vez en vez de cientos de llamadas a la API.
