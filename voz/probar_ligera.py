"""Voces LIGERAS candidatas, medidas igual: las frases de frases_prueba.json,
tiempo al primer audio, RTF, RAM y CPU. Cada candidata corre en su propio
entorno (F:\\ai\\tts\\<modelo>\\.venv) porque sus dependencias chocan.

POR QUE EN CPU: con el 8B y la voz actual la tarjeta va a 11,3 de 12 GB; una
voz que corra en CPU devuelve ~811 MiB de VRAM.

    <venv>\\python probar_ligera.py pocket [voz]        voz: lola (de serie) o un .wav
    <venv>\\python probar_ligera.py neutts <ref.wav> <ref.txt>
"""
import json
import os
import sys
import threading
import time
from pathlib import Path

import numpy as np
import psutil
import soundfile as sf

AQUI = Path(__file__).parent
SALIDA = AQUI / "salida" / "ligeras"
SALIDA.mkdir(parents=True, exist_ok=True)
FRASES = [f["texto"] for f in json.loads((AQUI / "frases_prueba.json").read_text(encoding="utf-8"))]
PROC = psutil.Process()


class Cpu:
    """% de CPU del proceso mientras dura el bloque (100 = un nucleo entero)."""
    def __enter__(self):
        self.t0 = time.perf_counter(); self.c0 = sum(PROC.cpu_times()[:2]); return self

    def __exit__(self, *a):
        self.pct = 100 * (sum(PROC.cpu_times()[:2]) - self.c0) / (time.perf_counter() - self.t0)


def medir(nombre, cargar, generar, sr):
    t = time.perf_counter(); estado = cargar(); carga_ms = (time.perf_counter() - t) * 1000
    sr = sr(estado) if callable(sr) else sr
    filas = []
    for i, texto in enumerate(FRASES):
        trozos = []; primero = None
        with Cpu() as c:
            t = time.perf_counter()
            for trozo in generar(estado, texto):
                if primero is None:
                    primero = (time.perf_counter() - t) * 1000
                trozos.append(np.asarray(trozo, dtype=np.float32).reshape(-1))
            total = time.perf_counter() - t
        audio = np.concatenate(trozos)
        dur = len(audio) / sr
        sf.write(SALIDA / f"{nombre}-{i + 1}.wav", audio, sr)
        filas.append({"frase": i + 1, "primer_audio_ms": round(primero), "total_ms": round(total * 1000),
                      "audio_s": round(dur, 2), "rtf": round(total / dur, 3), "cpu_pct": round(c.pct)})
        print(filas[-1], flush=True)
    res = {"candidata": nombre, "carga_ms": round(carga_ms), "ram_mib": round(PROC.memory_info().rss / 2**20), "filas": filas}
    (SALIDA / f"{nombre}.json").write_text(json.dumps(res, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(res, ensure_ascii=False))


def pocket(voz="lola", lengua="spanish_24l"):
    from pocket_tts import TTSModel

    def cargar():
        m = TTSModel.load_model(language=lengua, quantize=True)
        return m, m.get_state_for_audio_prompt(voz)

    def generar(e, texto):
        m, estado = e
        for trozo in m.generate_audio_stream(estado, texto):
            yield trozo.numpy()

    etiqueta = "pocket-" + (Path(voz).stem if voz.endswith(".wav") else voz) + ("" if lengua == "spanish_24l" else "-" + lengua)
    medir(etiqueta, cargar, generar, 24000)


def neutts(ref_wav, ref_txt):
    from neutts import NeuTTS

    def cargar():
        tts = NeuTTS(backbone_repo="neuphonic/neutts-nano-spanish-q8-gguf", backbone_device="cpu",
                     codec_repo="neuphonic/neucodec-onnx-decoder", codec_device="cpu")
        return tts, tts.encode_reference(ref_wav), Path(ref_txt).read_text(encoding="utf-8").strip()

    def generar(e, texto):
        tts, codigos, ref = e
        if hasattr(tts, "infer_stream"):
            yield from tts.infer_stream(texto, codigos, ref)
        else:
            yield tts.infer(texto, codigos, ref)

    medir("neutts-" + Path(ref_wav).stem, cargar, generar, 24000)


def f2(gpu="gpu"):
    """La voz actual, de referencia (Supertonic F2), con el entorno voz\\.venv."""
    from banco_voz import motor_supertonic

    def cargar():
        return motor_supertonic("F2", gpu=(gpu == "gpu"))

    def generar(decir, texto):
        yield decir(texto)[0]

    medir(f"f2-{gpu}", cargar, generar, lambda decir: decir("Hola.")[1])


if __name__ == "__main__":
    {"pocket": pocket, "neutts": neutts, "f2": f2}[sys.argv[1]](*sys.argv[2:])
