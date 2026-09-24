"""Las frases de las escuchas a ciegas, ya pasadas por texto_voz (numeros y
nombres en ingles escritos como se dicen). Todas las candidatas leen lo mismo.

    .venv\\Scripts\\python frases_prueba.py   escribe frases_prueba.json
"""
import json
from pathlib import Path

from texto_voz import para_decir

FRASES = [
    "¿De verdad vas a comprar botas ahora? Bueno. Tú sabrás.",
    "Vas 0/7/2 contra Yone y Sylas, y aun así el 31% del daño es tuyo. Algo es algo.",
    "El dólar en Perú hoy está a 3.362 soles, según elperu. Y no, mañana no te lo voy a recordar.",
    "Elige Tirador Mágico. Frente a Locomotora y Cuello de Botella, es el que mejor clasifica op.gg para Sylas.",
    "Son las 17:32. La GPU va a 52 grados y la VRAM está en 11,2 de 12 GB.",
    "¿Otra vez preguntando lo mismo? Bueno. Lo último que te escribió Irene: «Perfecto, trae el postre».",
    "Jax va AP, así que te conviene resistencia mágica: Capa de Negatrones por 900 de oro.",
    "No lo veo en tu pantalla. Si está escondido, ábrelo y vuelvo a mirar.",
    "Luis juega vóley los sábados. ¿Cómo le fue en el partido del viernes?",
    "Tienes abiertos Discord, Firefox y WezTerm en el workspace 3, y DaVinci en el 4.",
]

if __name__ == "__main__":
    salida = [{"original": f, "texto": para_decir(f)} for f in FRASES]
    Path(__file__).with_name("frases_prueba.json").write_text(json.dumps(salida, ensure_ascii=False, indent=1), encoding="utf-8")
    for s in salida:
        print(s["texto"])
