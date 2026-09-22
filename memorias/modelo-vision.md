---
titular: Qué modelo de visión usa Ojo y por qué cabe entero en la VRAM
claves: vision, modelo, vram, qwen, 8b, 35b, gguf, cuantizacion, q8, denso, moe, cabe
---

Ojo usa **Qwen3-VL-8B-Instruct a Q8_0** (8,11 GB) con su `mmproj-F16` (1,08 GB),
en `F:\ai\models\qwen3-vl-8b\`. Cabe entero en los 12,28 GB de la 4070 SUPER, así
que **no reparte nada a la CPU**: 1,2 GB de RAM recién cargado contra 10,5 del
modelo anterior, y carga en 5,1 s en vez de 14,7.

Antes se usaba `Qwen3.6-35B-A3B` a Q3_K_XL (16,8 GB). Ese no cabe en VRAM de
ninguna manera — su cuantización más pequeña son 10 GB a 1 bit — y por eso
necesitaba `--n-cpu-moe`.

El 8B saca 52,7 en ScreenSpot-Pro, la mitad que un modelo frontera, y aun así
gana aquí: ya no adivina coordenadas, se las da UI Automation.
