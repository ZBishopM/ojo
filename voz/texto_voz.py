"""El texto tal como hay que DECIRLO, antes de pasarlo a la voz.

En la escucha a ciegas del 2026-09-23 fallaron todos los motores en lo mismo:
"Jax" leido en ingles o letra a letra, "AP" como palabra, y "4300" mal
dicho. No es cosa de la voz, es del texto: se reescribe como se pronuncia en
espanol latino y los numeros pasan a palabras.

    python texto_voz.py           comprobaciones
"""
import re

from num2words import num2words

# Nombres en ingles, siglas y marcas: como se dicen. Se buscan como palabra
# entera y sin distinguir mayusculas. Ampliar aqui cuando la voz tropiece.
PRONUNCIACION = {
    "Jax": "Yax", "AP": "a pe", "AD": "a de", "KDA": "ka de a", "MVP": "eme ve pe",
    "ARAM": "a ram", "Mayhem": "méijem", "op.gg": "o pe ge ge", "LoL": "lol",
    "WezTerm": "ues term", "Firefox": "fáyerfox", "Discord": "díscord",
    "GlazeWM": "gleis de eme", "Windows": "uíndous", "Yone": "yone",
    # Supertonic decia "Syla" (ronda 2).
    "Sylas": "Sáilas",
}
_NOMBRES = re.compile(r"(?<![\w.])(" + "|".join(re.escape(k) for k in sorted(PRONUNCIACION, key=len, reverse=True)) + r")(?![\w])", re.I)
_CLAVES = {k.lower(): v for k, v in PRONUNCIACION.items()}


def _numero(m):
    t = m.group(0)
    entero = t.replace(".", "").replace(" ", "")
    if "," in entero:
        a, b = entero.split(",", 1)
        return f"{num2words(int(a), lang='es')} coma {num2words(int(b), lang='es')}"
    return num2words(int(entero), lang="es")


def para_decir(texto: str) -> str:
    t = _NOMBRES.sub(lambda m: _CLAVES[m.group(0).lower()], texto)
    # KDA "0/7/2": "cero, siete y dos". Con "cero, siete, dos" la voz
    # tropezaba (ronda 2): la "y" le da el final de enumeracion.
    t = re.sub(r"\b(\d+)/(\d+)/(\d+)\b", lambda m: "{}, {} y {}".format(*(num2words(int(x), lang="es") for x in m.groups())), t)
    t = re.sub(r"(\d)\s*%", r"\1 por ciento", t)
    # 4300, 4.300, 4 300, 2,5
    t = re.sub(r"\d{1,3}(?:[. ]\d{3})+(?:,\d+)?|\d+(?:,\d+)?", _numero, t)
    return t


if __name__ == "__main__":
    casos = {
        "El más fuerte es Jax AP, con 4300 de oro.": "El más fuerte es Yax a pe, con cuatro mil trescientos de oro.",
        "Vas 0/7/2 y haces el 31% del daño.": "Vas cero, siete y dos y haces el treinta y uno por ciento del daño.",
        "contra Yone y Sylas": "contra yone y Sáilas",
        "Según op.gg, 4.300 o 2,5.": "Según o pe ge ge, cuatro mil trescientos o dos coma cinco.",
        "Tienes WezTerm y Discord.": "Tienes ues term y díscord.",
        "jax ad": "Yax a de",
    }
    mal = [(e, para_decir(e), s) for e, s in casos.items() if para_decir(e) != s]
    for e, obt, s in mal:
        print(f"FALLA: {e!r}\n  dio   {obt!r}\n  tocaba {s!r}")
    print(f"{len(casos) - len(mal)}/{len(casos)} OK")
    raise SystemExit(1 if mal else 0)
