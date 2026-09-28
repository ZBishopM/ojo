"""Pocket ONNX INT8 (spanish_24l, voz lola clonada): nucleos al generar, RTF
y primer audio, con N hilos. Uso: python medir_onnx.py <hilos> <etiqueta> [guardar.wav]"""
import json
import re
import statistics
import sys
import time

import numpy as np
import onnxruntime as ort
import soundfile as sf

sys.path.insert(0, r"D:\2026-projects\ojo\voz")
import pocket_tts_onnx as P  # noqa: E402
from texto_voz import para_decir  # noqa: E402

HILOS, ETIQ = int(sys.argv[1]), sys.argv[2]
GUARDAR = sys.argv[3] if len(sys.argv) > 3 else None


def opciones(self):
    o = ort.SessionOptions()
    o.intra_op_num_threads = HILOS
    o.inter_op_num_threads = 1
    o.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    return o


P.PocketTTSOnnx._make_session_options = opciones
_prep = P.PocketTTSOnnx.prepare_voice_state
_voces = {}


def prep_cacheado(self, voice):
    """La voz se acondiciona UNA vez (el servidor lo hara al arrancar), no en cada frase."""
    if str(voice) not in _voces:
        _voces[str(voice)] = _prep(self, voice)
    return self._clone_state(_voces[str(voice)])


if __import__("os").environ.get("VOZ_CACHE") == "1":
    P.PocketTTSOnnx.prepare_voice_state = prep_cacheado
tts = P.PocketTTSOnnx(models_dir=__import__("os").environ.get("MODELS", r"F:\ai\tts\pocket-onnx\onnx"), language=__import__("os").environ.get("BUNDLE", "spanish_24l"),
                      precision="int8", device="cpu", temperature=0.3)
VOZ = r"F:\ai\tts\pocket-onnx\lola.wav"
estado = tts.prepare_voice_state(VOZ)  # clonar una vez (lo hace el servidor al arrancar)
for _ in tts.stream("Hola.", voice=VOZ):
    pass

FRASE = ("Te lo dije tres veces, pero claro, el experto eres tú. Adelante, vuelve a pelear solo "
         "en el río, que ahí te matan siempre y luego me culpas a mí.")
partes = [f for f in re.split(r"(?<=[.!?…;:])\s+", para_decir(FRASE)) if f]
filas, audio = [], []
for vuelta in range(3):
    c0, t0, primera, n, audio = time.process_time(), time.perf_counter(), None, 0, []
    for p in partes:
        np.random.seed(42)
        for a in tts.stream(p, voice=VOZ):
            if primera is None:
                primera = (time.perf_counter() - t0) * 1000
            n += a.size
            audio.append(a)
    gen = time.perf_counter() - t0
    filas.append({"nucleos": (time.process_time() - c0) / gen, "rtf": gen / (n / tts.sample_rate), "primera": primera})
if GUARDAR:
    sf.write(GUARDAR, np.concatenate(audio), tts.sample_rate)
print(json.dumps({"variante": ETIQ, **{k: round(statistics.median(f[k] for f in filas), 3 if k != "primera" else 0) for k in filas[0]}}), flush=True)
