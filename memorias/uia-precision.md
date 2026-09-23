---
titular: Cómo Ojo saca las coordenadas exactas de un control
claves: uia, automation, coordenadas, boton, control, rectangulo, precision, senalar, clic, grounding
---

`uia/` (`ojo-uia.exe`) no adivina: lee los rectángulos con **UI Automation**, que
es el mismo dato con el que Windows dibuja cada control. Es el camino de UFO2,
el agente de escritorio de Microsoft.

Medido en Discord: **4 aciertos de 4** ofreciéndole la lista de controles, contra
1 de 4 cuando el modelo daba coordenadas a ojo. Sus respuestas sin la lista eran
números redondos —0,98 · 0,02— porque nombraba regiones en vez de localizar.

Coste: de 41 ms (Claude) a 330 ms (Firefox con 30 pestañas). Corre en paralelo
con la captura.

**Dónde no llega:** Zed devuelve 1 control porque se dibuja entera con la GPU, y
lo mismo valdrá para juegos. Ahí la lista viene vacía y el modelo vuelve a sus
coordenadas.
