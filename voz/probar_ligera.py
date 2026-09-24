"""Voces candidatas, medidas igual: las frases de frases_prueba.json, varias
vueltas, tiempo al primer audio (p50 y p95), RTF, CPU, RAM y VRAM. Cada
candidata corre en su propio entorno porque sus dependencias chocan:

    F:\\ai\\tts\\pocket\\.venv      Pocket TTS en CPU
    F:\\ai\\tts\\pocket-gpu\\.venv  Pocket TTS con torch CUDA
    F:\\ai\\tts\\neutts\\.venv      NeuTTS
    voz\\.venv                     F2 (Supertonic, la voz de antes)

    <venv>\\python probar_ligera.py pocket [voz] [lengua] [--device cuda] [--hilos 2] [--vueltas 3]
    <venv>\\python probar_ligera.py neutts <ref.wav> <ref.txt>
    voz\\.venv\\Scripts\\python probar_ligera.py f2 gpu
"""
import json
import subprocess
import sys
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

# Opciones --clave valor, fuera de los argumentos posicionales.
OPC = {}
_pos = []
_a = sys.argv[1:]
while _a:
    x = _a.pop(0)
    if x.startswith("--"):
        OPC[x[2:]] = _a.pop(0)
    else:
        _pos.append(x)
DEVICE = OPC.get("device", "cpu")
VUELTAS = int(OPC.get("vueltas", "1"))
HILOS = int(OPC["hilos"]) if "hilos" in OPC else None


def vram_usada():
    try:
        return int(subprocess.run(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                                  capture_output=True, text=True).stdout.split()[0])
    except Exception:
        return None


class Cpu:
    """% de CPU del proceso mientras dura el bloque (100 = un nucleo entero)."""
    def __enter__(self):
        self.t0 = time.perf_counter(); self.c0 = sum(PROC.cpu_times()[:2]); return self

    def __exit__(self, *a):
        self.pct = 100 * (sum(PROC.cpu_times()[:2]) - self.c0) / (time.perf_counter() - self.t0)


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))]


def medir(nombre, cargar, generar, sr):
    if HILOS:
        import torch
        torch.set_num_threads(HILOS)
    vram0 = vram_usada()
    t = time.perf_counter(); estado = cargar(); carga_ms = (time.perf_counter() - t) * 1000
    sr = sr(estado) if callable(sr) else sr
    filas = []
    for v in range(VUELTAS):
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
            if v == 0:
                sf.write(SALIDA / f"{nombre}-{i + 1}.wav", audio, sr)
            filas.append({"vuelta": v + 1, "frase": i + 1, "primer_audio_ms": round(primero), "total_ms": round(total * 1000),
                          "audio_s": round(dur, 2), "rtf": round(total / dur, 3), "cpu_pct": round(c.pct)})
            print(filas[-1], flush=True)
    vram1 = vram_usada()
    pa = [f["primer_audio_ms"] for f in filas]; rtf = [f["rtf"] for f in filas]
    res = {"candidata": nombre, "device": DEVICE, "hilos": HILOS, "vueltas": VUELTAS, "carga_ms": round(carga_ms),
           "ram_mib": round(PROC.memory_info().rss / 2**20),
           "vram_mib": (vram1 - vram0) if vram0 is not None and vram1 is not None else None,
           "primer_audio_p50": pct(pa, 50), "primer_audio_p95": pct(pa, 95),
           "rtf_p50": pct(rtf, 50), "rtf_p95": pct(rtf, 95), "rtf_max": max(rtf),
           "cpu_p50": pct([f["cpu_pct"] for f in filas], 50), "filas": filas}
    etiqueta = nombre + (f"-{DEVICE}" if DEVICE != "cpu" else "") + (f"-{HILOS}h" if HILOS else "") + OPC.get("sufijo", "")
    (SALIDA / f"{etiqueta}.json").write_text(json.dumps(res, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps({k: v for k, v in res.items() if k != "filas"}, ensure_ascii=False))


def pocket(voz="lola", lengua="spanish_24l"):
    from pocket_tts import TTSModel

    def cargar():
        # int8 dinamico solo en CPU (FBGEMM); en GPU, float32 tal cual.
        m = TTSModel.load_model(language=lengua, quantize=(DEVICE == "cpu"))
        if DEVICE != "cpu":
            m.to(DEVICE)
        return m, m.get_state_for_audio_prompt(voz)

    def generar(e, texto):
        m, estado = e
        for trozo in m.generate_audio_stream(estado, texto):
            yield trozo.float().cpu().numpy()

    etiqueta = "pocket-" + (Path(voz).stem if voz.endswith(".wav") else voz) + ("" if lengua == "spanish_24l" else "-" + lengua)
    medir(etiqueta, cargar, generar, 24000)


def neutts(ref_wav, ref_txt):
    from neutts import NeuTTS

    def cargar():
        # El modelo base (torch): el GGUF q8 es un repo aparte con su propia puerta.
        tts = NeuTTS(backbone_repo="neuphonic/neutts-nano-spanish", backbone_device=DEVICE,
                     codec_repo="neuphonic/neucodec", codec_device=DEVICE)
        return tts, tts.encode_reference(ref_wav), Path(ref_txt).read_text(encoding="utf-8").strip()

    def generar(e, texto):
        tts, codigos, ref = e
        if hasattr(tts, "infer_stream"):
            yield from tts.infer_stream(texto, codigos, ref)
        else:
            yield tts.infer(texto, codigos, ref)

    medir("neutts-" + Path(ref_wav).stem, cargar, generar, 24000)


def f2(gpu="gpu"):
    """La voz de antes, de referencia (Supertonic F2), con el entorno voz\\.venv."""
    from banco_voz import motor_supertonic

    def cargar():
        return motor_supertonic("F2", gpu=(gpu == "gpu"))

    def generar(decir, texto):
        yield decir(texto)[0]

    medir(f"f2-{gpu}", cargar, generar, lambda decir: decir("Hola.")[1])


if __name__ == "__main__":
    {"pocket": pocket, "neutts": neutts, "f2": f2}[_pos[0]](*_pos[1:])
