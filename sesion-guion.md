# Sesión con micrófono — guion y hoja de puntuación

Tú hablas, yo mido, tú puntúas lo que ves. Las quince frases se dicen dos
veces: una tanda con el **8B** y otra con **Bonsai**.

## Antes de empezar

- **Discord delante y visible.** Si está oculto por DWM la lista de controles
  llega vacía y la sesión no vale — ya costó una medición entera.
- **No hay voz de salida.** La Fase D no está hecha: las respuestas se leen en
  los subtítulos del overlay.
- Comprobar que `ojo-uia` devuelve **40 controles** sobre Discord.

## Cómo se dice cada frase

Mantener **Ctrl+Win**, hablar, soltar. El overlay dibuja al soltar.

## Las quince frases

**Señalar — debe apuntar a un control real**

1. dónde silencio el micrófono
2. dónde están los ajustes de usuario
3. dónde escribo un mensaje
4. dónde está el botón de cerrar

**Dibujar — es lo que menos probado está**

5. marca con una caja la lista de servidores
6. señala con una flecha dónde se cambia de canal
7. numera los pasos para enviar un mensaje

**Conocimiento del proyecto — debe cargar memoria y NO señalar**

8. cuánta RAM reserva el servidor por defecto
9. en qué disco están los modelos
10. qué hace n-cpu-moe

**No debe señalar, aunque haya pantalla delante**

11. cuánto tarda whisper en transcribir
12. por qué el overlay no sale en la captura

**Los dos difíciles**

13. qué río cruza Lima
    *(el 8B la acierta; Bonsai contesta «El río Lima» — está medido)*
14. cuántos paneles hay en esta pantalla
    *(visión pura: UIA no ayuda aquí)*

**Robustez del oído**

15. a ver… eh… quiero que me digas dónde está, mmm, el botón ese de silenciar,
    el del micrófono

## Hoja de puntuación

Una fila por frase y por modelo. Las tres primeras son de sí/no para que vaya
rápido; la **d** es la que más falta hace, porque ordena por dolor real los
siete pendientes de estética.

| | pregunta | escala |
|---|---|---|
| **a** | ¿te entendió bien lo que dijiste? | sí / no / a medias |
| **b** | ¿apuntó o dibujó donde debía? | sí / no / no tocaba |
| **c** | ¿lo que dijo era correcto? | sí / no / no lo sé |
| **d** | ¿se entendía de un vistazo? | 1-5 |

### Tanda 1 — 8B

| # | a | b | c | d | nota |
|---|---|---|---|---|------|
| 1 | | | | | |
| 2 | | | | | |
| 3 | | | | | |
| 4 | | | | | |
| 5 | | | | | |
| 6 | | | | | |
| 7 | | | | | |
| 8 | | | | | |
| 9 | | | | | |
| 10 | | | | | |
| 11 | | | | | |
| 12 | | | | | |
| 13 | | | | | |
| 14 | | | | | |
| 15 | | | | | |

### Tanda 2 — Bonsai

| # | a | b | c | d | nota |
|---|---|---|---|---|------|
| 1 | | | | | |
| 2 | | | | | |
| 3 | | | | | |
| 4 | | | | | |
| 5 | | | | | |
| 6 | | | | | |
| 7 | | | | | |
| 8 | | | | | |
| 9 | | | | | |
| 10 | | | | | |
| 11 | | | | | |
| 12 | | | | | |
| 13 | | | | | |
| 14 | | | | | |
| 15 | | | | | |

### Tres preguntas al final de cada tanda

- ¿cuál de las quince salió peor, y qué pasó?
- ¿en alguna te pareció que tardó demasiado?
- ¿el dibujo estorbó alguna vez en vez de ayudar?

## Lo que mido yo

Cada frase deja una fila en `sesion.csv`:

```
hora, frase, modelo, audio_s, stt_ms, captura_ms, uia_ms, memoria_ms,
modelo_ms, hasta_dibujo_ms, controles, memorias, via, senalo, trazos, dijo
```

`hasta_dibujo_ms` va de **soltar la tecla** a que la escena sale hacia el
overlay: es el número que tú percibes. Los de etapa solo explican en qué se
fue.

Tu columna **d** y mi `hasta_dibujo_ms` son las dos que deciden qué se arregla
después: una dice si se entiende, la otra si se hace esperar.
