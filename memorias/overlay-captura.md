---
titular: El overlay que dibuja encima y por qué no sale en la captura
claves: overlay, dibujar, captura, flecha, cursor, pantalla, bitblt, shadowplay, grabar, capa
---

El overlay es una ventana en capa (`WS_EX_LAYERED | TRANSPARENT | TOPMOST |
NOACTIVATE | TOOLWINDOW`) pintada con `UpdateLayeredWindow(ULW_ALPHA)`, copiada
de `ws-slide`. Rasteriza con tiny-skia y texto con fontdue. Medido: 1,05 ms
pintar y 3,93 ms presentar, unos 5 de los 16,7 que hay a 60 fps.

`SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` lo esconde de la captura, y
sin eso la IA vería sus propias flechas en la imagen siguiente.

**Pero excluye de TODAS las tuberías**, incluida Windows.Graphics.Capture — la
que usa shadowplay. Por eso el overlay arranca visible y el flag solo se activa
en el instante del BitBlt; si estuviera puesto siempre, no se podría grabar una
demo.
