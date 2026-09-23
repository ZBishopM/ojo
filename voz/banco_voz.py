"""Banco de voces: las mismas frases (frases.txt) con cada motor.

Mide la carga del motor, el tiempo de la PRIMERA FRASE (lo que tarda en
empezar a sonar si se habla frase a frase) y el factor de tiempo real (RTF =
tiempo de sintesis / duracion del audio). Deja los WAV en salida/<motor>/.

    .venv\\Scripts\\python.exe banco_voz.py supertonic piper
"""
import json
import sys
import time
from pathlib import Path

import numpy as np
import soundfile as sf

AQUI = Path(__file__).parent
MODELOS = Path(r"F:\ai\voz")
FRASES = [l.strip() for l in (AQUI / "frases.txt").read_text(encoding="utf-8").splitlines() if l.strip()]


def motor_supertonic(voz="F1"):
    from supertonic import TTS
    t = TTS(model_dir=MODELOS / "supertonic-3")
    estilo = t.get_voice_style(voice_name=voz)

    # 4 pasos y no los 8 de fabrica: medido aqui, 8 = 1.906 ms, 4 = 1.086,
    # 2 = 731 para la misma frase de 6 s.
    def decir(texto):
        wav, _ = t.synthesize(texto, voice_style=estilo, lang="es", total_steps=4)
        return np.asarray(wav, dtype=np.float32).reshape(-1), t.sample_rate
    return decir


def motor_piper(voz="es_MX-claude-high"):
    from piper import PiperVoice
    v = PiperVoice.load(str(MODELOS / "piper" / f"{voz}.onnx"))

    def decir(texto):
        trozos = [c.audio_float_array for c in v.synthesize(texto)]
        return np.concatenate(trozos).astype(np.float32), v.config.sample_rate
    return decir


MOTORES = {"supertonic": motor_supertonic, "piper": motor_piper}


def medir(nombre, fabrica, *args):
    etiqueta = nombre + ("-" + args[0] if args else "")
    out = AQUI / "salida" / etiqueta
    out.mkdir(parents=True, exist_ok=True)
    t0 = time.perf_counter()
    decir = fabrica(*args)
    carga = time.perf_counter() - t0
    decir("Hola.")  # en caliente: la primera llamada paga la inicializacion
    filas = []
    for i, f in enumerate(FRASES, 1):
        primera = f.split(". ")[0]
        t0 = time.perf_counter(); decir(primera); t_primera = time.perf_counter() - t0
        t0 = time.perf_counter(); wav, sr = decir(f); t_total = time.perf_counter() - t0
        dur = len(wav) / sr
        sf.write(out / f"{i}.wav", wav, sr)
        filas.append({"frase": i, "primera_ms": round(t_primera * 1000), "total_ms": round(t_total * 1000),
                      "audio_s": round(dur, 2), "rtf": round(t_total / dur, 3)})
    r = {"motor": etiqueta, "carga_ms": round(carga * 1000), "frases": filas,
         "primera_ms_max": max(x["primera_ms"] for x in filas), "rtf_medio": round(sum(x["rtf"] for x in filas) / len(filas), 3)}
    (out / "medida.json").write_text(json.dumps(r, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps({k: v for k, v in r.items() if k != "frases"}, ensure_ascii=False))


if __name__ == "__main__":
    for a in sys.argv[1:]:
        nombre, _, voz = a.partition(":")
        medir(nombre, MOTORES[nombre], *([voz] if voz else []))
